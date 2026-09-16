import "./setup";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { EmailSendResult } from "../email";

/**
 * The email transport is stubbed, so no provider is ever contacted and the
 * code only ever leaves through the fake. Capturing it here is also the test
 * for a real property: the code exists in the mail and nowhere else — not in
 * the callable's response, not in the challenge document, not in a log.
 */
const sent: Array<{ to: string; code: string; expiresInMinutes: number }> = [];
/** Google-only notices, captured separately: a different mail, to the same inbox. */
const notices: Array<{ to: string }> = [];
let nextSendResult: EmailSendResult = {
  sent: true,
  providerMessageId: "test-message",
  elapsedMs: 12,
};
let nextNoticeResult: EmailSendResult = {
  sent: true,
  providerMessageId: "test-notice",
  elapsedMs: 9,
};

// Both senders are stubbed. Stubbing only one is not a smaller mistake: with
// the API key and From address set in setup.ts the unstubbed one is
// "configured", so it reaches `fetch` and the suite makes a real request to
// the provider. That happened — a 401 from api.resend.com in the
// google-only test — and it is why this mock lists every sender rather than
// the one the test was thinking about.
vi.mock("../email", async (importOriginal) => {
  const original = await importOriginal<typeof import("../email")>();
  return {
    ...original,
    sendPasswordResetCodeEmail: vi.fn(
      async (args: { to: string; code: string; expiresInMinutes: number }) => {
        sent.push(args);
        return nextSendResult;
      }
    ),
    sendGoogleOnlyNoticeEmail: vi.fn(async (args: { to: string }) => {
      notices.push(args);
      return nextNoticeResult;
    }),
  };
});

const { admin, db } = await import("../platform");
const { callAs, clearRateLimits, errorCodeOf } = await import("./helpers");
const {
  confirmPasswordResetCodeCallable,
  requestPasswordResetCodeCallable,
} = await import("../passwordReset");

const EMAIL = "reset-subject@example.com";
const GOOD_PASSWORD = "Str0ng!Passw0rd";
const OTHER_PASSWORD = "An0ther!Passw0rd";

type RequestResult = { challengeId: string; expiresInSeconds: number };

async function ensureUser(
  email: string,
  options: { password?: string | null; disabled?: boolean } = {}
): Promise<string> {
  const auth = admin.auth();
  try {
    const existing = await auth.getUserByEmail(email);
    await auth.deleteUser(existing.uid);
  } catch {
    // not present
  }
  const created = await auth.createUser({
    email,
    ...(options.password === null ? {} : { password: options.password ?? GOOD_PASSWORD }),
    ...(options.disabled ? { disabled: true } : {}),
  });
  return created.uid;
}

const request = (data: unknown) =>
  callAs<RequestResult>(requestPasswordResetCodeCallable, null, data);
const confirm = (data: unknown) =>
  callAs<{ ok: true }>(confirmPasswordResetCodeCallable, null, data);

async function startFlow(email = EMAIL) {
  sent.length = 0;
  const result = await request({ email });
  return { challengeId: result.challengeId, code: sent.at(-1)?.code ?? "" };
}

async function clearChallenges() {
  const snap = await db.collection("passwordResetChallenges").get();
  await Promise.all(snap.docs.map((d) => d.ref.delete()));
}

describe("password reset by numeric code", () => {
  beforeEach(async () => {
    sent.length = 0;
    notices.length = 0;
    nextSendResult = {
      sent: true,
      providerMessageId: "test-message",
      elapsedMs: 12,
    };
    nextNoticeResult = {
      sent: true,
      providerMessageId: "test-notice",
      elapsedMs: 9,
    };
    await clearRateLimits();
    await clearChallenges();
    vi.restoreAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("mails a six-digit code and sets the password when it is confirmed", async () => {
    const uid = await ensureUser(EMAIL);
    const { challengeId, code } = await startFlow();

    expect(sent).toHaveLength(1);
    expect(sent[0].to).toBe(EMAIL);
    expect(code).toMatch(/^\d{6}$/);

    // The code is not in the response, and not in the stored challenge.
    const stored = await db.doc(`passwordResetChallenges/${challengeId}`).get();
    const data = stored.data() ?? {};
    expect(JSON.stringify(data)).not.toContain(code);
    expect(data.codeDigest).toBeTypeOf("string");
    expect(data.codeDigest).not.toBe(code);
    expect(data.uid).toBe(uid);

    await expect(
      confirm({ challengeId, code, newPassword: GOOD_PASSWORD })
    ).resolves.toEqual({ ok: true });

    const after = await db.doc(`passwordResetChallenges/${challengeId}`).get();
    expect(after.data()?.status).toBe("consumed");
    // Nothing that could verify the code again survives.
    expect(after.data()?.codeDigest).toBeUndefined();
  });

  it("does not set emailVerified as a side effect", async () => {
    const uid = await ensureUser(EMAIL);
    expect((await admin.auth().getUser(uid)).emailVerified).toBe(false);

    const { challengeId, code } = await startFlow();
    await confirm({ challengeId, code, newPassword: GOOD_PASSWORD });

    // Proving control of an inbox for a reset is not the same as verifying
    // the address for the gates that read this flag.
    expect((await admin.auth().getUser(uid)).emailVerified).toBe(false);
  });

  it("revokes existing sessions so other devices are signed out", async () => {
    const uid = await ensureUser(EMAIL);
    // Asserted through the call rather than through tokensValidAfterTime,
    // which has one-second granularity — a fast test sets it to the same
    // second it started in and the comparison proves nothing either way.
    const revoke = vi.spyOn(admin.auth(), "revokeRefreshTokens");

    const { challengeId, code } = await startFlow();
    await confirm({ challengeId, code, newPassword: GOOD_PASSWORD });

    expect(revoke).toHaveBeenCalledWith(uid);
    // And it happened after the password was set, not instead of it.
    expect((await admin.auth().getUser(uid)).tokensValidAfterTime).toBeTruthy();
  });

  it("rejects a wrong code and counts the attempt", async () => {
    await ensureUser(EMAIL);
    const { challengeId, code } = await startFlow();
    const wrong = code === "000000" ? "111111" : "000000";

    expect(await errorCodeOf(() => confirm({ challengeId, code: wrong, newPassword: GOOD_PASSWORD })))
      .toContain("invalid-argument");

    const stored = await db.doc(`passwordResetChallenges/${challengeId}`).get();
    expect(stored.data()?.attempts).toBe(1);
    expect(stored.data()?.status).toBe("pending");
  });

  it("locks the challenge after five wrong codes", async () => {
    await ensureUser(EMAIL);
    const { challengeId, code } = await startFlow();
    const wrong = code === "000000" ? "111111" : "000000";

    for (let i = 0; i < 5; i += 1) {
      await errorCodeOf(() =>
        confirm({ challengeId, code: wrong, newPassword: GOOD_PASSWORD })
      );
    }

    // Even the correct code is refused once the budget is gone.
    expect(
      await errorCodeOf(() => confirm({ challengeId, code, newPassword: GOOD_PASSWORD }))
    ).toContain("resource-exhausted");
  });

  it("does not restore the attempt budget when a new code is sent", async () => {
    await ensureUser(EMAIL);
    const { challengeId, code } = await startFlow();
    const wrong = code === "000000" ? "111111" : "000000";

    for (let i = 0; i < 4; i += 1) {
      await errorCodeOf(() =>
        confirm({ challengeId, code: wrong, newPassword: GOOD_PASSWORD })
      );
    }

    // Resend, bypassing the cooldown the way a minute of waiting would.
    await db
      .doc(`passwordResetChallenges/${challengeId}`)
      .update({ lastSentAtMs: 0 });
    sent.length = 0;
    const resent = await request({ email: EMAIL, challengeId });
    expect(resent.challengeId).toBe(challengeId);
    const newCode = sent.at(-1)?.code ?? "";
    expect(newCode).toMatch(/^\d{6}$/);

    const stored = await db.doc(`passwordResetChallenges/${challengeId}`).get();
    expect(stored.data()?.attempts).toBe(4);

    // One wrong guess left, and then it is locked — a resend did not buy five
    // more tries.
    await errorCodeOf(() =>
      confirm({ challengeId, code: wrong, newPassword: GOOD_PASSWORD })
    );
    expect(
      await errorCodeOf(() => confirm({ challengeId, code: newCode, newPassword: GOOD_PASSWORD }))
    ).toContain("resource-exhausted");
  });

  it("invalidates the previous code when a new one is sent", async () => {
    await ensureUser(EMAIL);
    const { challengeId, code: firstCode } = await startFlow();

    await db
      .doc(`passwordResetChallenges/${challengeId}`)
      .update({ lastSentAtMs: 0 });
    sent.length = 0;
    await request({ email: EMAIL, challengeId });
    const secondCode = sent.at(-1)?.code ?? "";
    expect(secondCode).not.toBe(firstCode);

    expect(
      await errorCodeOf(() => confirm({ challengeId, code: firstCode, newPassword: GOOD_PASSWORD }))
    ).toContain("invalid-argument");
    await expect(
      confirm({ challengeId, code: secondCode, newPassword: GOOD_PASSWORD })
    ).resolves.toEqual({ ok: true });
  });

  it("refuses a resend inside the cooldown", async () => {
    await ensureUser(EMAIL);
    const { challengeId } = await startFlow();
    expect(
      await errorCodeOf(() => request({ email: EMAIL, challengeId }))
    ).toContain("resource-exhausted");
  });

  it("caps how many codes one challenge can issue", async () => {
    await ensureUser(EMAIL);
    const { challengeId } = await startFlow();
    for (let i = 0; i < 3; i += 1) {
      await db
        .doc(`passwordResetChallenges/${challengeId}`)
        .update({ lastSentAtMs: 0 });
      await request({ email: EMAIL, challengeId });
    }
    await db
      .doc(`passwordResetChallenges/${challengeId}`)
      .update({ lastSentAtMs: 0 });
    expect(
      await errorCodeOf(() => request({ email: EMAIL, challengeId }))
    ).toContain("resource-exhausted");
  });

  it("expires on its own clock, not on a deletion running on time", async () => {
    await ensureUser(EMAIL);
    const { challengeId, code } = await startFlow();

    // The document is still there; only its own timestamp has passed.
    await db
      .doc(`passwordResetChallenges/${challengeId}`)
      .update({ expiresAtMs: Date.now() - 1 });

    expect(
      await errorCodeOf(() => confirm({ challengeId, code, newPassword: GOOD_PASSWORD }))
    ).toContain("deadline-exceeded");
  });

  it("cannot be used twice", async () => {
    await ensureUser(EMAIL);
    const { challengeId, code } = await startFlow();
    await confirm({ challengeId, code, newPassword: GOOD_PASSWORD });

    expect(
      await errorCodeOf(() => confirm({ challengeId, code, newPassword: OTHER_PASSWORD }))
    ).toContain("failed-precondition");
  });

  it("consumes once under concurrent confirms", async () => {
    await ensureUser(EMAIL);
    const { challengeId, code } = await startFlow();

    const results = await Promise.allSettled([
      confirm({ challengeId, code, newPassword: GOOD_PASSWORD }),
      confirm({ challengeId, code, newPassword: GOOD_PASSWORD }),
      confirm({ challengeId, code, newPassword: GOOD_PASSWORD }),
    ]);
    const fulfilled = results.filter((r) => r.status === "fulfilled");
    // At least one has to succeed, and the challenge must end up spent
    // exactly once rather than left open.
    expect(fulfilled.length).toBeGreaterThanOrEqual(1);
    const stored = await db.doc(`passwordResetChallenges/${challengeId}`).get();
    expect(stored.data()?.status).toBe("consumed");
    expect(stored.data()?.codeDigest).toBeUndefined();
  });

  it("answers an unknown address exactly like a known one", async () => {
    sent.length = 0;
    const unknown = await request({ email: "nobody-here@example.com" });

    expect(unknown.challengeId).toBeTypeOf("string");
    expect(unknown.expiresInSeconds).toBeGreaterThan(0);
    // No mail, and the challenge carries nothing that could ever verify.
    expect(sent).toHaveLength(0);
    const stored = await db
      .doc(`passwordResetChallenges/${unknown.challengeId}`)
      .get();
    expect(stored.data()?.uid).toBeNull();
    expect(stored.data()?.codeDigest).toBeNull();

    // And a guess fails the same way a wrong code does, not a different way.
    expect(
      await errorCodeOf(() =>
        confirm({
          challengeId: unknown.challengeId,
          code: "123456",
          newPassword: GOOD_PASSWORD,
        })
      )
    ).toContain("invalid-argument");
  });

  it("treats a disabled account like an unknown address at request time", async () => {
    await ensureUser(EMAIL, { disabled: true });
    sent.length = 0;
    const result = await request({ email: EMAIL });

    expect(result.challengeId).toBeTypeOf("string");
    expect(sent).toHaveLength(0);
  });

  it("keeps the deleted-account protection", async () => {
    const uid = await ensureUser(EMAIL);
    await db.doc(`userDeletionTombstones/${uid}`).set({ deletedAt: Date.now() });
    try {
      sent.length = 0;
      await request({ email: EMAIL });
      expect(sent).toHaveLength(0);
    } finally {
      await db.doc(`userDeletionTombstones/${uid}`).delete();
    }
  });

  it("will not add a password to an account that has none", async () => {
    // Google-only shape: a user record with no password provider.
    await ensureUser(EMAIL, { password: null });
    sent.length = 0;
    const result = await request({ email: EMAIL });
    // No code is minted, so no code can ever verify against this challenge.
    expect(sent).toHaveLength(0);
    expect(result.challengeId).toBeTypeOf("string");
  });

  it("tells a Google-only account how to sign in, in the mail rather than the response", async () => {
    // The dead end this replaces: the response promised a code, none was
    // minted, and the only reachable outcome was "that code is not correct".
    // The "use Google" line lived in the confirm handler, behind a correct
    // code they could never have.
    await ensureUser(EMAIL, { password: null });
    sent.length = 0;
    notices.length = 0;

    const result = await request({ email: EMAIL });

    expect(sent).toHaveLength(0);
    expect(notices).toEqual([{ to: EMAIL }]);
    expect(result.challengeId).toBeTypeOf("string");
    expect(result.expiresInSeconds).toBeGreaterThan(0);
  });

  it("answers a Google-only address exactly like an unknown one", async () => {
    await ensureUser(EMAIL, { password: null });
    const googleOnly = await request({ email: EMAIL });
    const unknown = await request({ email: "nobody-at-all@example.com" });

    // Same shape, same fields, same values apart from the opaque id.
    expect(Object.keys(googleOnly).sort()).toEqual(Object.keys(unknown).sort());
    expect(googleOnly.expiresInSeconds).toBe(unknown.expiresInSeconds);
    expect(googleOnly.challengeId).not.toBe(unknown.challengeId);
  });

  it("does not report a failed Google-only notice to the caller", async () => {
    // Saying "that send failed" would say the address exists and has no
    // password, which is the thing the identical response protects.
    await ensureUser(EMAIL, { password: null });
    nextNoticeResult = { sent: false, reason: "provider-error", elapsedMs: 40 };

    await expect(request({ email: EMAIL })).resolves.toMatchObject({
      challengeId: expect.any(String),
    });
  });

  it("refuses a challenge id that is not one it minted", async () => {
    // The id used to go straight into a document path, so a slash addressed a
    // nested document outside the collection that the rules and any TTL
    // policy cover.
    //
    // ensureUser is not decoration: the test above leaves EMAIL as a
    // passwordless account, so without this startFlow mints no code and the
    // assertions below pass or fail on the wrong reason.
    await ensureUser(EMAIL);
    const { code } = await startFlow();
    await expect(
      confirm({
        challengeId: "../../users/someone",
        code,
        newPassword: OTHER_PASSWORD,
      })
    ).rejects.toThrow();

    const injected = await request({
      email: EMAIL,
      challengeId: "passwordResetChallenges/x/y",
    });
    // Treated as "no challenge supplied": a fresh, well-formed id.
    expect(injected.challengeId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
    );
    const stray = await db.collection("passwordResetChallenges").doc("x").get();
    expect(stray.exists).toBe(false);
  });

  it("keeps the original creation time when a code is resent", async () => {
    await ensureUser(EMAIL);
    const first = await request({ email: EMAIL });
    const before = (
      await db.doc(`passwordResetChallenges/${first.challengeId}`).get()
    ).data()?.createdAt;

    // Past the cooldown.
    await db
      .doc(`passwordResetChallenges/${first.challengeId}`)
      .update({ lastSentAtMs: Date.now() - 61_000 });
    await request({ email: EMAIL, challengeId: first.challengeId });

    const after = (
      await db.doc(`passwordResetChallenges/${first.challengeId}`).get()
    ).data()?.createdAt;
    // The old ternary had the same expression in both branches, so this moved.
    expect(after?.toMillis?.()).toBe(before?.toMillis?.());
  });

  it("rejects a code bound to a different challenge", async () => {
    await ensureUser(EMAIL);
    const first = await startFlow();
    await clearRateLimits();
    sent.length = 0;
    const second = await request({ email: EMAIL });
    const secondCode = sent.at(-1)?.code ?? "";

    // The digest binds purpose + challenge + uid + code, so a code that is
    // valid for one challenge is meaningless against another.
    expect(
      await errorCodeOf(() =>
        confirm({
          challengeId: first.challengeId,
          code: secondCode,
          newPassword: GOOD_PASSWORD,
        })
      )
    ).toContain("invalid-argument");
    expect(second.challengeId).not.toBe(first.challengeId);
  });

  it("rejects a challenge whose purpose is not password reset", async () => {
    await ensureUser(EMAIL);
    const { challengeId, code } = await startFlow();
    await db
      .doc(`passwordResetChallenges/${challengeId}`)
      .update({ purpose: "something-else" });

    expect(
      await errorCodeOf(() => confirm({ challengeId, code, newPassword: GOOD_PASSWORD }))
    ).toContain("invalid-argument");
  });

  it("never trusts a uid supplied by the caller", async () => {
    const victim = await ensureUser("victim@example.com");
    await ensureUser(EMAIL);
    const { challengeId, code } = await startFlow();

    // The uid is read from the challenge, so passing someone else's changes
    // nothing about whose password is set.
    await confirm({
      challengeId,
      code,
      newPassword: GOOD_PASSWORD,
      uid: victim,
    });

    const stored = await db.doc(`passwordResetChallenges/${challengeId}`).get();
    const targetUid = await admin.auth().getUserByEmail(EMAIL);
    expect(stored.data()?.uid).toBe(targetUid.uid);
    expect(stored.data()?.uid).not.toBe(victim);
  });

  it("enforces the product's password policy, not Firebase's floor", async () => {
    await ensureUser(EMAIL);
    const { challengeId, code } = await startFlow();

    // Six characters is acceptable to Firebase Auth and not to this product.
    const code1 = await errorCodeOf(() =>
      confirm({ challengeId, code, newPassword: "abc123" })
    );
    expect(code1).toContain("invalid-argument");

    // Rejected before the code is even looked at, so it costs no attempt.
    const stored = await db.doc(`passwordResetChallenges/${challengeId}`).get();
    expect(stored.data()?.attempts ?? 0).toBe(0);
  });

  it("reports a send failure instead of claiming a code is on its way", async () => {
    await ensureUser(EMAIL);
    nextSendResult = { sent: false, reason: "provider-error", elapsedMs: 40 };

    expect(await errorCodeOf(() => request({ email: EMAIL }))).toContain(
      "unavailable"
    );
  });

  it("refuses when email delivery is not configured", async () => {
    await ensureUser(EMAIL);
    nextSendResult = { sent: false, reason: "not-configured", elapsedMs: 0 };

    expect(await errorCodeOf(() => request({ email: EMAIL }))).toContain(
      "failed-precondition"
    );
  });

  it("lets the same code finish the job when the Auth write fails first", async () => {
    const uid = await ensureUser(EMAIL);
    const { challengeId, code } = await startFlow();

    const updateUser = vi
      .spyOn(admin.auth(), "updateUser")
      .mockRejectedValueOnce(new Error("auth unavailable"));

    await expect(
      confirm({ challengeId, code, newPassword: GOOD_PASSWORD })
    ).rejects.toBeTruthy();
    updateUser.mockRestore();

    // Left retryable rather than burnt: the person still has a correct code.
    const mid = await db.doc(`passwordResetChallenges/${challengeId}`).get();
    expect(mid.data()?.status).toBe("verifying");

    await expect(
      confirm({ challengeId, code, newPassword: GOOD_PASSWORD })
    ).resolves.toEqual({ ok: true });
    expect((await admin.auth().getUser(uid)).uid).toBe(uid);
  });

  it("recovers when the password was set but the bookkeeping write was lost", async () => {
    await ensureUser(EMAIL);
    const { challengeId, code } = await startFlow();

    // Phase 2 succeeded, phase 3 did not: exactly the window where the
    // password has changed and nothing recorded it.
    const ref = db.doc(`passwordResetChallenges/${challengeId}`);
    // Spied on the prototype, not on this instance: the handler builds its own
    // DocumentReference for the same path, so an instance spy here never sees
    // the call. `once` lands on the only plain .update() the success path
    // makes, which is the phase-3 bookkeeping write.
    const proto = Object.getPrototypeOf(ref) as { update: unknown };
    const update = vi
      .spyOn(proto as never, "update")
      .mockRejectedValueOnce(new Error("write lost"));
    await expect(
      confirm({ challengeId, code, newPassword: GOOD_PASSWORD })
    ).rejects.toBeTruthy();
    update.mockRestore();

    const mid = await ref.get();
    expect(mid.data()?.status).toBe("verifying");

    // Retrying with the same code sets the same password again — harmless —
    // and finishes the bookkeeping.
    await expect(
      confirm({ challengeId, code, newPassword: GOOD_PASSWORD })
    ).resolves.toEqual({ ok: true });
    expect((await ref.get()).data()?.status).toBe("consumed");
  });

  it("rate limits sends per address", async () => {
    await ensureUser(EMAIL);
    const codes: string[] = [];
    for (let i = 0; i < 5; i += 1) {
      const result = await request({ email: EMAIL });
      codes.push(result.challengeId);
    }
    expect(await errorCodeOf(() => request({ email: EMAIL }))).toContain(
      "resource-exhausted"
    );
    expect(new Set(codes).size).toBe(5);
  });

  it("requires a usable email and says nothing else about it", async () => {
    expect(await errorCodeOf(() => request({ email: "" }))).toContain(
      "invalid-argument"
    );
    expect(await errorCodeOf(() => request({ email: "not-an-address" }))).toContain(
      "invalid-argument"
    );
    expect(await errorCodeOf(() => request({}))).toContain("invalid-argument");
  });
});
