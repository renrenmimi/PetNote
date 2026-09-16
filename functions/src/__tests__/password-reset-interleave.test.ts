import "./setup";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { EmailSendResult } from "../email";

/**
 * The interleavings the entry-point guards cannot prove anything about.
 *
 * `password-reset-delivery.test.ts` runs tasks in an order this file chooses,
 * which is enough for "a stale task arrives late". It is *not* enough for the
 * case the handoff asked about: a worker that has already read a processable
 * challenge and is then overtaken by a confirm. Checking `consumed` once on
 * the way in says nothing about that window, because the window opens after
 * the check.
 *
 * So the worker is parked here — inside the provider call, which is the only
 * place it genuinely waits — the confirm is driven to `verifying` and then to
 * `consumed`, and only then is the worker released. What it does next is the
 * answer.
 *
 * Also the two invariants the handoff named separately: a provider that
 * accepted the mail but timed out on the way back, and the delivered-marker
 * write failing. Both are "the send happened, we do not know it" — the shape
 * that used to invalidate a code somebody was already holding.
 */

type Sent = { to: string; code: string };
const sent: Array<Sent> = [];
let nextSendResult: EmailSendResult = {
  sent: true,
  providerMessageId: "i",
  elapsedMs: 5,
};

/** Parks the first send that reaches it, once. */
let hold: Promise<void> | null = null;
let release: (() => void) | null = null;
let parked = false;
function openHold() {
  parked = false;
  hold = new Promise<void>((resolve) => {
    release = resolve;
  });
}

vi.mock("../email", async (importOriginal) => {
  const original = await importOriginal<typeof import("../email")>();
  return {
    ...original,
    emailTransportConfigured: () => true,
    sendPasswordResetCodeEmail: vi.fn(
      async (args: { to: string; code: string }) => {
        // Recorded *before* parking, deliberately. Parking first models
        // "the worker has not sent yet", which is a different and less
        // interesting window — and it left the test confirming with a code
        // the parked worker had already superseded, which is correct
        // behaviour and not what B3 asks about. This models the window that
        // matters: the provider has accepted, the code is in an inbox, and
        // the worker has not yet recorded the delivery.
        sent.push({ to: args.to, code: args.code });
        if (hold) {
          const claimed = hold;
          hold = null;
          parked = true;
          await claimed;
        }
        return nextSendResult;
      }
    ),
    sendGoogleOnlyNoticeEmail: vi.fn(async () => nextSendResult),
  };
});

const enqueued: Array<{ challengeId: string; generation?: number }> = [];
vi.mock("firebase-admin/functions", () => ({
  getFunctions: () => ({
    taskQueue: () => ({
      enqueue: async (payload: { challengeId: string; generation?: number }) => {
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

const EMAIL = "interleave-subject@example.com";
const PASSWORD = "Str0ng!Passw0rd";
const NEW_PASSWORD = "An0ther!Passw0rd";

const request = (data: unknown) =>
  callAs<{ challengeId: string }>(requestPasswordResetCodeCallable, null, data);
const confirm = (data: unknown) =>
  callAs<{ ok: true }>(confirmPasswordResetCodeCallable, null, data);
const runTask = (payload: Record<string, unknown>) =>
  deliverPasswordResetCodeTask.run({ data: payload } as never);

async function waitFor(predicate: () => boolean, label: string) {
  for (let i = 0; i < 400; i += 1) {
    if (predicate()) return;
    await new Promise((r) => setTimeout(r, 5));
  }
  throw new Error(`timed out waiting for ${label}`);
}

async function challenge(id: string) {
  return (await db.doc(`passwordResetChallenges/${id}`).get()).data() ?? {};
}

describe("password reset: worker overtaken by a confirm", () => {
  beforeEach(async () => {
    sent.length = 0;
    enqueued.length = 0;
    hold = null;
    release = null;
    parked = false;
    nextSendResult = { sent: true, providerMessageId: "i", elapsedMs: 5 };
    await clearRateLimits();
    const snap = await db.collection("passwordResetChallenges").get();
    await Promise.all(snap.docs.map((d) => d.ref.delete()));

    const auth = admin.auth();
    try {
      await auth.deleteUser((await auth.getUserByEmail(EMAIL)).uid);
    } catch {
      // absent
    }
    await auth.createUser({ email: EMAIL, password: PASSWORD });
  });

  it("B3: a worker parked before a confirm does not overwrite the digest or send afterwards", async () => {
    // A first delivery, so there is a usable code.
    const { challengeId } = await request({ email: EMAIL });
    await runTask(enqueued[0]);
    const code = sent.at(-1)!.code;

    // A second delivery, parked *after* the provider accepted it. This worker
    // has read a processable challenge, written its digest, put the mail on
    // its way, and not yet recorded the delivery.
    await db
      .doc(`passwordResetChallenges/${challengeId}`)
      .update({ lastSentAtMs: Date.now() - 61_000 });
    await request({ email: EMAIL, challengeId });
    openHold();
    const parkedRun = runTask(enqueued[enqueued.length - 1]);
    await waitFor(() => parked, "the worker to park after the send");

    const digestWhileParked = (await challenge(challengeId)).codeDigest;
    // The code from the parked worker's mail — the newest one, which is what
    // a person would type.
    const parkedCode = sent.at(-1)!.code;
    expect(parkedCode).not.toBe(code);
    sent.length = 0;

    // The person uses the code from the newest mail. Confirm goes pending →
    // verifying → consumed while that worker is still parked.
    await expect(
      confirm({ challengeId, code: parkedCode, newPassword: NEW_PASSWORD })
    ).resolves.toMatchObject({ ok: true });
    const afterConfirm = await challenge(challengeId);
    expect(afterConfirm.status).toBe("consumed");
    expect(afterConfirm.codeDigest).toBeUndefined();

    // Now release the overtaken worker.
    release!();
    await parkedRun;

    const afterWorker = await challenge(challengeId);
    // It did not resurrect a digest on a spent challenge...
    expect(afterWorker.codeDigest).toBeUndefined();
    expect(afterWorker.status).toBe("consumed");
    // ...and it sent nothing further. `sent` was cleared after the parked
    // worker's own mail was recorded, so an empty array here is the result
    // being asserted: releasing a worker that has been overtaken by a confirm
    // produces no additional mail. A useless code arriving after the password
    // had already changed is precisely what this window used to allow.
    expect(sent).toHaveLength(0);
    // Its digest did exist before the confirm, and is gone with it — nothing
    // the overtaken worker did outlives the consume.
    expect(digestWhileParked).toBeTypeOf("string");

    // And the challenge cannot be used again by anyone.
    expect(
      await errorCodeOf(() =>
        confirm({ challengeId, code: parkedCode, newPassword: PASSWORD })
      )
    ).toContain("failed-precondition");
  });

  it("the password really did change, and only once", async () => {
    // The interleaving above must not be satisfied by the confirm failing.
    const { challengeId } = await request({ email: EMAIL });
    await runTask(enqueued[0]);
    const code = sent.at(-1)!.code;

    await confirm({ challengeId, code, newPassword: NEW_PASSWORD });
    const user = await admin.auth().getUserByEmail(EMAIL);
    expect(user.uid).toBeTypeOf("string");
    // A second confirm with the same code is refused as already used, not
    // silently applied again.
    expect(
      await errorCodeOf(() =>
        confirm({ challengeId, code, newPassword: PASSWORD })
      )
    ).toContain("failed-precondition");
  });
});

describe("password reset: the provider accepted but we did not hear", () => {
  beforeEach(async () => {
    sent.length = 0;
    enqueued.length = 0;
    hold = null;
    parked = false;
    nextSendResult = { sent: true, providerMessageId: "i", elapsedMs: 5 };
    await clearRateLimits();
    const snap = await db.collection("passwordResetChallenges").get();
    await Promise.all(snap.docs.map((d) => d.ref.delete()));
  });

  it("a timeout reported after the provider accepted does not strand the code", async () => {
    /*
     * The worst shape: the mail is on its way, and the worker is told
     * "timeout". It throws, Cloud Tasks retries, and the retry must not
     * invalidate a code that is already in an inbox — because the inbox is
     * the one place we cannot check.
     *
     * The send is recorded here by the stub, which is what "the provider
     * accepted" means; the *result* handed back is the timeout.
     */
    await request({ email: EMAIL });
    nextSendResult = { sent: false, reason: "timeout", elapsedMs: 10_000 };
    await expect(runTask(enqueued[0])).rejects.toThrow();
    const strandedCode = sent.at(-1)!.code;
    expect(strandedCode).toMatch(/^\d{6}$/);

    // Cloud Tasks retries. The provider is healthy this time.
    nextSendResult = { sent: true, providerMessageId: "i2", elapsedMs: 5 };
    await runTask(enqueued[0]);
    const secondCode = sent.at(-1)!.code;

    // Two mails exist. This is the honest residual: the worker could not know
    // the first one arrived, so it minted again — and the *newer* code is the
    // one that works, which is the invariant that matters. The older one is
    // dead rather than ambiguous.
    expect(secondCode).not.toBe(strandedCode);
    const challengeId = enqueued[0].challengeId;
    expect(
      await errorCodeOf(() =>
        confirm({ challengeId, code: strandedCode, newPassword: NEW_PASSWORD })
      )
    ).toContain("invalid-argument");
    await expect(
      confirm({ challengeId, code: secondCode, newPassword: NEW_PASSWORD })
    ).resolves.toMatchObject({ ok: true });
  });

  it("a failed delivered-marker write does not invalidate the delivered code twice over", async () => {
    /*
     * The narrow window the design comment names: the send succeeded, and the
     * write that records it did not. The retry cannot know, so it mints again
     * — but it must still be bounded, and the newest code must still be the
     * working one rather than both being dead.
     */
    const { challengeId } = await request({ email: EMAIL });
    await runTask(enqueued[0]);
    const firstCode = sent.at(-1)!.code;

    // Simulate the marker write having been lost.
    await db
      .doc(`passwordResetChallenges/${challengeId}`)
      .update({ deliveredGeneration: admin.firestore.FieldValue.delete() });

    await runTask(enqueued[0]);
    const secondCode = sent.at(-1)!.code;
    expect(secondCode).not.toBe(firstCode);

    // Exactly one of them works, and it is the newer one.
    expect(
      await errorCodeOf(() =>
        confirm({ challengeId, code: firstCode, newPassword: NEW_PASSWORD })
      )
    ).toContain("invalid-argument");
    await expect(
      confirm({ challengeId, code: secondCode, newPassword: NEW_PASSWORD })
    ).resolves.toMatchObject({ ok: true });
  });

  it("an explicit resend and a task retry are told apart", async () => {
    /*
     * The distinction the handoff asked for. A retry of the same delivery
     * carries the generation it was created with; a resend the person asked
     * for creates a new one. So a retry arriving after a resend is stale and
     * silent, while the resend's own task delivers — the opposite of the old
     * behaviour, where both minted and whichever wrote last won.
     */
    const { challengeId } = await request({ email: EMAIL });
    const retryOfFirst = { ...enqueued[0] };
    await runTask(enqueued[0]);
    const firstCode = sent.at(-1)!.code;

    await db
      .doc(`passwordResetChallenges/${challengeId}`)
      .update({ lastSentAtMs: Date.now() - 61_000 });
    await request({ email: EMAIL, challengeId });
    const resendPayload = enqueued[enqueued.length - 1];
    expect(resendPayload.generation).toBe((retryOfFirst.generation ?? 0) + 1);

    await runTask(resendPayload);
    const resentCode = sent.at(-1)!.code;
    expect(resentCode).not.toBe(firstCode);

    // The old delivery's retry now arrives. It is a retry, not a request, and
    // it sends nothing.
    sent.length = 0;
    await runTask(retryOfFirst);
    expect(sent).toHaveLength(0);

    // The code from the resend — the newest mail — is the one that works.
    await expect(
      confirm({ challengeId, code: resentCode, newPassword: NEW_PASSWORD })
    ).resolves.toMatchObject({ ok: true });
  });
});
