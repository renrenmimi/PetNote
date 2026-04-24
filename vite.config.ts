import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  // Remove stray debug logging and the debugger keyword from production
  // builds. console.warn / console.error are deliberately kept so
  // runtime issues still surface in the browser devtools.
  esbuild: {
    pure: ["console.log", "console.debug", "console.info"],
    drop: ["debugger"],
  },
});
