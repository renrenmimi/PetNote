import { defineConfig } from "vitest/config";

// Firestore rules tests run against the emulator and share one RulesTestEnvironment
// per file, so they must not run in parallel: seeding for one test would land
// while another is asserting.
export default defineConfig({
  test: {
    environment: "node",
    include: ["tests/rules/**/*.test.ts"],
    globals: false,
    fileParallelism: false,
    testTimeout: 30_000,
    hookTimeout: 30_000,
  },
});
