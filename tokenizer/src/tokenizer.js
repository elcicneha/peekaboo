/**
 * tokenizer.js — vscode-textmate tokenization bridge for QuickLookCode
 *
 * Bundled by esbuild into tokenizer.bundle.js (see ../esbuild.js).
 * The bundle is a self-contained script: the oniguruma WASM is embedded as
 * base64, so the WKWebView needs no network access and no separate .wasm file.
 *
 * Exposed global:
 *   window.tokenize(grammarJSON: string, code: string)
 *     → Promise<Array<Array<{text: string, scopes: string[]}>>>
 *
 * Each inner array corresponds to one line of `code` (split on "\n").
 * Each element within a line is one TextMate token span.
 */

import { Registry, INITIAL } from "vscode-textmate";
import { createOnigScanner, createOnigString, loadWASM } from "vscode-oniguruma";

// The WASM binary is inlined by esbuild as a base64 data URL.
// import is resolved at build time; the string value is the base64 payload.
import onigWasmB64 from "vscode-oniguruma/release/onig.wasm";

let initialized = false;

async function ensureInitialized() {
  if (initialized) return;
  // Decode base64 → Uint8Array → initialise the oniguruma WASM engine.
  // esbuild's `dataurl` loader produces a data URL like:
  //   "data:application/wasm;base64,<payload>"
  const base64 = onigWasmB64.split(",")[1];
  const binary = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  await loadWASM(binary.buffer);
  initialized = true;
}

/**
 * Tokenize `code` using the TextMate grammar supplied as a JSON string.
 *
 * A fresh Registry is created for each call so there is no cross-render
 * state. Embedded grammar references (`include`) that point to other
 * scope names are silently skipped (returns null from loadGrammar), which
 * means those tokens fall back to the root scope color — acceptable for
 * a preview.
 *
 * @param {string} grammarJSON  Full content of a .tmLanguage.json file
 * @param {string} code         Source file content
 * @returns {Promise<Array<Array<{text: string, scopes: string[]}>>>}
 */
async function tokenize(grammarJSON, code) {
  await ensureInitialized();

  const grammarDef = JSON.parse(grammarJSON);
  const scopeName = grammarDef.scopeName;

  const registry = new Registry({
    onigLib: Promise.resolve({ createOnigScanner, createOnigString }),
    loadGrammar: (name) =>
      name === scopeName ? Promise.resolve(grammarDef) : Promise.resolve(null),
  });

  const grammar = await registry.loadGrammar(scopeName);
  if (!grammar) {
    throw new Error(`Grammar not found for scope: ${scopeName}`);
  }

  const lines = code.split("\n");
  let ruleStack = INITIAL;
  const result = [];

  for (const line of lines) {
    const { tokens, ruleStack: nextStack } = grammar.tokenizeLine(line, ruleStack);
    ruleStack = nextStack;

    result.push(
      tokens.map((t) => ({
        text: line.slice(t.startIndex, t.endIndex),
        scopes: t.scopes,
      }))
    );
  }

  return result;
}

// Expose on window so Swift's callAsyncJavaScript can reach it.
window.tokenize = tokenize;
