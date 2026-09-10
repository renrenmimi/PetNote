import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

import * as admin from "firebase-admin";
import { describe, expect, it } from "vitest";

import { FieldPath, FieldValue, Timestamp } from "../platform";

/**
 * Guards the one thing that makes the Cloud Functions emulator usable.
 *
 * firebase-tools proxies `firebase-admin` and answers every `admin.firestore`
 * access with `admin.firestore.bind(module)`. `bind()` returns a function that
 * carries none of the original's own properties, so inside that runtime
 * `admin.firestore.FieldValue` is `undefined`, every authenticated callable
 * dies in `assertRateLimit`, and the whole backend can only be tested through
 * a hand-written harness. Importing these three from the
 * `firebase-admin/firestore` subpath instead avoids the proxy entirely.
 *
 * Nothing about that is visible at a call site, so one innocent
 * `admin.firestore.FieldValue.serverTimestamp()` would take the real runtime
 * away again without failing a single behavioural test. Hence this file.
 */
describe("firebase-admin import discipline", () => {
  it("re-exports the same objects the admin namespace exposes", () => {
    // If these ever diverge, the swap would be a behaviour change rather than
    // a pure import change, and the reasoning above stops holding.
    expect(FieldValue).toBe(admin.firestore.FieldValue);
    expect(Timestamp).toBe(admin.firestore.Timestamp);
    expect(FieldPath).toBe(admin.firestore.FieldPath);
  });

  it("has no source file reading these off the admin namespace", () => {
    const srcDir = path.join(__dirname, "..");
    const offenders: string[] = [];

    for (const entry of readdirSync(srcDir, { withFileTypes: true })) {
      if (!entry.isFile() || !entry.name.endsWith(".ts")) continue;
      // platform.ts is where the reasoning lives, in prose.
      if (entry.name === "platform.ts") continue;

      const text = readFileSync(path.join(srcDir, entry.name), "utf8");
      text.split("\n").forEach((line, index) => {
        if (/admin\.firestore\.(FieldValue|Timestamp|FieldPath)\b/.test(line)) {
          offenders.push(`${entry.name}:${index + 1}`);
        }
      });
    }

    expect(
      offenders,
      "import FieldValue/Timestamp/FieldPath from ./platform instead — " +
        "reading them off admin.firestore breaks the functions emulator"
    ).toEqual([]);
  });
});
