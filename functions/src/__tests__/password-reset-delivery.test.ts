import "./setup";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { EmailSendResult } from "../email";

/**
 * Deterministic failure injection for the delivery worker.
 *
 * These are the five concurrency questions from the handoff, each written as
 * a test that either reproduces the problem or shows it cannot happen. None
 * of them is asserted as an attack until it runs.
 *
 * The queue is a list here, so "the task ran twice", "two tasks ran
 * interleaved" and "a task ran after the challenge moved on" are all just
 * calls in an order this file chooses.
 */

type Sent = { to: string; code: string };
const sent: Array<Sent> = [];
const notices: Array<{ to: string }> = [];
let nextSendResult: EmailSendResult = {
  sent: true,
  providerMessageId: "d",
  elapsedMs: 5,
};
/**
 * Lets a test hold a send open, to interleave two workers.
 *
 * My first version of this reassigned a single `gate` variable from both the
 * test and the mock, and deadlocked: the parked worker never reached the line
 * that would have told the test it had parked. An explicit promise plus a
 * `parked` flag is the same idea without the race, and the B2 result below is
 * only trustworthy because of it.
 */
let hold: { promise: Promise<void>; release: () => void } | null = null;
let parked = false;

let release: (() => void) | null = null;

function openHold() {
  const promise = new Promise<void>((resolve) => {
    release = resolve;
  });
  hold = { promise, release: () => release?.() };
  parked = false;
}

vi.mock("../email", async (importOriginal) => {
  const original = await importOriginal<typeof import("../email")>();
  return {
    ...original,
    emailTransportConfigured: () => true,
    sendPasswordResetCodeEmail: vi.fn(
      async (args: { to: string; code: string }) => {
        // Single use: the hold is claimed by the first send that reaches it
        // and cleared immediately, so the *second* worker in the interleaving
        // test runs straight through. Leaving it set parked both workers and
        // deadlocked — which is how the first version of this file produced a
        // 30 s timeout that looked like a finding and was not one.
        if (hold) {
          const claimed = hold;
          hold = null;
          parked = true;
          await claimed.promise;
        }
        sent.push({ to: args.to, code: args.code });
        return nextSendResult;
      }
    ),
    sendGoogleOnlyNoticeEmail: vi.fn(async (args: { to: string }) => {
      notices.push(args);
      return nextSendResult;
    }),
  };
});

const enqueued: Array<Record<string, unknown>> = [];
vi.mock("firebase-admin/functions", () => ({
  getFunctions: () => ({
    taskQueue: () => ({
      enqueue: async (payload: Record<string, unknown>) => {
        enqueued.push(payload);
      },
    }),
  }),
}));

const { admin, db } = await import("../platform");
const { callAs, clearRateLimits, errorCodeOf } = await import("./helpers");
const {
  confirmPasswordResetCodeCallable,
  deliverPasswordResetCodeTask,
  requestPasswordResetCodeCallable,
} = await import("../passwordReset");

const EMAIL = "delivery-subject@example.com";
const PASSWORD = "Str0ng!Passw0rd";
const NEW_PASSWORD = "An0ther!Passw0rd";

const request = (data: unknown) =>
  callAs<{ challengeId: string }>(requestPasswordResetCodeCallable, null, data);
const confirm = (data: unknown) =>
  callAs<{ ok: true }>(confirmPasswordResetCodeCallable, null, data);

/** Runs one queued task. Nothing drains automatically. */
const runTask = (payload: Record<string, unknown>) =>
  deliverPasswordResetCodeTask.run({ data: payload } as never);

async function ensureUser() {
  const auth = admin.auth();
  try {
    await auth.deleteUser((await auth.getUserByEmail(EMAIL)).uid);
  } catch {
    // absent
  }
  await auth.createUser({ email: EMAIL, password: PASSWORD });
}

async function challenge(id: string) {
  return (await db.doc(`passwordResetChallenges/${id}`).get()).data() ?? {};
}

describe("password reset delivery under concurrency", () => {
  beforeEach(async () => {
    sent.length = 0;
    notices.length = 0;
    enqueued.length = 0;
    hold = null;
    parked = false;
    nextSendResult = { sent: true, providerMessageId: "d", elapsedMs: 5 };
    await clearRateLimits();
    const snap = await db.collection("passwordResetChallenges").get();
    await Promise.all(snap.docs.map((d) => d.ref.delete()));
    await ensureUser();
  });

  it("B1: a retry after a successful send does not invalidate the delivered code", async () => {
    // The task succeeded but Cloud Tasks did not see the acknowledgement, so
    // it runs the task again. The person is holding an email with a code they
    // have not used yet.
    const { challengeId } = await request({ email: EMAIL });
    const payload = enqueued[0];
    await runTask(payload);
    const firstCode = sent.at(-1)!.code;

    // Same task, again. At-least-once means this is not hypothetical.
    await runTask(payload);

    // No second email, and the code they are holding still works.
    expect(sent).toHaveLength(1);
    await expect(
      confirm({ challengeId, code: firstCode, newPassword: NEW_PASSWORD })
    ).resolves.toMatchObject({ ok: true });
  });

  it("B2: the newest email is the one that works", async () => {
    // Two deliveries in flight: the first task is held open inside the
    // provider call while the person asks for a resend, so the two workers
    // interleave and the digest writes can land in either order.
    const { challengeId } = await request({ email: EMAIL });
    const firstPayload = enqueued[0];

    openHold();
    const firstRun = runTask(firstPayload);
    // Wait until the first worker is actually parked inside the send.
    for (let i = 0; i < 200 && !parked; i += 1) {
      await new Promise((r) => setTimeout(r, 5));
    }
    expect(parked).toBe(true);

    // Past the cooldown, ask again. This is the generation that must win.
    await db
      .doc(`passwordResetChallenges/${challengeId}`)
      .update({ lastSentAtMs: Date.now() - 61_000 });
    await request({ email: EMAIL, challengeId });
    const secondPayload = enqueued[enqueued.length - 1];
    await runTask(secondPayload);
    const newestCode = sent.at(-1)!.code;

    // Now let the stale worker finish.
    release!();
    await firstRun;

    // Whatever order the writes landed in, the code from the newest email is
    // the one that verifies.
    await expect(
      confirm({ challengeId, code: newestCode, newPassword: NEW_PASSWORD })
    ).resolves.toMatchObject({ ok: true });
  });

  it("B3: a task that ran before a confirm does not mail a useless code afterwards", async () => {
    const { challengeId } = await request({ email: EMAIL });
    const payload = enqueued[0];
    await runTask(payload);
    const code = sent.at(-1)!.code;

    // The person used the code. The challenge is spent.
    await confirm({ challengeId, code, newPassword: NEW_PASSWORD });
    expect((await challenge(challengeId)).status).toBe("consumed");

    sent.length = 0;
    // A duplicate dispatch of the same task arrives after all that.
    await runTask(payload);

    // Nothing is mailed, and the finished challenge is not rewritten.
    expect(sent).toHaveLength(0);
    expect((await challenge(challengeId)).status).toBe("consumed");
    expect((await challenge(challengeId)).codeDigest).toBeUndefined();
  });

  it("B4: the send cap counts send attempts, not user requests", async () => {
    // One request, then a retry storm. `sendCount` is incremented by the
    // request handler, so a check against it alone bounds how many times a
    // person asked — not how many emails the queue can produce.
    const { challengeId } = await request({ email: EMAIL });
    const payload = enqueued[0];

    nextSendResult = { sent: false, reason: "provider-error", elapsedMs: 5 };
    let thrown = 0;
    for (let i = 0; i < 8; i += 1) {
      try {
        await runTask(payload);
      } catch {
        thrown += 1;
      }
    }

    const stored = await challenge(challengeId);
    // Whatever the number is, it has to be bounded by something the worker
    // itself counts.
    expect(stored.sendAttempts).toBeLessThanOrEqual(5);
    expect(thrown).toBeLessThanOrEqual(5);
  });

  it("B5: a stale task cannot send against a newer challenge state", async () => {
    const { challengeId } = await request({ email: EMAIL });
    const stalePayload = enqueued[0];

    await db
      .doc(`passwordResetChallenges/${challengeId}`)
      .update({ lastSentAtMs: Date.now() - 61_000 });
    await request({ email: EMAIL, challengeId });
    const freshPayload = enqueued[enqueued.length - 1];

    await runTask(freshPayload);
    const freshCode = sent.at(-1)!.code;
    sent.length = 0;

    // The old task finally gets dispatched.
    await runTask(stalePayload);

    // It sent nothing, and did not disturb the code that is in an inbox.
    expect(sent).toHaveLength(0);
    await expect(
      confirm({ challengeId, code: freshCode, newPassword: NEW_PASSWORD })
    ).resolves.toMatchObject({ ok: true });
  });

  it("still delivers a code for an ordinary single request", async () => {
    // The control: none of the above may be achieved by never sending.
    const { challengeId } = await request({ email: EMAIL });
    await runTask(enqueued[0]);
    expect(sent).toHaveLength(1);
    expect(sent[0].code).toMatch(/^\d{6}$/);
    expect(sent[0].to).toBe(EMAIL);
    await expect(
      confirm({ challengeId, code: sent[0].code, newPassword: NEW_PASSWORD })
    ).resolves.toMatchObject({ ok: true });
  });

  it("still retries a genuine send failure", async () => {
    nextSendResult = { sent: false, reason: "timeout", elapsedMs: 10_000 };
    await request({ email: EMAIL });
    await expect(runTask(enqueued[0])).rejects.toThrow();
  });

  it("still refuses an expired challenge", async () => {
    const { challengeId } = await request({ email: EMAIL });
    await db
      .doc(`passwordResetChallenges/${challengeId}`)
      .update({ expiresAtMs: Date.now() - 1 });
    await runTask(enqueued[0]);
    expect(sent).toHaveLength(0);
  });

  it("still says nothing different for an address with no account", async () => {
    await request({ email: "delivery-nobody@example.com" });
    expect(enqueued).toHaveLength(1);
    await runTask(enqueued[0]);
    expect(sent).toHaveLength(0);
    expect(notices).toHaveLength(0);
  });

  it("keeps the wrong-code path intact", async () => {
    const { challengeId } = await request({ email: EMAIL });
    await runTask(enqueued[0]);
    const code = sent.at(-1)!.code;
    const wrong = code === "000000" ? "111111" : "000000";
    expect(
      await errorCodeOf(() =>
        confirm({ challengeId, code: wrong, newPassword: NEW_PASSWORD })
      )
    ).toContain("invalid-argument");
  });
});
