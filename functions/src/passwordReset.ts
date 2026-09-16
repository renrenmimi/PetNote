import { createHmac, randomInt, randomUUID, timingSafeEqual } from "node:crypto";
import { getFunctions } from "firebase-admin/functions";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { onTaskDispatched } from "firebase-functions/v2/tasks";
import { logger } from "firebase-functions";

import { admin, db, FieldValue, Timestamp } from "./platform";
import { assertRateLimit, requestData, trimString } from "./shared";
import {
  EMAIL_SECRETS,
  emailTransportConfigured,
  PASSWORD_RESET_CODE_SECRET,
  sendGoogleOnlyNoticeEmail,
  sendPasswordResetCodeEmail,
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

/**
 * A floor on how long `requestPasswordResetCode` takes, whatever it decides.
 *
 * This is a **mitigation of a timing side channel, not a closed hole**, and
 * the number is small now for a reason. Originally it had to hide a whole
 * round trip to the email provider — a deliverable address cost ~260 ms more
 * than an unknown one, measured. Sending moved to a Cloud Tasks queue, and
 * the request path now does exactly the same work for every address
 * (rate limit, lookup, write the challenge, enqueue), so what is left to hide
 * is one extra Firestore read for an account that exists.
 *
 * Measured on the emulator, five samples each, floor disabled:
 *
 *   before the queue   deliverable 268 ms (267-269), unknown   8 ms (7-14)
 *   after the queue    deliverable  12 ms (10-27),   unknown   9 ms (7-12)
 *
 * So the queue removed the gap structurally — 260 ms down to 3 ms — and this
 * floor only has to cover what is left. 400 ms rather than 3 ms because a
 * deployed function's Auth lookup and cold starts vary far more than a local
 * emulator's, and the margin is cheap.
 *
 * What remains, said plainly: this is **not constant-time and not a closed
 * hole**. The floor bounds the eligibility read with margin, but it does not
 * bound cold-start variance, and an attacker with enough samples may still
 * see a difference. Closing it properly would mean doing identical work for
 * every address — including a tombstone read for addresses with no account —
 * which is a further change this floor does not achieve.
 *
 * Overridable only so the test suite can run at zero. Production never sets
 * it, and the default is the value that ships.
 */
const MIN_REQUEST_MS = (() => {
  const override = Number(process.env.PASSWORD_RESET_MIN_REQUEST_MS);
  return Number.isFinite(override) && override >= 0 ? override : 400;
})();

/**
 * What the delivery worker should do for a challenge.
 *
 * Decided in the request handler, where the account state is already in hand,
 * and carried on the challenge document rather than in the task payload —
 * which is also why the payload is nothing but a challenge id. No address and
 * no code ever enter the queue.
 */
type DeliveryOutcome = "code" | "google-only" | "none";

const DELIVERY_QUEUE = "deliverPasswordResetCodeTask";

const CHALLENGE_ID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

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

/** Holds the response back until `MIN_REQUEST_MS` has passed since `startedAt`. */
async function holdUntilFloor(startedAt: number): Promise<void> {
  const remaining = MIN_REQUEST_MS - (Date.now() - startedAt);
  if (remaining > 0) {
    await new Promise((resolve) => setTimeout(resolve, remaining));
  }
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
  // Spread rather than listed, so this cannot bind a subset of what
  // email.ts reads — which is exactly how the From address came to be
  // missing, leaving the flow permanently "not configured".
  { secrets: [PASSWORD_RESET_CODE_SECRET, ...EMAIL_SECRETS] },
  async (request) => {
    const startedAt = Date.now();
    // No auth requirement: this exists for people who cannot sign in. There
    // is deliberately no `request.auth` check and no emailVerified gate.
    // Asked before anything else, and safe to: whether the transport is
    // configured is a property of the environment, identical for every
    // address, and answered from memory. Now that the send happens on a
    // queue the request cannot report a provider failure, so this is what
    // stops an unconfigured deployment telling people to go and check their
    // email for ever.
    if (!emailTransportConfigured()) {
      throw new HttpsError(
        "failed-precondition",
        "Email delivery is not configured for this environment."
      );
    }

    const data = requestData(request.data);
    const email = normalizeEmail(data.email);
    const rawChallengeId =
      typeof data.challengeId === "string" ? data.challengeId : null;
    const existingChallengeId =
      rawChallengeId && CHALLENGE_ID_PATTERN.test(rawChallengeId)
        ? rawChallengeId
        : null;

    const key = emailKey(email);
    // Keyed by the hashed address rather than a uid, because there is no
    // caller identity here. The subject slot in the shared limiter is just a
    // string; nothing reads it back as a user id.
    // Not floored, and it does not need to be: this runs before any account
    // lookup, so how long it takes is the same whether or not the address has
    // an account. It is the one exit from this handler that skips the floor.
    await assertRateLimit(`pwreset_${key}`, "passwordResetSend", SEND_RATE_LIMIT);

    const user = await lookupUser(email);
    const eligibility = user ? await accountEligibility(user) : null;
    // An ineligible account is treated exactly like an unknown one *in the
    // response*. What differs is what lands in the inbox, which is a channel
    // only the account holder can read.
    const deliverable = user !== null && eligibility === null;
    // A Google-only account has nothing to reset, and used to be sent into a
    // dead end: the response promised a code, none was ever minted for them,
    // and the only reachable outcome was "that code is not correct". The
    // "use Google" message lived in the confirm handler, which they could
    // never reach. It is told in the mail instead.
    const googleOnly = user !== null && eligibility === "no-password-provider";

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
          // Floored like every other exit: by this point an eligible account
          // has cost one more Firestore read than an unknown one, and a
          // refusal that returns faster for strangers is still a signal.
          await holdUntilFloor(startedAt);
          throw new HttpsError(
            "resource-exhausted",
            "A code was just sent. Please wait a moment before asking for another."
          );
        }
        if ((existing.sendCount ?? 0) >= MAX_SENDS_PER_CHALLENGE) {
          await holdUntilFloor(startedAt);
          throw new HttpsError(
            "resource-exhausted",
            "Too many codes requested. Start again in a few minutes."
          );
        }
      }
    }

    const isResend = challengeId === existingChallengeId;
    const expiresAtMs = now + CODE_TTL_MS;
    const outcome: DeliveryOutcome = deliverable
      ? "code"
      : googleOnly
        ? "google-only"
        : "none";

    // No code is minted here any more, and none is written. The worker mints
    // it, so the plaintext exists in one process for one send and then only
    // in the mail — not in this document, not in the response, not in the
    // task payload, not in a log.
    await challengeRef(challengeId).set(
      {
        emailKey: key,
        purpose: PURPOSE,
        // Present only for a deliverable account. For anything else the
        // challenge exists and looks identical from outside, but no code can
        // ever verify against it.
        uid: deliverable || googleOnly ? user!.uid : null,
        outcome,
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
        // Only on creation. The previous form was a ternary with the same
        // expression in both branches, so every resend quietly reset the
        // creation time of the challenge it was extending.
        ...(isResend ? {} : { createdAt: FieldValue.serverTimestamp() }),
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    // Enqueued for **every** outcome, including an address with no account.
    // That is the point: the request path now performs identical work
    // whatever it found, so there is no provider round trip on one branch and
    // nothing on the other. An unknown address costs one queue operation and
    // a worker that immediately does nothing.
    //
    // A durable API call, not fire-and-forget: if the enqueue fails the
    // caller is told the request failed, rather than being sent to wait for
    // mail that was never scheduled.
    try {
      await getFunctions()
        .taskQueue(DELIVERY_QUEUE)
        .enqueue(
          { challengeId },
          // Shorter than the code's own lifetime. A task still waiting to run
          // after the code has expired has nothing useful left to send.
          { dispatchDeadlineSeconds: 300 }
        );
    } catch (error) {
      logger.error("Could not enqueue password reset delivery", {
        challengeId,
        error: error instanceof Error ? error.message : "unknown",
      });
      await holdUntilFloor(startedAt);
      throw new HttpsError(
        "unavailable",
        "Could not send the code. Please try again."
      );
    }

    // Every path leaves through the same floor, including the throws above:
    // an error that arrives faster than a success is its own signal.
    await holdUntilFloor(startedAt);

    return {
      challengeId,
      expiresInSeconds: Math.round(CODE_TTL_MS / 1000),
      // Deliberately identical for every address.
      status: "sent" as const,
    };
  }
);


/**
 * Sends the mail, off the request path, on a durable queue.
 *
 * **Persistence.** Cloud Tasks holds the task, not this process. The enqueue
 * is an awaited API call in `requestPasswordResetCode`, so a task either
 * exists before the caller is told "check your email" or the caller is told
 * the request failed. That is the whole reason this is not
 * fire-and-forget: a `void send()` left running after the response would
 * disappear with the instance, silently, and the person would wait for mail
 * that no longer had anything sending it.
 *
 * **Retries.** `retryConfig` below, with exponential backoff. A thrown error
 * is a retry; a returned value is success. Provider timeouts and 5xx
 * therefore get another attempt without the person having to ask again,
 * which is what the old inline send could never do.
 *
 * **Duplicate delivery.** Cloud Tasks is at-least-once, so a task may run
 * again after a send the queue did not see succeed. The worker mints a fresh
 * code on each attempt and supersedes the stored digest, so a duplicate means
 * two mails of which **only the newer code works** — the same situation as
 * asking for a resend, which this flow already handles and explains. It is
 * bounded twice: `maxAttempts` here, and the challenge's own
 * `MAX_SENDS_PER_CHALLENGE`, which the worker re-checks so a retry storm
 * cannot mail somebody more times than a person could have asked.
 *
 * **Rate limiting.** Two layers, neither of them here by accident. The
 * request handler's per-address limit decides how many tasks can be created
 * at all; `rateLimits` below decides how fast the queue drains, so a burst of
 * legitimate requests cannot turn into a burst at the provider and get the
 * sending domain throttled. The Google-only notice goes through this same
 * queue and the same limits — it is not a side channel around them.
 *
 * The payload is a challenge id and nothing else. The address comes from Auth
 * by uid, so it is never in the queue; the code is minted here, so it is
 * never in the queue either.
 */
export const deliverPasswordResetCodeTask = onTaskDispatched(
  {
    secrets: [PASSWORD_RESET_CODE_SECRET, ...EMAIL_SECRETS],
    retryConfig: {
      // Three tries, not more: after ~2 minutes of provider failure the code
      // is halfway through its ten-minute life and a fresh request is the
      // better answer than a late mail.
      maxAttempts: 3,
      minBackoffSeconds: 10,
      maxBackoffSeconds: 60,
    },
    rateLimits: {
      // Sized for the provider and the domain's reputation, not for this
      // app's peak: reset mail is low volume and being slightly slow is
      // better than being rate limited upstream.
      maxConcurrentDispatches: 5,
      maxDispatchesPerSecond: 5,
    },
  },
  async (request) => {
    const challengeId =
      typeof request.data?.challengeId === "string"
        ? request.data.challengeId
        : "";
    if (!CHALLENGE_ID_PATTERN.test(challengeId)) {
      // Not retryable — a malformed id will still be malformed in ten
      // seconds. Returning rather than throwing takes it off the queue.
      logger.error("Delivery task had no usable challenge id");
      return;
    }

    const ref = challengeRef(challengeId);
    const snap = await ref.get();
    if (!snap.exists) {
      // The challenge was cleaned up, or never existed. Nothing to send and
      // nothing to retry.
      return;
    }
    const challenge = snap.data() ?? {};

    if (challenge.purpose !== PURPOSE) return;
    if (challenge.status === "consumed") return;
    // Expiry is the code's own clock, checked here as well as at verify time.
    // A task that waited out the queue has nothing worth mailing.
    if (
      typeof challenge.expiresAtMs !== "number" ||
      challenge.expiresAtMs <= Date.now()
    ) {
      logger.info("Delivery task dropped: challenge already expired", {
        challengeId,
      });
      return;
    }

    const outcome = challenge.outcome as DeliveryOutcome | undefined;
    // An address with no account, or one that is disabled or deleted. The task
    // exists so that the request path did identical work for every address;
    // there is nothing to send.
    if (outcome === "none" || outcome === undefined) return;

    const sendCount =
      typeof challenge.sendCount === "number" ? challenge.sendCount : 0;
    if (sendCount > MAX_SENDS_PER_CHALLENGE) {
      // Re-checked here, so retries cannot mail somebody more times than a
      // person could have asked for.
      logger.warn("Delivery task dropped: send cap already reached", {
        challengeId,
        sendCount,
      });
      return;
    }

    const uid = typeof challenge.uid === "string" ? challenge.uid : null;
    if (uid === null) return;

    // The address is read here rather than carried, so it never enters the
    // queue. It is also the freshest answer: an account whose address changed
    // between the request and the send gets the mail at the address it has
    // now, which is the one its owner can read.
    let email: string;
    try {
      const user = await admin.auth().getUser(uid);
      // Re-checked at the moment of sending. A ban or a deletion that started
      // after the request must stop the mail.
      const eligibility = await accountEligibility(user);
      if (!user.email) return;
      if (outcome === "code" && eligibility !== null) {
        logger.info("Delivery task dropped: account no longer eligible", {
          challengeId,
        });
        return;
      }
      email = user.email;
    } catch (error) {
      const code = (error as { code?: string } | null)?.code ?? "";
      // A deleted account is not a retryable condition.
      if (code === "auth/user-not-found") return;
      throw error;
    }

    if (outcome === "google-only") {
      const result = await sendGoogleOnlyNoticeEmail({ to: email });
      if (!result.sent) {
        if (result.reason === "not-configured") {
          // Retrying will not configure it. Logged for an operator instead.
          logger.error("Google-only notice: transport not configured", {
            challengeId,
          });
          return;
        }
        // Retryable.
        throw new Error(`google-only notice failed: ${result.reason}`);
      }
      return;
    }

    // outcome === "code". Minted here, per attempt: the previous digest is
    // superseded, so if a retry produces a second mail only the newer code
    // verifies.
    const code = generateCode();
    await ref.update({
      codeDigest: codeDigest(challengeId, uid, code),
      updatedAt: FieldValue.serverTimestamp(),
    });

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
        logger.error("Password reset code: transport not configured", {
          challengeId,
        });
        return;
      }
      throw new Error(`code send failed: ${result.reason}`);
    }
  }
);

export const confirmPasswordResetCodeCallable = onCall(
  { secrets: [PASSWORD_RESET_CODE_SECRET] },
  async (request) => {
    const data = requestData(request.data);
    const challengeId = trimString(data.challengeId, "challengeId");
    const code = trimString(data.code, "code").replace(/\D/g, "");
    const newPassword = assertPasswordAcceptable(data.newPassword);

    // Checked before the id reaches a document path. The rate-limit key below
    // was already being sanitised, which hid the fact that `challengeRef`
    // next to it was not: a value with a slash addressed a nested document
    // outside the collection the rules and the TTL policy cover. Anything
    // that is not a UUID cannot be a challenge this server minted, so it is
    // refused with the same message as a wrong code.
    if (!CHALLENGE_ID_PATTERN.test(challengeId)) {
      throw new HttpsError("invalid-argument", "That code is not correct.");
    }

    await assertRateLimit(
      `pwreset_confirm_${challengeId}`,
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
