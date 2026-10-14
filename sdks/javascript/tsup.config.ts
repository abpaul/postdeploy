import { defineConfig } from "tsup";

/**
 * Four independent bundles, one per subpath export (docs/sdk/01-sdk-spec.md
 * section 1, heartbeat-v2 contract "SDK" section). Each entry is bundled
 * standalone (tsup/esbuild default) so every dist/<adapter>/index.js is
 * self-contained -- no cross-bundle relative imports at runtime, even though
 * the adapters re-export from ../core in source.
 *
 * Ships only the neutral/node/cloudflare/core ESM(+CJS for node) outputs;
 * no IIFE/UMD build yet. That ships alongside automatic browser
 * instrumentation (window.onerror etc.), which v0.2.x does not implement --
 * see README's scope note. Until then, browser consumers are expected to
 * use a bundler or `<script type="module">`.
 */
export default defineConfig([
  {
    name: "browser",
    entry: { index: "src/browser/index.ts" },
    outDir: "dist/browser",
    format: ["esm"],
    platform: "browser",
    target: "es2022",
    dts: true,
    clean: true,
    sourcemap: true,
    splitting: false,
  },
  {
    name: "node",
    entry: { index: "src/node/index.ts" },
    outDir: "dist/node",
    format: ["esm", "cjs"],
    platform: "node",
    target: "node18",
    dts: true,
    clean: true,
    sourcemap: true,
    splitting: false,
  },
  {
    name: "cloudflare",
    entry: { index: "src/cloudflare/index.ts" },
    outDir: "dist/cloudflare",
    format: ["esm"],
    platform: "neutral",
    target: "es2022",
    dts: true,
    clean: true,
    sourcemap: true,
    splitting: false,
  },
  {
    name: "core",
    entry: { index: "src/core/index.ts" },
    outDir: "dist/core",
    format: ["esm"],
    platform: "neutral",
    target: "es2022",
    dts: true,
    clean: true,
    sourcemap: true,
    splitting: false,
  },
]);
