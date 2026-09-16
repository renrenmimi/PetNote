import { createHmac, randomInt, randomUUID, timingSafeEqual } from "node:crypto";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { logger } from "firebase-functions";

import { admin, db, FieldValue, Timestamp } from "./platform";
import { assertRateLimit, requestData, trimString } from "./shared";
import {
  PASSWORD_RESET_CODE_SECRET,
  sendPasswordResetCodeEmail,
  TRANSACTIONAL_EMAIL_API_KEY,
} from "./email";

/**
 * Numeric-code password reset.
 *
 * Firebase's own `sendPasswordResetEmail` sends an `oobCode` link. That code
 * is not a six-digit secret and must not be treated as one: it cannot be
 * truncated into digits, it cannot be checked in the client, and pointing the
 * project at a custom action handler does not turn a link into an OTP. The
 * only supported way to get "enter a code, then set a new password" is for a
 * trusted server to mint and verify its own code and then use the Admin SDK
 * to set the password — which keeps the same Firebase Auth user and the same
 * uid. No identity service is replaced and no second user store is created.
 *
 * Shape of the protocol:
 *
 *   requestPasswordResetCode({ email })      -> { challengeId, expiresInSeconds }
 *   confirmPasswordResetCode({ challengeId, code, newPassword }) -> { ok: true }
 *
 * `requestPasswordResetCode` answers identically whether or not an account
 * exists: it always creates a challenge and always returns a challengeId. For
 * an unknown address the challenge simply carries no code digest, so every
 * later attempt fails the same way a wrong code does. That is what keeps this
 * from becoming an account-existence oracle.
 */

/** Six digits. Stored only as a keyed digest — never in a document or a log. */
const CODE_LENGTH = 6;
const CODE_TTL_MS = 10 * 60_000;
/** Wrong guesses allowed per challenge. Resending does NOT restore these. */
const MAX_ATTEMPTS = 5;
const MAX_SENDS_PER_CHALLENGE = 4;
const RESEND_COOLDOWN_MS = 60_000;

const SEND_RATE_LIMIT = { limit: 5, windowMs: 15 * 60_000 } as const;
const CONFIRM_RATE_LIMIT = { limit: 15, windowMs: 15 * 60_000 } as const;

const PURPOSE = "reset-password";

type ChallengeStatus = "pending" | "verifying" | "consumed";

function challengeRef(challengeId: string) {
  return db.doc(`passwordResetChallenges/${challengeId}`);
}

function normalizeEmail(value: unknown): string {
  const email = trimString(value, "email").toLowerCase();
  // Deliberately permissive: the server is not the place to re-litigate what
  // a valid address is, and a rejection here would be a different response
  // for a malformed address than for a well-formed unknown one.
  if (email.length === 0 || email.length > 254 || !email.includes("@")) {
    throw new HttpsError("invalid-argument", "A valid email is required.");
  }
  return email;
}

/**
 * A stable, non-reversible key for "requests about this address", used for
 * rate limiting and never stored alongside anything that would re-identify
 * it. Uses the same server secret as the code digest.
 */
function emailKey(email: string): string {
  return createHmac("sha256", PASSWORD_RESET_CODE_SECRET.value())
    .update(`email:${email}`)
    .digest("hex")
    .slice(0, 32);
}

/**
 * The digest binds the code to this challenge, this account and this purpose,
 * so a code cannot be replayed against another challenge, another account, or
 * some future non-reset flow that happens to use six digits.
 */
function codeDigest(challengeId: string, uid: string, code: string): string {
  return createHmac("sha256", PASSWORD_RESET_CODE_SECRET.value())
    .update(`${PURPOSE}:${challengeId}:${uid}:${code}`)
    .digest("hex");
}

function digestsMatch(a: string, b: string): boolean {
  const left = Buffer.from(a, "utf8");
  const right = Buffer.from(b, "utf8");
  if (left.length !== right.length) return false;
  return timingSafeEqual(left, right);
}

function generateCode(): string {
  // randomInt is CSPRNG-backed and unbiased over the range, unlike
  // Math.random or a modulo of random bytes.
  return String(randomInt(0, 10 ** CODE_LENGTH)).padStart(CODE_LENGTH, "0");
}

/**
 * Server-side password policy.
 *
 * Duplicates src/utils/passwordValidator.ts on purpose: the client copy is
 * there to give feedback while typing, and a server that trusts it is a
 * server with no policy at all. Firebase Auth's own floor is six characters,
 * which is weaker than this product's.
 */
function assertPasswordAcceptable(password: unknown): string {
  if (typeof password !== "string") {
    throw new HttpsError("invalid-argument", "newPassword must be a string.");
  }
  const failures: string[] = [];
  if (password.length < 8) failures.push("at least 8 characters");
  if (password.length > 64) failures.push("at most 64 characters");
  if (!/[A-Z]/.test(password)) failures.push("an uppercase letter");
  if (!/[a-z]/.test(password)) failures.push("a lowercase letter");
  if (!/[0-9]/.test(password)) failures.push("a number");
  if (!/[!@#$%^&*()_+\-=[\]{};':"\\|,.<>/?]/.test(password)) {
    failures.push("a special character");
  }
  if (failures.length > 0) {
    // Says what is missing, never echoes the password.
    throw new HttpsError(
      "invalid-argument",
      `Password needs ${failures.join(", ")}.`
    );
  }
  return password;
}

/**
 * Whether this account may have its password set by this flow.
 *
 * Returns null when it may, or a reason when it may not. A disabled account
 * and a deleted account keep the protections every other mutating path
 * already has; `emailVerified` is deliberately NOT required — needing a
 * verified address to recover an account you cannot get into is a deadlock,
 * and this flow proves control of the inbox by itself.
 */
async function accountEligibility(
  user: admin.auth.UserRecord
): Promise<"disabled" | "deleted" | "no-password-provider" | null> {
  if (user.disabled) return "disabled";
  const tombstone = await db.doc(`userDeletionTombstones/${user.uid}`).get();
  if (tombstone.exists) return "deleted";
  const hasPassword = user.providerData.some(
    (provider) => provider.providerId === "password"
  );
  // Conservative until the owner decides: this flow restores access to an
  // account that already has a password. Letting it *add* one to a
  // Google-only account is an identity-linking decision, not a bug fix, and
  // it would let inbox access alone convert the sign-in method.
  if (!hasPassword) return "no-password-provider";
  return null;
}

async function lookupUser(
  email: string
): Promise<admin.auth.UserRecord | null> {
  try {
    return await admin.auth().getUserByEmail(email);
  } catch (error) {
    const code = (error as { code?: string } | null)?.code ?? "";
    if (code === "auth/user-not-found") return null;
    throw error;
  }
}

export const requestPasswordResetCodeCallable = onCall(
  { secrets: [PASSWORD_RESET_CODE_SECRET, TRANSACTIONAL_EMAIL_API_KEY] },
  async (request) => {
    // No auth requirement: this exists for people who cannot sign in. There
    // is deliberately no `request.auth` check and no emailVerified gate.
    const data = requestData(request.data);
    const email = normalizeEmail(data.email);
    const existingChallengeId =
      typeof data.challengeId === "string" ? data.challengeId : null;

    const key = emailKey(email);
    // Keyed by the hashed address rather than a uid, because there is no
    // caller identity here. The subject slot in the shared limiter is just a
    // string; nothing reads it back as a user id.
    await assertRateLimit(`pwreset_${key}`, "passwordResetSend", SEND_RATE_LIMIT);

    const user = await lookupUser(email);
    const eligibility = user ? await accountEligibility(user) : null;
    // An ineligible account is treated exactly like an unknown one here. The
    // reason is only ever disclosed at confirm time, to somebody who has
    // already proved they received the mail.
    const deliverable = user !== null && eligibility === null;

    let challengeId = existingChallengeId ?? randomUUID();
    const now = Date.now();

    if (existingChallengeId) {
      // Resend against an existing challenge: keeps the attempt budget,
      // enforces a cooldown, and caps how many times a code can be reissued.
      const snap = await challengeRef(existingChallengeId).get();
      const existing = snap.exists ? snap.data() ?? {} : null;
      if (
        !existing ||
        existing.emailKey !== key ||
        existing.status === "consumed"
      ) {
        // Do not say which of those it was.
        challengeId = randomUUID();
      } else {
        const lastSentAt =
          typeof existing.lastSentAtMs === "number" ? existing.lastSentAtMs : 0;
        if (now - lastSentAt < RESEND_COOLDOWN_MS) {
          throw new HttpsError(
            "resource-exhausted",
            "A code was just sent. Please wait a moment before asking for another."
          );
        }
        if ((existing.sendCount ?? 0) >= MAX_SENDS_PER_CHALLENGE) {
          throw new HttpsError(
            "resource-exhausted",
            "Too many codes requested. Start again in a few minutes."
          );
        }
      }
    }

    const isResend = challengeId === existingChallengeId;
    const code = deliverable ? generateCode() : null;
    const expiresAtMs = now + CODE_TTL_MS;

    await challengeRef(challengeId).set(
      {
        emailKey: key,
        purpose: PURPOSE,
        // Present only for a deliverable account. For anything else the
        // challenge exists and looks identical from outside, but no code can
        // ever verify against it.
        uid: deliverable ? user!.uid : null,
        codeDigest:
          code && deliverable ? codeDigest(challengeId, user!.uid, code) : null,
        status: "pending" satisfies ChallengeStatus,
        // Attempts are NOT reset on resend. Restoring the budget every time a
        // new code is mailed would make the cap meaningless.
        ...(isResend ? {} : { attempts: 0 }),
        sendCount: FieldValue.increment(1),
        expiresAtMs,
        // Checked in code on every verify. The TTL policy is only for
        // housekeeping — expiry must not depend on a deletion running on time.
        expiresAt: Timestamp.fromMillis(expiresAtMs),
        lastSentAtMs: now,
        createdAt: isResend ? (FieldValue.serverTimestamp() as never) : FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    if (code && deliverable) {
      // Outside any transaction, and after the challenge is durable: an email
      // cannot be rolled back, so it must never be sent from something that
      // may be retried.
      const result = await sendPasswordResetCodeEmail({
        to: email,
        code,
        expiresInMinutes: Math.round(CODE_TTL_MS / 60_000),
      });
      if (!result.sent) {
        // Never logs the code or the address.
        logger.warn("Password reset code not delivered", {
          challengeId,
          reason: result.reason,
        });
        if (result.reason === "not-configured") {
          throw new HttpsError(
            "failed-precondition",
            "Email delivery is not configured for this environment."
          );
        }
        throw new HttpsError(
          "unavailable",
          "Could not send the code. Please try again."
        );
      }
    }

    return {
      challengeId,
      expiresInSeconds: Math.round(CODE_TTL_MS / 1000),
      // Deliberately identical for every address.
      status: "sent" as const,
    };
  }
);

export const confirmPasswordResetCodeCallable = onCall(
  { secrets: [PASSWORD_RESET_CODE_SECRET] },
  async (request) => {
    const data = requestData(request.data);
    const challengeId = trimString(data.challengeId, "challengeId");
    const code = trimString(data.code, "code").replace(/\D/g, "");
    const newPassword = assertPasswordAcceptable(data.newPassword);

    await assertRateLimit(
      `pwreset_confirm_${challengeId.replace(/[^A-Za-z0-9_-]/g, "_")}`,
      "passwordResetConfirm",
      CONFIRM_RATE_LIMIT
    );

    const ref = challengeRef(challengeId);

    // Phase 1: decide, and record the decision, atomically. The Auth write is
    // deliberately outside this transaction — a transaction may be retried,
    // and changing somebody's password twice because of a contention retry is
    // not acceptable.
    const outcome = await db.runTransaction(async (transaction) => {
      const snap = await transaction.get(ref);
      if (!snap.exists) return { kind: "invalid" as const };
      const challenge = snap.data() ?? {};

      if (challenge.purpose !== PURPOSE) return { kind: "invalid" as const };
      if (challenge.status === "consumed") return { kind: "used" as const };
      if (
        typeof challenge.expiresAtMs !== "number" ||
        challenge.expiresAtMs <= Date.now()
      ) {
        return { kind: "expired" as const };
      }

      const attempts =
        typeof challenge.attempts === "number" ? challenge.attempts : 0;
      if (attempts >= MAX_ATTEMPTS) return { kind: "locked" as const };

      const uid = typeof challenge.uid === "string" ? challenge.uid : null;
      const storedDigest =
        typeof challenge.codeDigest === "string" ? challenge.codeDigest : null;

      // An unknown or ineligible address produced a challenge with no digest.
      // It fails here, the same way a wrong code does.
      const matches =
        uid !== null &&
        storedDigest !== null &&
        code.length === CODE_LENGTH &&
        digestsMatch(storedDigest, codeDigest(challengeId, uid, code));

      if (!matches) {
        transaction.update(ref, {
          attempts: attempts + 1,
          updatedAt: FieldValue.serverTimestamp(),
        });
        return { kind: "wrong" as const, attemptsLeft: MAX_ATTEMPTS - (attempts + 1) };
      }

      // "verifying" is retryable on purpose: if the Auth write succeeded but
      // the response was lost, the client retries with the same code and we
      // finish the job rather than telling them a correct code is wrong.
      transaction.update(ref, {
        status: "verifying" satisfies ChallengeStatus,
        attempts: attempts + 1,
        verifyingAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      return { kind: "verified" as const, uid };
    });

    if (outcome.kind !== "verified") {
      // One message for every failure mode that could say something about the
      // account. "expired" and "used" are safe to name because holding the
      // challenge id already implies having asked for it.
      if (outcome.kind === "expired") {
        throw new HttpsError(
          "deadline-exceeded",
          "That code has expired. Request a new one."
        );
      }
      if (outcome.kind === "used") {
        throw new HttpsError(
          "failed-precondition",
          "That code has already been used. Request a new one."
        );
      }
      if (outcome.kind === "locked") {
        throw new HttpsError(
          "resource-exhausted",
          "Too many incorrect codes. Request a new one."
        );
      }
      throw new HttpsError("invalid-argument", "That code is not correct.");
    }

    // Re-check account state at the moment of the write, not only at request
    // time: a ban or a deletion may have started in between.
    const user = await admin.auth().getUser(outcome.uid);
    const eligibility = await accountEligibility(user);
    if (eligibility !== null) {
      await ref.update({
        status: "pending" satisfies ChallengeStatus,
        updatedAt: FieldValue.serverTimestamp(),
      });
      if (eligibility === "no-password-provider") {
        throw new HttpsError(
          "failed-precondition",
          "This account signs in with Google. Use Continue with Google instead."
        );
      }
      throw new HttpsError(
        "failed-precondition",
        "This account cannot be used to sign in right now."
      );
    }

    // Phase 2: the cross-service step. Setting the same password twice is
    // harmless, which is what makes a retry after a lost response safe.
    // `emailVerified` is deliberately untouched — proving inbox control for a
    // reset is not the same as verifying the address for the gates that use
    // that flag.
    await admin.auth().updateUser(outcome.uid, { password: newPassword });

    // Old sessions on other devices are cut. Somebody resetting a password is
    // often doing it because they think someone else has it.
    await admin.auth().revokeRefreshTokens(outcome.uid);

    // Phase 3: mark it spent. If this write fails the password is already
    // changed and the challenge stays "verifying" — a repeat of the same code
    // is idempotent, and it still expires on its own clock.
    await ref.update({
      status: "consumed" satisfies ChallengeStatus,
      consumedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
      // Nothing about the password, the code or the address is recorded.
      codeDigest: FieldValue.delete(),
    });

    return { ok: true as const };
  }
);
