import "./setup";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { EmailSendResult } from "../email";

/**
 * The account-existence oracle that answering identically does not close.
 *
 * `requestPasswordResetCode` returns the same fields for every address, which
 * is the point of the design. It did not take the same *time*: a deliverable
 * address paid a round trip to the email provider and an unknown one returned
 * as soon as the Auth lookup missed. Hundreds of milliseconds, measurable
 * from anywhere, and enough to sort a list of addresses into "has an account"
 * and "does not".
 *
 * Since sending moved to a Cloud Tasks queue the request path does identical
 * work for every address, so what is left to hide is one extra Firestore read
 * rather than a whole provider round trip — which is why the shipping floor
 * is 400 ms rather than 1.5 s. The property under test is unchanged: no
 * usable gap between an address with an account and one without.
 *
 * This file is separate because the floor is read once at module load, so the
 * override has to be in place before `../passwordReset` is imported. The main
 * suite runs with the floor at zero — paying it in wall time on every request
 * test is not worth it — and this is where it is put back.
 */
const FLOOR_MS = 400;
process.env.PASSWORD_RESET_MIN_REQUEST_MS = String(FLOOR_MS);

/** How long the provider is pretended to take for a deliverable address. */
const PROVIDER_MS = 120;

const sendResult: EmailSendResult = {
  sent: true,
  providerMessageId: "timing",
  elapsedMs: PROVIDER_MS,
};

vi.mock("../email", async (importOriginal) => {
  const original = await importOriginal<typeof import("../email")>();
  return {
    ...original,
    // Both senders, so nothing reaches a real provider. See the note in
    // password-reset.test.ts about the 401 that taught us this.
    sendPasswordResetCodeEmail: vi.fn(async () => {
      await new Promise((resolve) => setTimeout(resolve, PROVIDER_MS));
      return sendResult;
    }),
    sendGoogleOnlyNoticeEmail: vi.fn(async () => {
      await new Promise((resolve) => setTimeout(resolve, PROVIDER_MS));
      return sendResult;
    }),
  };
});

// Cloud Tasks is captured, not contacted: the request handler enqueues and
// a real queue call here would fail and turn every sample into an error.
vi.mock("firebase-admin/functions", () => ({
  getFunctions: () => ({
    taskQueue: () => ({ enqueue: async () => {} }),
  }),
}));

const { admin, db } = await import("../platform");
const { callAs, clearRateLimits } = await import("./helpers");
const { requestPasswordResetCodeCallable } = await import("../passwordReset");

const KNOWN = "timing-known@example.com";
const UNKNOWN = "timing-unknown-nobody@example.com";

type RequestResult = { challengeId: string; expiresInSeconds: number };

async function timeRequest(email: string): Promise<number> {
  const startedAt = Date.now();
  await callAs<RequestResult>(requestPasswordResetCodeCallable, null, {
    email,
  });
  return Date.now() - startedAt;
}

describe("password reset request timing", () => {
  beforeEach(async () => {
    await clearRateLimits();
    const snap = await db.collection("passwordResetChallenges").get();
    await Promise.all(snap.docs.map((d) => d.ref.delete()));

    const auth = admin.auth();
    try {
      await auth.deleteUser((await auth.getUserByEmail(KNOWN)).uid);
    } catch {
      // not present
    }
    await auth.createUser({ email: KNOWN, password: "Str0ng!Passw0rd" });
    try {
      await auth.deleteUser((await auth.getUserByEmail(UNKNOWN)).uid);
    } catch {
      // never existed, which is the point
    }
  });

  it("holds an unknown address to the same floor as a deliverable one", async () => {
    const unknown = await timeRequest(UNKNOWN);
    expect(unknown).toBeGreaterThanOrEqual(FLOOR_MS);
  });

  it("holds a deliverable address to the floor too", async () => {
    const known = await timeRequest(KNOWN);
    expect(known).toBeGreaterThanOrEqual(FLOOR_MS);
  });

  it("leaves no usable gap between the two", async () => {
    // Not an assertion that they are equal — they are not, and claiming so
    // would be the same overstatement the code comment avoids. What matters
    // is that the provider round trip no longer pokes out above the floor,
    // so the difference is scheduler noise rather than a signal the size of
    // an HTTP request.
    const known = await timeRequest(KNOWN);
    await clearRateLimits();
    const unknown = await timeRequest(UNKNOWN);

    expect(Math.abs(known - unknown)).toBeLessThan(PROVIDER_MS);
  });
});
