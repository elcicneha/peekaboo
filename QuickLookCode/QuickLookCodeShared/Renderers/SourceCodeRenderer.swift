//
//  SourceCodeRenderer.swift
//  QuickLookCodeShared
//
//  Tokenizes source code via vscode-textmate running inside a JavaScriptCore
//  context, then builds a syntax-highlighted HTML page using the active VS Code theme.
//
//  JavaScriptCore (JSC) is used instead of WKWebView because:
//    • JSC runs in-process — no child process spawning, works in sandboxed extensions.
//    • The tokenizer-jsc.js bundle uses native JS regex (no WASM), so initialization
//      is fully synchronous.
//    • JSC automatically drains the microtask queue after each API call, which lets
//      us use vscode-textmate's Promise-based API without an async event loop.
//

import Foundation
import JavaScriptCore

// MARK: - Public API

public enum SourceCodeRenderer {

    // MARK: Limits

    public static let maxBytes = 500 * 1024   // 500 KB
    public static let maxLines = 10_000

    // MARK: Errors

    public enum RendererError: LocalizedError {
        case resourceNotFound(String)
        case tokenizationFailed(String)
        case grammarNotUTF8

        public var errorDescription: String? {
            switch self {
            case .resourceNotFound(let r):   return "Resource not found: \(r)"
            case .tokenizationFailed(let r): return "Tokenization failed: \(r)"
            case .grammarNotUTF8:            return "Grammar file is not valid UTF-8"
            }
        }
    }

    // MARK: Entry point

    /// Renders `fileURL` as a syntax-highlighted HTML page.
    /// Safe to call from any thread — JSC is used in-process.
    public static func render(
        fileURL: URL,
        grammarData: Data,
        theme: ThemeData,
        languageInfo: FileTypeRegistry.LanguageInfo,
        fileName: String
    ) async throws -> Data {
        let (content, truncationNote) = readFile(at: fileURL)

        let rawLines = try tokenize(code: content, grammarData: grammarData)

        let mapper = TokenMapper(theme: theme)
        let spanLines: [[HTMLRenderer.TokenSpan]] = rawLines.map { line in
            line.map { raw in
                HTMLRenderer.TokenSpan(
                    text: raw.text,
                    color: mapper.color(forScopes: raw.scopes),
                    fontStyle: mapper.fontStyle(forScopes: raw.scopes)
                )
            }
        }

        let html = HTMLRenderer.render(
            lines: spanLines,
            theme: theme,
            languageDisplayName: languageInfo.displayName,
            fileName: fileName,
            truncationNote: truncationNote
        )
        return Data(html.utf8)
    }

    // MARK: - File reading + size guard

    private static func readFile(at url: URL) -> (String, String?) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attrs?[.size] as? Int) ?? 0

        let rawData: Data
        if byteCount > maxBytes {
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return ("// Could not read file.", nil)
            }
            defer { try? handle.close() }
            rawData = handle.readData(ofLength: maxBytes)
        } else {
            guard let data = try? Data(contentsOf: url) else {
                return ("// Could not read file.", nil)
            }
            rawData = data
        }

        let content = String(data: rawData, encoding: .utf8)
            ?? String(data: rawData, encoding: .isoLatin1)
            ?? "// File could not be decoded."

        let lines = content.components(separatedBy: "\n")
        if lines.count > maxLines {
            let truncated = lines.prefix(maxLines).joined(separator: "\n")
            return (truncated, "// [Preview truncated — file exceeds \(maxLines) lines]")
        }

        if byteCount > maxBytes {
            return (content, "// [Preview truncated — file exceeds 500 KB]")
        }

        return (content, nil)
    }

    // MARK: - JSC tokenization

    private static func tokenize(code: String, grammarData: Data) throws -> [[RawToken]] {
        guard let grammarJSON = String(data: grammarData, encoding: .utf8) else {
            throw RendererError.grammarNotUTF8
        }

        let bundle = Bundle(for: BundleAnchor.self)
        guard let bundleURL = bundle.url(forResource: "tokenizer-jsc", withExtension: "js") else {
            throw RendererError.resourceNotFound(
                "tokenizer-jsc.js not found in QuickLookCodeShared.framework — run `pnpm run build` in tokenizer/"
            )
        }

        let bundleScript: String
        do {
            bundleScript = try String(contentsOf: bundleURL, encoding: .utf8)
        } catch {
            throw RendererError.resourceNotFound("Could not read tokenizer-jsc.js: \(error.localizedDescription)")
        }

        let context = JSContext()!
        context.exceptionHandler = { _, exception in
            // Errors are non-fatal; doTokenize will return null and we'll fall through.
            guard let msg = exception?.toString() else { return }
            NSLog("[QuickLookCode] JSC: %@", msg)
        }

        // JSC has no `window`; shim it to globalThis so the iife bundle works.
        context.evaluateScript("var window = globalThis;")

        // Load the vscode-textmate bundle.
        context.evaluateScript(bundleScript)

        // Step 1 — init grammar.
        // After this call, JSC drains its microtask queue automatically.
        // Because our onigLib and loadGrammar callbacks resolve synchronously,
        // _grammar is set before the call returns to Swift.
        let initFn = context.objectForKeyedSubscript("initGrammar")
        initFn?.call(withArguments: [grammarJSON])

        // Step 2 — tokenize. Returns an Array<Array<{text,scopes}>> or null.
        let tokenizeFn = context.objectForKeyedSubscript("doTokenize")
        let result = tokenizeFn?.call(withArguments: [code])

        guard let result, !result.isNull, !result.isUndefined else {
            throw RendererError.tokenizationFailed(
                "doTokenize returned null — grammar may not have loaded (check grammar JSON)"
            )
        }

        return parseResult(result)
    }

    private static func parseResult(_ value: JSValue) -> [[RawToken]] {
        guard let lines = value.toArray() else { return [] }
        return lines.compactMap { lineAny -> [RawToken]? in
            guard let line = lineAny as? [Any] else { return [] }
            return line.compactMap { tokenAny -> RawToken? in
                guard
                    let token  = tokenAny as? [String: Any],
                    let text   = token["text"]   as? String,
                    let scopes = token["scopes"] as? [String]
                else { return nil }
                return RawToken(text: text, scopes: scopes)
            }
        }
    }
}

// MARK: - Internals

extension SourceCodeRenderer {
    struct RawToken {
        let text: String
        let scopes: [String]
    }
}

/// Used only as a `Bundle(for:)` anchor to locate the framework's resources.
private final class BundleAnchor {}
