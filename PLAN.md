# QuickLook Extension — Build Plan

## Core Idea

A macOS Quick Look extension that uses **VS Code's own tokenization engine and your active theme** to render code previews. The result is pixel-accurate coloring — identical to what you see in the editor — with zero manual theme configuration.

---

## Why This Approach

VS Code is open source (MIT). It uses `vscode-textmate` to tokenize code and TextMate grammars (JSON files) for 100+ languages. Both are available:

- `vscode-textmate` — published on npm, has a WASM build
- Grammar files — sitting at `/Applications/Visual Studio Code.app/Contents/Resources/app/extensions/`
- Your active theme — JSON file in `~/.vscode/extensions/` or VS Code's built-in themes folder

Using the same engine + same grammars + same theme = identical output. No separate theme setup, no color mismatch.

---

## Architecture

### Rendering: HTML (not RTF)

Since `vscode-textmate` runs in JavaScript, we use a WKWebView to:
1. Load the WASM build of `vscode-textmate`
2. Load the grammar file for the target language
3. Tokenize the code
4. Apply theme colors to tokens
5. Return styled HTML to the Quick Look preview

RTF is out. HTML is the right call here since we're already in a JS context.

Markdown uses the same HTML path — `cmark-gfm` for parsing, code blocks tokenized by `vscode-textmate`.

### Three Xcode Targets

```
QuickLookApp/           — Host app (required by macOS to bundle the extension)
                          Minimal UI: shows active VS Code theme name, status
QuickLookExtension/     — QL Preview Extension (QLPreviewProvider)
                          Routes file to renderer, returns HTML reply
QuickLookShared/        — Framework with all rendering logic
                          Used by both app and extension
```

### Renderer Routing

```
file arrives
    ├── .md / .markdown  →  MarkdownRenderer  →  cmark-gfm + vscode-textmate for code blocks
    └── everything else  →  SourceCodeRenderer →  vscode-textmate tokenization
                                                   both → HTML → QLPreviewReply(.html)
```

---

## File Structure

```
quick-look/
├── QuickLook.xcodeproj
│
├── QuickLookApp/
│   ├── QuickLookApp.swift
│   ├── ContentView.swift           # Shows active theme, VS Code path status
│   ├── Info.plist
│   └── QuickLookApp.entitlements   # App Group
│
├── QuickLookExtension/
│   ├── PreviewProvider.swift        # Entry point, routing, .ts magic byte check
│   ├── Info.plist                   # QLSupportedContentTypes
│   └── QuickLookExtension.entitlements
│
├── QuickLookShared/
│   ├── Renderers/
│   │   ├── PreviewRenderer.swift        # Protocol: render(fileURL:) → Data
│   │   ├── SourceCodeRenderer.swift     # vscode-textmate → HTML
│   │   ├── MarkdownRenderer.swift       # cmark-gfm → HTML, code blocks via textmate
│   │   └── PlainTextRenderer.swift      # Fallback
│   ├── VSCode/
│   │   ├── VSCodeLocator.swift          # Finds VS Code installation path
│   │   ├── GrammarLoader.swift          # Loads .tmGrammar.json from VS Code's extensions
│   │   ├── ThemeLoader.swift            # Reads active VS Code theme JSON → token colors
│   │   └── TokenMapper.swift           # Maps vscode-textmate token scopes → colors
│   ├── FileTypeRegistry.swift          # Extension → renderer + grammar name mapping
│   ├── HTMLRenderer.swift              # Assembles final HTML from tokens + theme
│   ├── UserSettings.swift              # App Group UserDefaults (font, size, etc.)
│   └── Resources/
│       ├── vscode-textmate.wasm        # Compiled vscode-textmate WASM build
│       ├── tokenizer.js                # JS glue: loads WASM, exposes tokenize()
│       ├── markdown-styles.css         # GitHub-like markdown stylesheet
│       └── base-template.html          # HTML shell, all CSS inlined at render time
│
└── Tests/
    ├── GrammarLoaderTests.swift
    ├── ThemeLoaderTests.swift
    ├── RendererTests.swift
    └── Fixtures/
        ├── sample.swift
        ├── sample.py
        ├── sample.ts               # TypeScript (text)
        ├── sample-video.ts         # Actual MPEG-2 file for magic byte test
        └── README.md
```

---

## Phases

### Phase 0 — Xcode Scaffolding ✅
**Goal:** Build succeeds, extension visible in System Settings → Extensions → Quick Look

1. ✅ Created Xcode project `QuickLookCode`, macOS App target, deployment target **macOS 13.0**
2. ✅ Added Quick Look Preview Extension target (`QuickLookCodeExtension`)
3. ✅ Added Framework target (`QuickLookCodeShared`), linked into both App and Extension
4. ✅ Configured App Group entitlement: `group.com.nehagupta.quicklookcode`
5. ✅ `PreviewProvider` returns hardcoded HTML via `QLPreviewReply(dataOfContentType: .html)`
6. ✅ `Info.plist` — `QLIsDataBasedPreview: true`, `QLSupportedContentTypes: [public.swift-source]`
7. ✅ Built, launched app, confirmed `qlmanage -p test.swift` shows QuickLookCode preview

**Verified:** `qlmanage -p test.swift` shows dark HTML preview with filename — extension is live

---

### Phase 1 — VS Code / Antigravity Integration ✅
**Goal:** Read grammars and theme directly from the IDE installation

**Verified:** Host app shows `Antigravity · Default Dark Modern · Dark · #1F1F1F`

1. ✅ **IDELocator** (`QuickLookCodeShared/IDE/IDELocator.swift`) — finds VS Code (preferred) then Antigravity in `/Applications` and `~/Applications`. Returns all installed IDEs; `preferred` returns first found.

2. ✅ **GrammarLoader** (`QuickLookCodeShared/IDE/GrammarLoader.swift`) — searches built-in and user extensions for `.tmLanguage.json` / `.tmGrammar.json` by language name. In-memory URL cache.

3. ✅ **ThemeLoader** (`QuickLookCodeShared/IDE/ThemeLoader.swift`) — reads `workbench.colorTheme` from `settings.json`; falls back to `"Default Dark Modern"` when unset. Scans `themes/` folders in all extensions, matches by `"name"` key inside JSON. Returns `ThemeData` with background, foreground, and `[TokenColorRule]`.

4. ✅ **TokenMapper** (`QuickLookCodeShared/IDE/TokenMapper.swift`) — TextMate prefix-matching algorithm, most-specific scope wins.

5. ✅ **Entitlements** — added `temporary-exception` read-only access for `/Applications/`, `~/.vscode/`, `~/.antigravity/`, and both `Library/Application Support/` paths (app + extension).

6. ✅ **Host app status UI** (`ContentView.swift`) — live display of detected IDE, path, theme name, type, and background color swatch.

**Note:** IDE catalog supports VS Code + Antigravity (Google's VS Code fork). VS Code is preferred; Antigravity is fallback. Both share identical internal structure.

---

### Phase 2 — Tokenization + HTML Output (⚠️ working with known gaps)
**Goal:** Code files render with correct colors in Quick Look

**What was built:**

1. ✅ **JSC-based tokenizer** (`tokenizer/src/tokenizer-jsc.js`, built via esbuild)
   - Uses `vscode-textmate` for tokenization
   - Runs inside a `JSContext` (JavaScriptCore) — not WKWebView.
   - Reason: QL extensions are sandboxed and cannot host a WKWebView reliably; JSC runs in-process and returns results synchronously.
   - Two-step protocol: `initGrammar(grammarJSON)` then `doTokenize(code)` — JSC drains the microtask queue between calls, letting vscode-textmate's Promise-based API resolve without an event loop.

2. ✅ **Native JS regex shim for oniguruma**
   - `vscode-textmate` normally uses `vscode-oniguruma` (WASM). We can't ship WASM in a QL extension (see "Dead-end: WASM" below), so we wrote our own `makeOnigScanner` that wraps native JS `RegExp`.
   - Handles the most common oniguruma→JS gaps: `\G` anchor (via slice + `^`), `(?x)` verbose mode (manual stripping), `\p{L}` Unicode props (adds `u` flag), `\x{HHHH}` codepoints, `\h` / `\H` / `\A` / `(?~...)`.
   - **Known limit**: ~95% of grammar patterns work. Features like `\G` inside lookbehinds, `\K`, atomic groups, and complex absence operators break silently — tokens get mislabeled or skipped.

3. ✅ **SourceCodeRenderer** (`QuickLookCodeShared/Renderers/SourceCodeRenderer.swift`)
   - File-size guard: caps at 500 KB / 10,000 lines, appends truncation note.
   - Creates a `JSContext`, loads the bundled `tokenizer-jsc.js`, calls `initGrammar` then `doTokenize`, parses back `[[RawToken]]`.
   - Uses `TokenMapper` to resolve scope→color, then calls `HTMLRenderer`.

4. ✅ **HTMLRenderer** (`QuickLookCodeShared/Renderers/HTMLRenderer.swift`)
   - Self-contained HTML document with inlined CSS (sandbox blocks external loads).
   - Uses theme's `editor.background` / `editor.foreground`, configurable font + size, optional line-number gutter, truncation note styling.
   - ⚠️ `1lh` CSS unit is not supported in QL's WebKit — use `em`-based `min-height` instead.

5. ✅ **FileTypeRegistry**, **UTType declarations**, **entitlements** — all wired up.

6. ✅ **ThemeLoader `include` chain** — VS Code themes (`dark_modern.json`) frequently delegate via `"include": "./dark_plus.json"`. Original parser ignored this and returned zero rules, which caused all tokens to fall back to foreground color. Fixed with recursive `parseTokenColors(from:fileURL:)`.

**Why this isn't good enough:**

Two independent gaps prevent pixel-perfect output:

- **Regex gap** (tokenization layer): Our JS-regex oniguruma approximation silently mislabels tokens whose grammar patterns use features JS regex can't express. Examples seen in the Swift grammar: comments rendered as plain text because of `(?!\G)` wrapper; `import Foundation` misclassified because of `\G` in a lookbehind; function names missed because of `(?x)` verbose patterns. We patched three specific breakages but the underlying engine is still an approximation.

- **Scope→color gap** (mapping layer): `TokenMapper.swift` only handles single-component selectors. VS Code themes (and especially community themes) use multi-component selectors like `"meta.function.body variable.other"` (descendant), parent selectors, and exclusion selectors (`comment - comment.line`). Our mapper splits on spaces and treats the whole string as one prefix to match — none of these advanced forms work. Tokens get a reasonable fallback color, but not the exact color VS Code shows.

**Dead-ends we ruled out:**

- **WASM via WKWebView in the extension** — QL extensions under the App Sandbox can host a WebView but async WASM init fights with the QL reply lifecycle. The WKWebView build (`tokenizer.bundle.js`, ~2 MB) is retained for debugging only.
- **WASM in JSC** — JSC supports WASM on paper, but WASM JIT requires `com.apple.security.cs.allow-jit`, which QL extensions are not granted. Interpreter fallback is too slow and may be disabled in the sandbox context.
- **Extending TokenMapper to patch specific selector shapes** — brittle, per-theme whack-a-mole. Not pursued.

---

### Phase 2.5 — Native Library Migration (next)
**Goal:** Pixel-perfect parity with VS Code by replacing both approximations with the real implementations.

Insight: we're a native macOS binary, not a browser. The reason VS Code ships WASM + hand-rolled TypeScript scope matching is that it runs in Electron. We can link C libraries and call real APIs directly.

**1. Native oniguruma (fixes the regex gap)**

- Add oniguruma C library to the Xcode project. Options:
  - SwiftPM: wrap the C source in a `.systemLibrary` or vendored SwiftPM package.
  - Vendored: drop the oniguruma source into `QuickLookCodeShared/Vendor/oniguruma/`, add to build phases.
  - Prebuilt `.xcframework`: compile once, link into the framework target.
- Write `OnigScanner.swift` wrapping `onig_new` / `onig_search` / `onig_region_t`. Handle UTF-16 ↔ UTF-8 conversion at the JSC boundary (JS strings are UTF-16; oniguruma supports both encodings — pick one and stay consistent).
- Expose `createOnigScanner(patterns)` and `createOnigString(str)` to `JSContext` via `setObject(_:forKeyedSubscript:)`. This fulfills `vscode-textmate`'s `IOnigLib` interface.
- In `tokenizer-jsc.js`, replace the local `jsOnigLib` with `globalThis.onigLib` so the bundle pulls the Swift-provided implementation.
- **Result:** 100% oniguruma compatibility, native speed, no WASM, no JIT entitlement. ~300 lines of Swift.

**2. Use `tokenizeLine2` for color resolution (fixes the scope→color gap)**

`vscode-textmate` exposes two tokenization APIs. We've been using the wrong one.

- `tokenizeLine(line, ruleStack)` → `[{startIndex, endIndex, scopes}]` — just scope labels; scope→color mapping is left to the caller. **This is what we use today, and it's why TokenMapper exists.**
- `tokenizeLine2(line, ruleStack)` → `Uint32Array` of packed `(startIndex, metadata)` pairs where `metadata` is a bitfield containing the already-resolved foreground index, background index, and font-style flags. **This is what VS Code itself uses.** The library does scope→color mapping internally, with full support for descendant selectors, parent selectors, exclusion selectors, and specificity scoring.

Changes:
- In `initGrammar`, also accept a theme object and call `registry.setTheme({ name, settings: tokenColors })`, then capture `registry.getColorMap()` (a `string[]` of hex codes indexed by metadata).
- In `doTokenize`, switch to `grammar.tokenizeLine2(line, ruleStack)`. Unpack each metadata word:
  ```
  foreground = (metadata >> 18) & 0x1FF
  background = (metadata >> 23) & 0x1FF
  fontStyle  = (metadata >> 14) & 0x0F   // 1=italic, 2=bold, 4=underline
  ```
  Look up the foreground hex in the color map; translate font-style flags to our existing `fontStyle` string format.
- Return `[{text, color, fontStyle}]` lines to Swift. Swift just renders.
- **Delete `TokenMapper.swift` entirely.** The library does this correctly; our reimplementation does not.

**3. Clean up**

- Delete the `jsOnigLib` regex approximation, `stripVerbose`, `sanitizePattern`, `buildEntry`, `capturePositions`, `makeOnigScanner` from `tokenizer-jsc.js`. All of it becomes dead code once `globalThis.onigLib` is provided by Swift.
- Keep the two-step `initGrammar` / `doTokenize` protocol — it still makes sense for JSC.
- Remove the WKWebView `tokenizer.bundle.js` path + esbuild target unless there's a reason to keep it.

**Verify:**
- Same Swift source file visually diffed against VS Code — comments, strings, function names, keywords, types, operators all match color-for-color.
- Spot-check against one or two community themes that use multi-component selectors (e.g. One Dark Pro) to confirm the scope→color fix lands.
- `qlmanage -p` on .py, .swift, .js, .json, .ts, .rs — colors identical to VS Code.

---

### Phase 3 — Markdown Renderer
**Goal:** `.md` files render as full GitHub-flavored Markdown

1. Add `cmark-gfm` via Swift Package Manager
2. **MarkdownRenderer**:
   - Parse `.md` → HTML via cmark-gfm (GFM tables, task lists, strikethrough)
   - Fenced code blocks: extract language + content, run through vscode-textmate, replace with highlighted HTML
   - Inline images: convert relative paths to data URIs where possible
3. **markdown-styles.css** — GitHub-like stylesheet, inlined into HTML output
4. Dark/light mode: two CSS blocks, `@media (prefers-color-scheme: dark)` switches between them

**Verify:** `qlmanage -p README.md` — tables, task lists, syntax-highlighted code blocks render correctly

---

### Phase 4 — TypeScript `.ts` Fix (Magic Byte Detection)
**Goal:** `.ts` TypeScript files render correctly; actual MPEG-2 video files pass through

**The problem:** macOS registers `.ts` as `public.mpeg-2-transport-stream` at the system level.

**The solution:** Declare our extension as the handler for `public.mpeg-2-transport-stream`, then inspect the file content to decide what to do.

MPEG-2 Transport Stream signature:
- Byte 0 = `0x47`
- Byte 188 = `0x47`
- Byte 376 = `0x47`
- (sync byte at every 188-byte packet boundary)

```swift
func isMPEG2(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    let data = handle.readData(ofLength: 565)
    guard data.count >= 376 else { return false }
    return data[0] == 0x47 && data[188] == 0x47 && data[376] == 0x47
}
```

- If MPEG-2 → throw `QLPreviewError.notSupported` (system handles it)
- If text → render as TypeScript

**Verify:** TypeScript files render. A real `.ts` video file falls through to system handler.

---

### Phase 5 — Polish & Auto-Update
**Goal:** Zero maintenance, always in sync with VS Code

1. **Theme auto-detection** — watch `~/Library/Application Support/Code/User/settings.json` for changes using `FSEventStream`. When theme changes in VS Code, next Quick Look preview automatically uses the new theme. No restart needed.

2. **Font sync** — read `"editor.fontFamily"` and `"editor.fontSize"` from VS Code settings, use those in previews

3. **Line numbers** — optional toggle (reads VS Code's `"editor.lineNumbers"` setting)

4. **Host app UI** — simple status view:
   - "VS Code found at: /Applications/..."
   - "Active theme: GitHub Dark"
   - Override toggles: font size, line numbers, word wrap

---

## Key Dependencies

| Dependency | Source | Purpose |
|---|---|---|
| `vscode-textmate` | npm, bundled via esbuild | Tokenization + scope→color via `tokenizeLine2` |
| `oniguruma` (C library) | vendored / SwiftPM / xcframework | Regex engine — linked natively, exposed to JSC from Swift |
| TextMate grammars | IDE installation (VS Code / Antigravity) | Language definitions |
| User's active theme | IDE installation | Token colors + font styles |
| `cmark-gfm` | Swift Package Manager | Markdown parsing (Phase 3) |

---

## Testing

```bash
# Test a file
qlmanage -p path/to/file.py

# Reload extension after changes
qlmanage -r
killall -HUP Finder

# Check extension is registered
pluginkit -m -v | grep quicklook

# Verify .ts magic byte detection
qlmanage -p sample.ts        # should render TypeScript
qlmanage -p sample-video.ts  # should fall through
```

---

## Out of Scope

- Mac App Store distribution
- Notarization / public release
- Bracket pair colorization (VS Code UI feature, not tokenization)
- Jupyter notebooks
- CSV / table rendering
