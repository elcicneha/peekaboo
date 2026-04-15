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
//      <!-- 1. Radio inputs FIRST — siblings of toolbar and content -->
//      [ToolbarRenderer.toggleInputsHTML]
//      <!-- 2. Toolbar -->
//      [ToolbarRenderer.html(showPreviewToggle: true)]
//      <!-- 3. Scrollable content -->
//      <div id="ql-content">
//        <div id="ql-view-preview">…</div>
//        <div id="ql-view-code">…</div>
//      </div>
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

        /* ── Radio inputs: hidden but functional ──────────────────────── */
        #ql-radio-preview,
        #ql-radio-code { display: none; }

        /* ── CSS-only view toggle ─────────────────────────────────────── */
        /* Default: preview visible, code hidden */
        #ql-view-code { display: none; }

        /* When code radio is selected */
        #ql-radio-code:checked ~ #ql-content #ql-view-preview { display: none; }
        #ql-radio-code:checked ~ #ql-content #ql-view-code    { display: block; }

        /* ── Toolbar ──────────────────────────────────────────────────── */
        #ql-toolbar {
            flex-shrink: 0;
            height: 44px;
            background: rgba(28, 28, 28, 0.96);
            -webkit-backdrop-filter: blur(20px) saturate(180%);
            border-bottom: 1px solid rgba(255, 255, 255, 0.07);
            display: flex;
            align-items: center;
            justify-content: flex-end;
            padding: 0 16px;
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
            font-size: 11px;
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
        }
        """

    // MARK: - HTML

    /// Two hidden radio inputs that power the CSS-only toggle.
    /// Must appear as the **first children of `<body>`**, before `#ql-toolbar`
    /// and `#ql-content`, so the `~` sibling selector can reach them.
    /// Only inject this for pages that use `showPreviewToggle: true`.
    public static let toggleInputsHTML = """
        <input type="radio" name="ql-view" id="ql-radio-preview" checked>
        <input type="radio" name="ql-view" id="ql-radio-code">
        """

    /// The toolbar `<div>`. Pass `showPreviewToggle: true` for markdown files.
    public static func html(showPreviewToggle: Bool) -> String {
        var controls = ""
        if showPreviewToggle {
            controls = """
                <div class="ql-pill" role="group" aria-label="View mode">
                  <label for="ql-radio-preview" id="ql-btn-preview">Preview</label>
                  <label for="ql-radio-code" id="ql-btn-code">Code</label>
                </div>
                """
        }
        return "<div id=\"ql-toolbar\">\(controls)</div>"
    }
}
