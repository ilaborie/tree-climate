import { defineConfig } from "vite";

// Vite owns the assets and nothing else. The 358 HTML pages are written by
// `tree-climate site`, which reads the manifest below to learn the hashed
// filenames -- so `mise run site` builds this first.
//
// Bundling MiniSearch rather than loading it from a CDN removes the pinned
// version, the subresource-integrity hash, and the fallback path for when the
// CDN is blocked. The site is now self-contained and works offline.
export default defineConfig({
  root: import.meta.dirname,
  build: {
    outDir: "../site/assets",
    // Flat: the output directory is already the assets directory.
    assetsDir: ".",
    emptyOutDir: true,
    manifest: true,
    rollupOptions: {
      input: "src/main.js",
    },
  },
});
