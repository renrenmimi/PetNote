import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  build: {
    // HEIC conversion is isolated into a lazy feature chunk. Keep the warning
    // threshold above that known payload so new app/vendor regressions still show.
    chunkSizeWarningLimit: 1400,
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (!id.includes("node_modules")) return;

          if (id.includes("node_modules/heic2any")) {
            return "vendor-heic";
          }
          if (
            id.includes("node_modules/firebase") ||
            id.includes("node_modules/@firebase")
          ) {
            return "vendor-firebase";
          }
          if (
            id.includes("node_modules/react") ||
            id.includes("node_modules/react-dom") ||
            id.includes("node_modules/scheduler")
          ) {
            return "vendor-react";
          }
          if (id.includes("node_modules/react-router")) {
            return "vendor-router";
          }
          if (id.includes("node_modules/lucide-react")) {
            return "vendor-icons";
          }
        },
      },
    },
  },
  // Remove stray debug logging and the debugger keyword from production
  // builds. console.warn / console.error are deliberately kept so
  // runtime issues still surface in the browser devtools.
  esbuild: {
    pure: ["console.log", "console.debug", "console.info"],
    drop: ["debugger"],
  },
});
