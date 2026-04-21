//
//  PreviewViewController.swift
//  QuickLookCodeExtension
//

import Cocoa
import Quartz
import WebKit
import QuickLookCodeShared

class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate {

    private var webView: WKWebView!
    private var pendingHTML: String?

    /// Set by the markdown render path; consumed in `didFinish` to kick off the
    /// deferred Code-tab tokenize. Nil for non-markdown files.
    private var pendingSourceContext: MarkdownSourceContext?

    private struct MarkdownSourceContext {
        let markdown: String
        let theme: ThemeData
        let ide: IDEInfo
    }

    private struct PreviewPayload {
        let html: String
        let sourceContext: MarkdownSourceContext?
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.masksToBounds = true

        // Reuse the shared web content process across all preview instances to avoid
        // the ~100–200 ms cold-start cost of spawning a fresh process each time.
        let config = WKWebViewConfiguration()
        config.processPool = SharedWebProcessPool.shared

        webView = WKWebView(frame: container.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 6
        webView.layer?.masksToBounds = true
        webView.navigationDelegate = self
        container.addSubview(webView)
        self.view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let html = pendingHTML {
            webView.loadHTMLString(html, baseURL: nil)
            pendingHTML = nil
        }
    }

    // After each page load, stretch <pre> to fill the scroll container so that
    // scroll events fire over the full viewport, not just the code lines. Also
    // the hook where the deferred markdown Code-tab tokenize kicks off — doing
    // it here instead of inline in `preparePreviewOfFile` means the tokenizer's
    // 100–200 ms cold init overlaps with WKWebView layout/paint, not the user's
    // wait for first pixels.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("""
            (function(){
                var qc = document.getElementById('ql-content');
                var pre = qc && qc.querySelector(':scope > pre');
                if (pre && qc) pre.style.minHeight = qc.offsetHeight + 'px';
            })();
        """)

        if let ctx = pendingSourceContext {
            pendingSourceContext = nil
            Task { @MainActor [weak self] in
                let sourceHTML = await MarkdownRenderer.renderSourceHTML(
                    markdown: ctx.markdown,
                    theme: ctx.theme,
                    ide: ctx.ide
                )
                guard let self, let webView = self.webView else { return }
                // Use callAsyncJavaScript's argument bridge so the HTML string is
                // passed as a JS value — no manual escaping, no injection risk.
                _ = try? await webView.callAsyncJavaScript(
                    "document.getElementById('ql-source-slot').innerHTML = html;",
                    arguments: ["html": sourceHTML],
                    in: nil,
                    in: .defaultClient
                )
            }
        }
    }

    func preparePreviewOfFile(at url: URL) async throws {
        // Pre-warm TokenizerEngine in parallel with the render path. Its 60–150 ms
        // JSContext + bundle eval cost overlaps with bootstrap / cmark-gfm / theme
        // load instead of serializing behind them. Cheap no-op if already warm.
        Task.detached(priority: .userInitiated) { CacheManager.prewarmTokenizer() }

        // Ensure the cache is populated before rendering. No-op after the first call
        // in a process; on ad-hoc-signed builds where there's no App Group, the
        // fallback disk cache lives in this process's sandbox container.
        CacheManager.bootstrap()

        if Task.isCancelled { return }

        let payload = await renderHTML(fileURL: url, fileName: url.lastPathComponent, ext: url.pathExtension)

        if Task.isCancelled { return }

        await MainActor.run {
            pendingSourceContext = payload.sourceContext
            pendingHTML = payload.html
            if webView.window != nil {
                webView.loadHTMLString(payload.html, baseURL: nil)
                pendingHTML = nil
            }
        }
    }

    // MARK: - Render pipeline

    /// Attempts syntax-highlighted rendering; falls back to plain text on any failure.
    private func renderHTML(fileURL: URL, fileName: String, ext: String) async -> PreviewPayload {
        if ext == "md" || ext == "markdown" {
            return await renderMarkdown(fileURL: fileURL, fileName: fileName)
        }

        guard let langInfo = FileTypeRegistry.language(forExtension: ext) else {
            return PreviewPayload(html: plainText(fileURL: fileURL, fileName: fileName, reason: "Unsupported file type"), sourceContext: nil)
        }

        guard let ide = IDELocator.preferred else {
            return PreviewPayload(html: plainText(fileURL: fileURL, fileName: fileName, reason: "VS Code not found"), sourceContext: nil)
        }

        let grammarLoader = GrammarLoader(ide: ide)
        guard let grammar = (try? grammarLoader.grammarData(for: langInfo.grammarSearch)) ?? nil else {
            return PreviewPayload(html: plainText(fileURL: fileURL, fileName: fileName, reason: "Grammar not found for \(langInfo.displayName)"), sourceContext: nil)
        }
        let siblingGrammars = grammarLoader.siblingGrammarData(for: langInfo.grammarSearch)

        guard let theme = try? ThemeLoader.loadActiveTheme(from: ide) else {
            return PreviewPayload(html: plainText(fileURL: fileURL, fileName: fileName, reason: "Theme could not be loaded"), sourceContext: nil)
        }

        if Task.isCancelled {
            return PreviewPayload(html: "", sourceContext: nil)
        }

        do {
            let data = try await SourceCodeRenderer.render(
                fileURL: fileURL,
                grammarData: grammar,
                siblingGrammars: siblingGrammars,
                theme: theme,
                languageInfo: langInfo,
                fileName: fileName
            )
            let html = String(data: data, encoding: .utf8) ?? plainText(fileURL: fileURL, fileName: fileName, reason: "Render produced invalid UTF-8")
            return PreviewPayload(html: html, sourceContext: nil)
        } catch {
            return PreviewPayload(html: plainText(fileURL: fileURL, fileName: fileName, reason: error.localizedDescription), sourceContext: nil)
        }
    }

    private func renderMarkdown(fileURL: URL, fileName: String) async -> PreviewPayload {
        guard let ide = IDELocator.preferred else {
            return PreviewPayload(html: plainText(fileURL: fileURL, fileName: fileName, reason: "VS Code not found"), sourceContext: nil)
        }
        guard let theme = try? ThemeLoader.loadActiveTheme(from: ide) else {
            return PreviewPayload(html: plainText(fileURL: fileURL, fileName: fileName, reason: "Theme could not be loaded"), sourceContext: nil)
        }

        if Task.isCancelled {
            return PreviewPayload(html: "", sourceContext: nil)
        }

        do {
            let result = try await MarkdownRenderer.render(
                fileURL: fileURL,
                theme: theme,
                ide: ide,
                fileName: fileName
            )
            guard let html = String(data: result.html, encoding: .utf8) else {
                return PreviewPayload(html: plainText(fileURL: fileURL, fileName: fileName, reason: "Markdown render produced invalid UTF-8"), sourceContext: nil)
            }
            return PreviewPayload(
                html: html,
                sourceContext: MarkdownSourceContext(markdown: result.markdown, theme: theme, ide: ide)
            )
        } catch {
            return PreviewPayload(html: plainText(fileURL: fileURL, fileName: fileName, reason: error.localizedDescription), sourceContext: nil)
        }
    }

    // MARK: - Plain text fallback

    private func plainText(fileURL: URL, fileName: String, reason: String) -> String {
        let content: String
        if let data = try? Data(contentsOf: fileURL),
           let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            let lines = text.components(separatedBy: "\n")
            let capped = lines.prefix(SourceCodeRenderer.maxLines).joined(separator: "\n")
            content = capped
                .replacingOccurrences(of: "&",  with: "&amp;")
                .replacingOccurrences(of: "<",  with: "&lt;")
                .replacingOccurrences(of: ">",  with: "&gt;")
        } else {
            content = "// Could not read file."
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <style>
        *, *::before, *::after { box-sizing: border-box; }
        html, body { margin: 0; padding: 0; background: #1e1e1e; color: #d4d4d4; }
        body { font-family: ui-monospace, 'SF Mono', Menlo, Monaco, monospace; font-size: 13px; }
        pre { margin: 0; padding: 16px 20px; line-height: 1.6; overflow: auto; }
        .note { color: #6a9955; font-style: italic; margin-bottom: 12px; }
        </style>
        </head>
        <body>
        <pre><div class="note">// \(escapeHTML(reason)) — showing plain text</div>\(content)</pre>
        </body>
        </html>
        """
    }

    private func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
