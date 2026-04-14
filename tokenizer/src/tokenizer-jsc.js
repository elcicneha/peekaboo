/**
 * tokenizer-jsc.js — JavaScriptCore-compatible synchronous tokenizer
 *
 * Key differences from tokenizer.js (WKWebView build):
 *  - No WASM / oniguruma — uses native JS RegExp as the onig implementation.
 *    This works for ~95% of TextMate grammar patterns. Patterns that use
 *    oniguruma-specific syntax (e.g. \h, absence operator) are silently skipped.
 *  - Everything is synchronous — JSC has no event loop, so we use a two-step
 *    protocol: initGrammar() queues Promise resolution, then doTokenize() runs
 *    after JSC drains the microtask queue automatically post-call.
 *  - Uses globalThis instead of window (JSC has no window).
 *
 * Swift protocol:
 *   1. globalThis.initGrammar(grammarJSON: string)  — call once per render
 *   2. (JSC drains microtasks automatically after the call returns)
 *   3. globalThis.doTokenize(code: string) → Array<Array<{text,scopes}>>
 */

import { Registry, INITIAL } from "vscode-textmate";

// ---------------------------------------------------------------------------
// Native JS regex — approximate oniguruma implementation
// ---------------------------------------------------------------------------

// Does the raw pattern string contain \G (oniguruma "current position" anchor)?
const HAS_G_ANCHOR = /\\G/;
// Does the pattern use Unicode property escapes (\p{L} etc.)? Needs 'u' flag in JS.
const HAS_UNICODE_PROP = /\\[pP]\{/;

// ---------------------------------------------------------------------------
// Verbose-mode (?x) stripping
// ---------------------------------------------------------------------------

/**
 * Strip whitespace and # comments from an oniguruma (?x) verbose-mode pattern.
 * Whitespace inside character classes [...] is preserved.
 */
function stripVerbose(p) {
    // Remove the leading (?x) or variant like (?xi), (?sx), etc.
    let s = p.replace(/^\(\?[a-zA-Z]*x[a-zA-Z]*\)/, "");
    let result = "";
    let inClass = false;
    let i = 0;
    while (i < s.length) {
        const c = s[i];
        if (c === "\\") {
            // Escaped character — always preserve both chars verbatim.
            result += s[i] + (s[i + 1] ?? "");
            i += 2;
            continue;
        }
        if (!inClass && c === "[") { inClass = true;  result += c; i++; continue; }
        if ( inClass && c === "]") { inClass = false; result += c; i++; continue; }
        if (!inClass) {
            if (c === "#") {
                // Comment — skip to end of line.
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
    // Handle verbose mode (?x) — must be done before other replacements.
    if (/^\(\?[a-zA-Z]*x[a-zA-Z]*\)/.test(p)) p = stripVerbose(p);

    return p
        .replace(/\\x\{([0-9a-fA-F]+)\}/g, "\\u{$1}") // \x{HHHH} → \u{HHHH} (needs u flag)
        .replace(/\\h/g, "[0-9a-fA-F]")                // hex digit class
        .replace(/\\H/g, "[^0-9a-fA-F]")               // non-hex digit class
        .replace(/\\A/g, "")                            // \A start-of-input — drop, ^ implied for G-patterns
        .replace(/\(\?~[^)]+\)/g, "(?:)");              // absence operator → no-op
}

/**
 * Build a compiled entry for a pattern.
 *
 * Two special cases:
 *  - \G patterns: replace \G with ^ and test on a slice from startPosition,
 *    so ^ anchors naturally to startPosition. No 'g' flag (single exec on slice).
 *  - \p{...} patterns: require the 'u' flag for Unicode property escapes.
 */
function buildEntry(pattern) {
    const hasGAnchor    = HAS_G_ANCHOR.test(pattern);
    const hasUnicode    = HAS_UNICODE_PROP.test(pattern);

    const adjusted = hasGAnchor
        ? sanitizePattern(pattern).replace(/\\G/g, "^")
        : sanitizePattern(pattern);

    // 'g' flag: needed for non-\G patterns so lastIndex works correctly.
    // 'u' flag: needed for \p{...} and \u{HHHH} to work.
    const flags = (hasGAnchor ? "" : "g") + (hasUnicode ? "u" : "");

    let re;
    try {
        re = new RegExp(adjusted, flags);
    } catch (_) {
        // Fallback: try without 'u' (loses Unicode properties but may recover)
        try { re = new RegExp(adjusted, hasGAnchor ? "" : "g"); } catch (_) { re = null; }
    }
    return { re, hasGAnchor };
}

/**
 * Approximate capture group start/end positions without the 'd' flag.
 * Capture[0] is exact (full match). Captures 1..N are approximated by
 * finding the capture text inside the full match — imprecise for repeated
 * substrings but correct for the vast majority of grammar captures.
 */
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
                    // \G patterns: test on a slice so ^ anchors to startPosition.
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

                // Pick earliest match; on tie, first pattern wins (loop order).
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
// Two-step protocol globals
// ---------------------------------------------------------------------------

let _grammar = null;

globalThis.initGrammar = function initGrammar(grammarJSON) {
    _grammar = null;
    let grammarDef;
    try {
        grammarDef = JSON.parse(grammarJSON);
    } catch (e) {
        console.error("initGrammar: failed to parse grammarJSON:", e.message);
        return;
    }
    const scopeName = grammarDef.scopeName;

    const registry = new Registry({
        onigLib: Promise.resolve(jsOnigLib),
        loadGrammar: (name) =>
            name === scopeName
                ? Promise.resolve(grammarDef)
                : Promise.resolve(null),
    });

    // loadGrammar returns a Promise. Because our onigLib and loadGrammar
    // callbacks are synchronously resolved, JSC will drain the microtask queue
    // after this call returns — so _grammar will be set before doTokenize runs.
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
        const { tokens, ruleStack: nextStack } = _grammar.tokenizeLine(
            line,
            ruleStack
        );
        ruleStack = nextStack;
        result.push(
            tokens.map((t) => ({
                text: line.slice(t.startIndex, t.endIndex),
                scopes: t.scopes,
            }))
        );
    }

    return result;
};
