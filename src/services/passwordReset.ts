import { httpsCallable } from "firebase/functions";

import { functions } from "./firebase";

/**
 * Numeric-code password reset.
 *
 * Off by default. `VITE_PASSWORD_RESET_OTP` gates it because the backend
 * callables need a transactional email provider that is not configured yet,
 * and an entry point that cannot finish is worse than no entry point: it
 * would take somebody who already cannot sign in and hand them a dead end.
 * Until the flag is set, ForgotPassword keeps sending Firebase's own reset
 * link, which works today.
 *
 * The flag is read once, at module scope, so a build either has this path or
 * it does not — there is no runtime toggle for a client to flip.
 */
export const passwordResetOtpEnabled =
  import.meta.env.VITE_PASSWORD_RESET_OTP === "1";

export const RESET_CODE_LENGTH = 6;

type RequestResponse = {
  challengeId: string;
  expiresInSeconds: number;
  status: "sent";
};

export type RequestCodeResult = {
  challengeId: string;
  expiresInSeconds: number;
};

/**
 * Asks for a code.
 *
 * Resolves the same way for an address with an account and one without —
 * that is the server's contract, and the UI must not try to interpret it
 * otherwise. Pass `challengeId` to resend on the existing challenge instead
 * of starting a new one; that keeps the attempt budget rather than refreshing
 * it, and it is what the server expects a "resend" to mean.
 */
export async function requestPasswordResetCode(
  email: string,
  challengeId?: string
): Promise<RequestCodeResult> {
  const call = httpsCallable<
    { email: string; challengeId?: string },
    RequestResponse
  >(functions, "requestPasswordResetCodeCallable");
  const { data } = await call({
    email,
    ...(challengeId ? { challengeId } : {}),
  });
  return {
    challengeId: data.challengeId,
    expiresInSeconds: data.expiresInSeconds,
  };
}

/**
 * Confirms a code and sets the new password.
 *
 * The uid is deliberately not a parameter. The server reads it from the
 * challenge; sending one from here would be a value the server must ignore.
 */
export async function confirmPasswordResetCode(args: {
  challengeId: string;
  code: string;
  newPassword: string;
}): Promise<void> {
  const call = httpsCallable<typeof args, { ok: true }>(
    functions,
    "confirmPasswordResetCodeCallable"
  );
  await call(args);
}

export type ResetCodeFailure =
  | "wrong-code"
  | "expired"
  | "already-used"
  | "too-many"
  | "weak-password"
  | "google-only"
  | "account-unavailable"
  | "not-configured"
  | "offline"
  | "unknown";

/**
 * Maps a callable error onto something the screen can say.
 *
 * `already-used` is separated out on purpose. If the password was set but the
 * response never arrived, the retry lands here — and the right thing to tell
 * somebody in that position is to try signing in with the new password, not
 * that their correct code was refused.
 */
export function classifyResetFailure(error: unknown): ResetCodeFailure {
  const code =
    error && typeof error === "object" && "code" in error
      ? String((error as { code?: unknown }).code ?? "")
      : "";
  const message =
    error && typeof error === "object" && "message" in error
      ? String((error as { message?: unknown }).message ?? "")
      : "";

  if (code.includes("deadline-exceeded")) return "expired";
  if (code.includes("unavailable") || code.includes("internal")) {
    return navigator.onLine === false ? "offline" : "unknown";
  }
  if (code.includes("resource-exhausted")) return "too-many";
  if (code.includes("failed-precondition")) {
    if (/already been used/i.test(message)) return "already-used";
    if (/Google/i.test(message)) return "google-only";
    if (/not configured/i.test(message)) return "not-configured";
    return "account-unavailable";
  }
  if (code.includes("invalid-argument")) {
    if (/^Password needs/i.test(message)) return "weak-password";
    return "wrong-code";
  }
  return "unknown";
}
