/**
 * esbuild.js — build script for the QuickLookCode tokenizer bundles
 *
 * Produces two bundles in QuickLookCodeShared/Resources/:
 *
 *   tokenizer-jsc.js     — JavaScriptCore build (used by the QL extension)
 *                          Native JS regex, fully synchronous, no WASM.
 *                          ~200 KB minified.
 *
 *   tokenizer.bundle.js  — WKWebView build (kept for future use / debugging)
 *                          Uses vscode-oniguruma WASM embedded as base64.
 *                          ~2 MB minified.
 *
 * Usage:
 *   pnpm install       # first time only
 *   pnpm run build     # produces both bundles
 */

import esbuild from "esbuild";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const resources = resolve(__dirname, "../QuickLookCode/QuickLookCodeShared/Resources");
const watchMode = process.argv.includes("--watch");

// ---------------------------------------------------------------------------
// JSC build — used by the extension (JavaScriptCore, synchronous, no WASM)
// ---------------------------------------------------------------------------
const jscCtx = await esbuild.context({
  entryPoints: [resolve(__dirname, "src/tokenizer-jsc.js")],
  bundle: true,
  format: "iife",
  platform: "neutral",
  mainFields: ["module", "main"],  // neutral platform doesn't resolve these by default
  target: ["es2022"],         // JSC on macOS 13 supports ES2022
  outfile: resolve(resources, "tokenizer-jsc.js"),
  minify: !watchMode,
  sourcemap: false,
  logLevel: "info",
});

// ---------------------------------------------------------------------------
// WKWebView build — kept for reference / future use
// ---------------------------------------------------------------------------
const wkCtx = await esbuild.context({
  entryPoints: [resolve(__dirname, "src/tokenizer.js")],
  bundle: true,
  format: "iife",
  platform: "browser",
  target: ["safari16"],
  outfile: resolve(resources, "tokenizer.bundle.js"),
  minify: !watchMode,
  sourcemap: false,
  loader: { ".wasm": "dataurl" },
  logLevel: "info",
});

if (watchMode) {
  await jscCtx.watch();
  await wkCtx.watch();
  console.log("Watching for changes…");
} else {
  await jscCtx.rebuild();
  await wkCtx.rebuild();
  await jscCtx.dispose();
  await wkCtx.dispose();
  console.log(`\nBuilt JSC bundle  → ${resources}/tokenizer-jsc.js`);
  console.log(`Built WKWebView bundle → ${resources}/tokenizer.bundle.js`);
}
