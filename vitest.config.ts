import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  test: {
    // jsdom rather than node: the hook and component tests added for the
    // iPhone UX pass render real React. The pure utility tests are
    // environment-agnostic and run unchanged under it.
    environment: "jsdom",
    include: ["src/**/*.test.ts", "src/**/*.test.tsx"],
    globals: false,
    setupFiles: ["src/test/setup.ts"],
    restoreMocks: true,
  },
});
