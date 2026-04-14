/**
 * tokenizer-jsc.js — JavaScriptCore-compatible synchronous tokenizer
 *
 * Uses vscode-textmate's tokenizeLine2 to produce packed metadata, resolves
 * foreground colors via the registry's internal color map, and returns flat
 * {text, color, fontStyle} spans to Swift. This moves scope-to-color matching
 * (descendant/parent/exclusion selectors, specificity scoring) into the
 * library — which is what VS Code itself does.
 *
 * Still using a native JS RegExp approximation for oniguruma; Part B will
 * replace that with a Swift-provided onigLib.
 *
 * Swift protocol:
 *   1. globalThis.initGrammar(grammarJSON: string, themeJSON: string)
 *   2. (JSC drains microtasks automatically after the call returns)
 *   3. globalThis.doTokenize(code: string)
 *        → Array<Array<{text, color, fontStyle}>>
 */

import { Registry, INITIAL } from "vscode-textmate";

// ---------------------------------------------------------------------------
// Native JS regex — approximate oniguruma implementation (replaced in Part B)
// ---------------------------------------------------------------------------

const HAS_G_ANCHOR = /\\G/;
const HAS_UNICODE_PROP = /\\[pP]\{/;

function stripVerbose(p) {
    let s = p.replace(/^\(\?[a-zA-Z]*x[a-zA-Z]*\)/, "");
    let result = "";
    let inClass = false;
    let i = 0;
    while (i < s.length) {
        const c = s[i];
        if (c === "\\") {
            result += s[i] + (s[i + 1] ?? "");
            i += 2;
            continue;
        }
        if (!inClass && c === "[") { inClass = true;  result += c; i++; continue; }
        if ( inClass && c === "]") { inClass = false; result += c; i++; continue; }
        if (!inClass) {
            if (c === "#") {
                while (i < s.length && s[i] !== "\n") i++;
                continue;
            }
            if (c === " " || c === "\t" || c === "\n" || c === "\r") {
                i++;
                continue;
            }
        }
        result += c;
        i++;
    }
    return result;
}

function sanitizePattern(p) {
    if (/^\(\?[a-zA-Z]*x[a-zA-Z]*\)/.test(p)) p = stripVerbose(p);
    return p
        .replace(/\\x\{([0-9a-fA-F]+)\}/g, "\\u{$1}")
        .replace(/\\h/g, "[0-9a-fA-F]")
        .replace(/\\H/g, "[^0-9a-fA-F]")
        .replace(/\\A/g, "")
        .replace(/\(\?~[^)]+\)/g, "(?:)");
}

function buildEntry(pattern) {
    const hasGAnchor = HAS_G_ANCHOR.test(pattern);
    const hasUnicode = HAS_UNICODE_PROP.test(pattern);

    const adjusted = hasGAnchor
        ? sanitizePattern(pattern).replace(/\\G/g, "^")
        : sanitizePattern(pattern);

    const flags = (hasGAnchor ? "" : "g") + (hasUnicode ? "u" : "");

    let re;
    try {
        re = new RegExp(adjusted, flags);
    } catch (_) {
        try { re = new RegExp(adjusted, hasGAnchor ? "" : "g"); } catch (_) { re = null; }
    }
    return { re, hasGAnchor };
}

function capturePositions(m, matchStart) {
    const full = m[0];
    const positions = [{
        start: matchStart,
        end: matchStart + full.length,
        length: full.length,
    }];

    let searchOffset = 0;
    for (let i = 1; i < m.length; i++) {
        const cap = m[i];
        if (cap === undefined || cap === null) {
            positions.push({ start: 0, end: 0, length: 0 });
            continue;
        }
        const idx = full.indexOf(cap, searchOffset);
        if (idx === -1) {
            positions.push({ start: 0, end: 0, length: 0 });
        } else {
            positions.push({
                start: matchStart + idx,
                end: matchStart + idx + cap.length,
                length: cap.length,
            });
            searchOffset = idx + cap.length;
        }
    }
    return positions;
}

function makeOnigScanner(patterns) {
    const entries = patterns.map(buildEntry);

    return {
        findNextMatchSync(string, startPosition) {
            const str = typeof string === "string" ? string : string.content;
            let bestMatch = null;
            let bestStart = Infinity;
            let bestPatternIdx = -1;

            for (let i = 0; i < entries.length; i++) {
                const { re, hasGAnchor } = entries[i];
                if (!re) continue;

                let m, matchStart;
                if (hasGAnchor) {
                    const slice = str.slice(startPosition);
                    m = re.exec(slice);
                    if (!m) continue;
                    matchStart = startPosition + m.index;
                } else {
                    re.lastIndex = startPosition;
                    m = re.exec(str);
                    if (!m || m.index < startPosition) continue;
                    matchStart = m.index;
                }

                if (matchStart < bestStart) {
                    bestMatch = m;
                    bestStart = matchStart;
                    bestPatternIdx = i;
                }
            }

            if (!bestMatch) return null;
            return {
                index: bestPatternIdx,
                captureIndices: capturePositions(bestMatch, bestStart),
            };
        },
        dispose() {},
    };
}

const jsOnigLib = {
    createOnigScanner: (patterns) => makeOnigScanner(patterns),
    createOnigString: (str) => ({ content: str, dispose() {} }),
};

// ---------------------------------------------------------------------------
// tokenizeLine2 metadata layout (vscode-textmate MetadataConsts)
// ---------------------------------------------------------------------------
//   bits  0-7   language id     (ignored here)
//   bits  8-9   token type      (ignored here)
//   bit  10     balanced bracket flag
//   bits 11-14  font style      (1=italic, 2=bold, 4=underline, 8=strikethrough)
//   bits 15-23  foreground index into color map
//   bits 24-31  background index into color map (ignored — we use theme.background)

const FONT_STYLE_OFFSET = 11;
const FOREGROUND_OFFSET = 15;
const FONT_STYLE_MASK = 0xF;
const FOREGROUND_MASK = 0x1FF;

// ---------------------------------------------------------------------------
// Two-step protocol globals
// ---------------------------------------------------------------------------

let _grammar = null;
let _colorMap = null;

globalThis.initGrammar = function initGrammar(grammarJSON, themeJSON) {
    _grammar = null;
    _colorMap = null;

    let grammarDef;
    try {
        grammarDef = JSON.parse(grammarJSON);
    } catch (e) {
        console.error("initGrammar: failed to parse grammarJSON: " + e.message);
        return;
    }

    let theme = null;
    if (themeJSON) {
        try {
            theme = JSON.parse(themeJSON);
        } catch (e) {
            console.error("initGrammar: failed to parse themeJSON: " + e.message);
        }
    }

    const scopeName = grammarDef.scopeName;

    const registry = new Registry({
        onigLib: Promise.resolve(jsOnigLib),
        loadGrammar: (name) =>
            name === scopeName
                ? Promise.resolve(grammarDef)
                : Promise.resolve(null),
    });

    if (theme) {
        registry.setTheme(theme);
        _colorMap = registry.getColorMap();
    }

    // loadGrammar returns a Promise; JSC drains the microtask queue after this
    // call returns, so _grammar is set before doTokenize runs.
    registry.loadGrammar(scopeName).then((g) => {
        _grammar = g;
    });
};

globalThis.doTokenize = function doTokenize(code) {
    if (!_grammar) return null;

    const lines = code.split("\n");
    let ruleStack = INITIAL;
    const result = [];

    for (const line of lines) {
        const { tokens, ruleStack: nextStack } = _grammar.tokenizeLine2(
            line,
            ruleStack
        );
        ruleStack = nextStack;

        const lineTokens = [];
        const len = tokens.length;
        for (let i = 0; i < len; i += 2) {
            const start = tokens[i];
            const metadata = tokens[i + 1];
            const end = i + 2 < len ? tokens[i + 2] : line.length;
            if (end <= start) continue;

            const fgIdx = (metadata >>> FOREGROUND_OFFSET) & FOREGROUND_MASK;
            const fsFlags = (metadata >>> FONT_STYLE_OFFSET) & FONT_STYLE_MASK;

            const color = (_colorMap && fgIdx > 0) ? (_colorMap[fgIdx] || null) : null;

            let fontStyle = null;
            if (fsFlags) {
                const parts = [];
                if (fsFlags & 1) parts.push("italic");
                if (fsFlags & 2) parts.push("bold");
                if (fsFlags & 4) parts.push("underline");
                if (fsFlags & 8) parts.push("strikethrough");
                fontStyle = parts.join(" ");
            }

            lineTokens.push({
                text: line.slice(start, end),
                color,
                fontStyle,
            });
        }

        result.push(lineTokens);
    }

    return result;
};
