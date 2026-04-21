# Design Decisions

A running record of non-obvious architectural decisions, failed approaches, and confirmed solutions. Consult this before changing scroll/layout/interactivity behaviour in the preview.

---

## Horizontal scroll in short code files

**Problem**: When a code file has fewer lines than the viewport height, the horizontal scrollbar appeared just below the last line of code — not at the bottom of the Quick Look window. Hovering in the empty space below the code did not trigger scroll.

**Diagnostic findings** (via `evaluateJavaScript` + `WKNavigationDelegate.webView(_:didFinish:)`):
- JS *does* run in Quick Look's WKWebView (`evaluateJavaScript` works, `error=nil`).
- `window.innerHeight` = WKWebView frame height (e.g. 600px). Viewport ≠ content height.
- `#ql-content.offsetHeight` = ~564px (fills the viewport via `flex: 1`). The CSS layout was already correct.
- The scroll container size was never the issue.

**Root cause**: macOS WKWebView only routes scroll events to a CSS scroll container when the mouse is over an actual DOM element inside it. The `<pre>` element was only as tall as the code lines (e.g. 100px). The 464px of empty background space within `#ql-content` had no element underneath, so WKWebView swallowed those scroll events.

**What did NOT work**:

| Approach | Why it failed |
|---|---|
| `body/html { height: 100% }` + `#ql-content { flex: 1; overflow: auto }` | Layout was already correct; not the cause |
| `html { overflow: auto }` (viewport-level scroll) | Same — elements already at correct heights |
| `#ql-content { position: fixed; inset: 0; overflow: auto }` | `position: fixed` in Quick Look WKWebView resolves to content dimensions, not the NSView frame |
| `pre { min-height: 100% }` | Percentage heights do not resolve inside a CSS scroll container (`overflow: auto`) in WKWebView |
| `#ql-content { display: flex; flex-direction: column }` + `pre { flex: 1 }` | Flex children inside a scroll container (`overflow: auto`) cannot grow to fill it via CSS in WKWebView |
| `evaluateJavaScript` injecting `min-height: Xpx` on `html`/`body` | JS ran and injected correctly, but elements were already the right height — wrong diagnosis |

**What works** (`PreviewViewController.swift`, `webView(_:didFinish:)`):

```javascript
(function(){
    var qc = document.getElementById('ql-content');
    var pre = qc && qc.querySelector('pre');
    if (pre && qc) pre.style.minHeight = qc.offsetHeight + 'px';
})();
```

After the page loads, read `#ql-content.offsetHeight` (the actual rendered pixel height from the JS runtime) and set it as an inline `minHeight` on `<pre>`. Inline styles bypass all CSS percentage/flex resolution ambiguity. The `<pre>` now physically covers the entire scroll container, so every pixel of the viewport is over a real DOM element and WKWebView routes scroll events correctly.

**Do not revert or "clean up" this JS injection.** It looks redundant (the CSS layout is already correct) but it is load-bearing for scroll behaviour in short files.

---

## Right-edge padding on horizontal scroll

**Problem**: When a code line overflows the viewport horizontally, the rightmost character is flush with the window edge at maximum scroll position. The left edge has 20px padding (from `pre { padding-left: 20px }`); the right edge has none.

**Root cause**: CSS padding on the trailing (right) edge of block elements does not extend the scrollable overflow area in WebKit. This is a long-standing WebKit behaviour — the scroll container's extent is determined by the content box of descendants, not their padding boxes on the trailing edge. `body { display: flex }` (set by `ToolbarRenderer.css`) makes this worse by changing how overflow propagates through the layout tree.

**What did NOT work**:

| Approach | Why it failed |
|---|---|
| `pre { padding: 16px 20px }` (original) | Right padding not included in WebKit scroll extent |
| `pre { padding-right: 0 }` + `.line { padding-right: 20px }` | Block-level `padding-right` on `.line` does not extend scroll width in WebKit |
| `html { padding-right: 20px }` | `box-sizing: border-box` (global rule) makes the padding shrink `html`'s content area instead of adding to scroll width |
| `code { display: block; width: max-content; min-width: 100%; padding-right: 20px; box-sizing: content-box }` | `body { display: flex; flex-direction: column }` constrains the flex item (`#ql-content`) cross-axis width; overflow did not propagate to the scroll container as expected |
| `.line::after { content: ''; display: inline-block; width: 20px }` | The inline-block `::after` extended each line's inline width, but the scroll container still did not account for it |

| `pre { margin-right: 20px }` | Child margins should extend scroll overflow per spec; did not work in this WKWebView setup |
| `evaluateJavaScript` in `didFinish`: read `pre.scrollWidth`, set `pre.style.width = scrollWidth + 20 + 'px'` inline | Same pattern that fixed the vertical scroll issue; `pre` became wider but scroll container still didn't expose the extra 20px |

**Not attempted**:
- `pre { border-right: 20px solid transparent }` — borders are part of the border box (unlike padding) and may genuinely extend scroll extent; untried.
- `webView.scrollView.contentInsets` — `WKWebView` on macOS does not expose a `scrollView` property (iOS-only API); native inset control unavailable.

**Decision**: dropped. The left-edge padding is consistent and the right-flush behaviour is a minor cosmetic issue. Revisit if a clean solution emerges.

---

## JavaScript availability in Quick Look WKWebView

`ToolbarRenderer.swift` has a comment "Quick Look's WebView has JavaScript disabled". This is **incorrect** — JS is enabled by default in WKWebView and Quick Look does not disable it. The comment was written to justify the CSS-only toggle approach, not from empirical testing.

`evaluateJavaScript` *does* work. The earlier failed attempts failed due to timing (called before the page finished loading), not because JS was disabled.

**CSS-only toggles** (radio inputs + `:checked` sibling selectors) are still the right approach for user interaction (the Preview/Code pill, word-wrap button) because they are synchronous with user input and need no round-trip. But JS is available for post-load DOM measurement and correction.

---

## Why `position: fixed` does not fill the WKWebView frame

In a normal browser, `position: fixed; inset: 0` fills the viewport (browser window). In Quick Look's WKWebView, the "viewport" for fixed-position elements resolves to the HTML document content area, not the NSView frame. Confirmed by the failed `#ql-content { position: fixed; inset: 0 }` experiment — it did not fill the frame. The `.ql-wrap-btn { position: fixed; top: 6px; right: 6px }` appears visually correct only because the content area starts at the top-left of the NSView, making corner-anchored fixed elements look right.

---

## CSS scroll containers and child percentage heights

In WKWebView (and WebKit generally), children of an element with `overflow: auto` or `overflow: scroll` cannot use percentage heights (`height: 100%`, `min-height: 100%`) to fill the parent. The parent's height is not considered "definite" for percentage resolution purposes once it becomes a scroll container.

This also applies to `flex: 1` on a child of a flex item that has `overflow: auto` — the child does not grow to fill the scroll container.

The only reliable way to fill a scroll container to its rendered height is to read `offsetHeight` via JavaScript at runtime and set an explicit pixel value as an inline style.
