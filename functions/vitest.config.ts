import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // These tests drive real Cloud Function handlers against the Firestore
    // emulator, so they are slower than unit tests and must not run in
    // parallel: several of them assert on a shared counter and would race.
    include: ["src/__tests__/**/*.test.ts"],
    fileParallelism: false,
    testTimeout: 30_000,
    hookTimeout: 30_000,
  },
});
