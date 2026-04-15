//
//  ToolbarRenderer.swift
//  QuickLookCodeShared
//
//  Generates the native-looking toolbar injected at the top of every
//  Quick Look preview. The toolbar occupies its own flex row so it never
//  overlaps the scrollable content area below it.
//
//  Toggle mechanism: CSS-only via hidden radio inputs + the general sibling
//  selector (~). Quick Look's WebView has JavaScript disabled, so all
//  interactivity must be driven by CSS :checked state.
//
//  Required body structure for markdown (showPreviewToggle: true):
//
//    <body>
//      <!-- 1. Radio/checkbox inputs FIRST — siblings of toolbar and content -->
//      [ToolbarRenderer.toggleInputsHTML]
//      [ToolbarRenderer.wordWrapCheckboxHTML]
//      <!-- 2. Toolbar -->
//      [ToolbarRenderer.html(showPreviewToggle: true, showWordWrapToggle: true)]
//      <!-- 3. Scrollable content -->
//      <div id="ql-content">
//        <div id="ql-view-preview">…</div>
//        <div id="ql-view-code">…</div>
//      </div>
//    </body>
//
//  Required body structure for code files (showPreviewToggle: false):
//
//    <body>
//      [ToolbarRenderer.wordWrapCheckboxHTML]
//      [ToolbarRenderer.html(showPreviewToggle: false, showWordWrapToggle: true)]
//      <div id="ql-content">…</div>
//    </body>
//

import Foundation

public enum ToolbarRenderer {

    // MARK: - CSS

    /// Full toolbar CSS: layout, dark/light themes, and the CSS-only toggle.
    /// Embed inside a `<style>` block in `<head>`.
    public static let css = """
        html { height: 100%; }
        body {
            height: 100%;
            margin: 0;
            padding: 0;
            display: flex;
            flex-direction: column;
        }

        /* ── Radio/checkbox inputs: hidden but functional ─────────────── */
        #ql-radio-preview,
        #ql-radio-code,
        #ql-wrap { display: none; }

        /* ── CSS-only view toggle ─────────────────────────────────────── */
        /* Default: preview visible, code hidden */
        #ql-view-code { display: none; }

        /* When code radio is selected */
        #ql-radio-code:checked ~ #ql-content #ql-view-preview { display: none; }
        #ql-radio-code:checked ~ #ql-content #ql-view-code    { display: block; }

        /* ── Word wrap toggle ─────────────────────────────────────────── */
        /* Each .line has --line-indent set by Swift (leading whitespace width
           in ch units). padding-left + negative text-indent creates a hanging
           indent so continuation lines align with the first non-space character. */
        #ql-wrap:checked ~ #ql-content .line {
            white-space: pre-wrap;
            padding-left: var(--line-indent, 0ch);
            text-indent: calc(-1 * var(--line-indent, 0ch));
        }

        /* Hide wrap button in markdown preview mode; rule never fires on
           plain code pages because #ql-radio-preview doesn't exist there. */
        #ql-radio-preview:checked ~ #ql-toolbar .ql-wrap-btn { display: none; }

        /* ── Toolbar ──────────────────────────────────────────────────── */
        #ql-toolbar {
            flex-shrink: 0;

            background: rgba(28, 28, 28, 0.96);
            -webkit-backdrop-filter: blur(20px) saturate(180%);
            border-bottom: 1px solid rgba(255, 255, 255, 0.07);
            display: flex;
            align-items: center;
            justify-content: flex-end;
            padding: 2px 8px 4px;
            gap: 8px;
        }
        #ql-content {
            flex: 1;
            overflow: auto;
        }

        /* ── Pill / segmented control ─────────────────────────────────── */
        .ql-pill {
            display: flex;
            background: rgba(255, 255, 255, 0.08);
            border-radius: 6px;
            padding: 2px;
            gap: 1px;
        }
        .ql-pill label {
            display: inline-block;
            background: transparent;
            color: rgba(255, 255, 255, 0.5);
            font-size: 12px;
            font-weight: 500;
            padding: 3px 12px;
            border-radius: 4px;
            cursor: pointer;
            font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
            letter-spacing: 0.01em;
            user-select: none;
        }

        /* Default active: Preview label */
        #ql-btn-preview {
            background: rgba(255, 255, 255, 0.16);
            color: rgba(255, 255, 255, 0.92);
        }

        /* When code radio is checked: Code becomes active, Preview becomes inactive */
        #ql-radio-code:checked ~ #ql-toolbar #ql-btn-preview {
            background: transparent;
            color: rgba(255, 255, 255, 0.5);
        }
        #ql-radio-code:checked ~ #ql-toolbar #ql-btn-code {
            background: rgba(255, 255, 255, 0.16);
            color: rgba(255, 255, 255, 0.92);
        }

        /* Hover: only the inactive button gets a hover highlight */
        #ql-radio-preview:checked ~ #ql-toolbar #ql-btn-code:hover,
        #ql-radio-code:checked   ~ #ql-toolbar #ql-btn-preview:hover {
            background: rgba(255, 255, 255, 0.06);
            color: rgba(255, 255, 255, 0.7);
        }

        /* ── Wrap button ──────────────────────────────────────────────── */
        .ql-wrap-btn {
            display: inline-flex;
            align-items: center;
            background: transparent;
            color: rgba(255, 255, 255, 0.75);
            font-size: 13px;
            font-weight: 400;
            padding: 0px 4px;
            border-radius: 6px;
            border: 1px solid rgba(255, 255, 255, 0.1);
            cursor: pointer;
            font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
            letter-spacing: 0.01em;
            user-select: none;
        }
        .ql-wrap-btn:hover {
            background: rgba(255, 255, 255, 0.05);
        }
        #ql-wrap:checked ~ #ql-toolbar .ql-wrap-btn {
            background: rgba(10, 132, 255, 0.1);
            color: #0a84ff;
            border-color: rgba(10, 132, 255, 0.4);
        }

        /* ── Light mode ───────────────────────────────────────────────── */
        @media (prefers-color-scheme: light) {
            #ql-toolbar {
                background: rgba(235, 235, 235, 0.97);
                border-bottom: 1px solid rgba(0, 0, 0, 0.08);
            }
            .ql-pill {
                background: rgba(0, 0, 0, 0.07);
            }
            .ql-pill label {
                color: rgba(0, 0, 0, 0.45);
            }
            #ql-btn-preview {
                background: rgba(0, 0, 0, 0.11);
                color: rgba(0, 0, 0, 0.85);
            }
            #ql-radio-code:checked ~ #ql-toolbar #ql-btn-preview {
                background: transparent;
                color: rgba(0, 0, 0, 0.45);
            }
            #ql-radio-code:checked ~ #ql-toolbar #ql-btn-code {
                background: rgba(0, 0, 0, 0.11);
                color: rgba(0, 0, 0, 0.85);
            }
            #ql-radio-preview:checked ~ #ql-toolbar #ql-btn-code:hover,
            #ql-radio-code:checked   ~ #ql-toolbar #ql-btn-preview:hover {
                background: rgba(0, 0, 0, 0.05);
                color: rgba(0, 0, 0, 0.6);
            }
            .ql-wrap-btn {
                background: transparent;
                color: rgba(0, 0, 0, 0.6);
                border-color: rgba(0, 0, 0, 0.1);
            }
            .ql-wrap-btn:hover {
                background: rgba(0, 0, 0, 0.05);
            }
            #ql-wrap:checked ~ #ql-toolbar .ql-wrap-btn {
                background: rgba(0, 122, 255, 0.1);
                color: #007aff;
                border-color: rgba(0, 122, 255, 0.4);
            }
        }
        """

    // MARK: - HTML

    /// Two hidden radio inputs that power the CSS-only view toggle.
    /// Must appear before `#ql-toolbar` and `#ql-content` in `<body>` so the
    /// `~` sibling selector can reach them.
    /// Only inject this for pages that use `showPreviewToggle: true`.
    public static let toggleInputsHTML = """
        <input type="radio" name="ql-view" id="ql-radio-preview" checked>
        <input type="radio" name="ql-view" id="ql-radio-code">
        """

    /// Hidden checkbox that powers the CSS-only word-wrap toggle.
    /// Must appear before `#ql-toolbar` and `#ql-content` in `<body>`.
    /// Inject this for all pages that use `showWordWrapToggle: true`.
    public static let wordWrapCheckboxHTML =
        "<input type=\"checkbox\" id=\"ql-wrap\">"

    /// The toolbar `<div>`.
    /// - `showPreviewToggle`: pass `true` for markdown files.
    /// - `showWordWrapToggle`: pass `true` to show the word-wrap button.
    public static func html(showPreviewToggle: Bool, showWordWrapToggle: Bool = false) -> String {
        var left = ""
        var right = ""
        if showWordWrapToggle {
            left = "<label for=\"ql-wrap\" class=\"ql-wrap-btn\">Wrap</label>"
        }
        if showPreviewToggle {
            right = """
                <div class="ql-pill" role="group" aria-label="View mode">
                  <label for="ql-radio-preview" id="ql-btn-preview">Preview</label>
                  <label for="ql-radio-code" id="ql-btn-code">Code</label>
                </div>
                """
        }
        // Both controls are right-aligned by the toolbar's justify-content: flex-end.
        // Wrap sits immediately left of the view-mode pill with the toolbar's 8px gap.
        return "<div id=\"ql-toolbar\">\(left)\(right)</div>"
    }
}
