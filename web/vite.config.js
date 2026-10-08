import { defineConfig } from "vite";
import { resolve } from "node:path";

// Dev-only mirror of the Vercel rewrite `/r/:token -> /share.html`.
function shareRewrite() {
  return {
    name: "cleared-share-rewrite",
    configureServer(server) {
      server.middlewares.use((req, _res, next) => {
        const match = /^\/r\/([A-Za-z0-9_-]+)\/?(\?.*)?$/.exec(req.url || "");
        if (match) req.url = `/share.html?t=${match[1]}`;
        next();
      });
    },
  };
}

export default defineConfig({
  appType: "mpa",
  plugins: [shareRewrite()],
  build: {
    rollupOptions: {
      input: {
        home: resolve(import.meta.dirname, "index.html"),
        hub: resolve(import.meta.dirname, "hub.html"),
        privacy: resolve(import.meta.dirname, "privacy.html"),
        support: resolve(import.meta.dirname, "support.html"),
        share: resolve(import.meta.dirname, "share.html"),
      },
    },
  },
});
