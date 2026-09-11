/**
 * Firebase Auth error codes → the notice the person actually sees.
 *
 * Returns translation keys rather than strings so English and Chinese cannot
 * drift apart, and so no call site is tempted to fall back on
 * `err.message` — the raw Firebase text ("Firebase: Error
 * (auth/invalid-credential).") was reaching the login screen before this.
 *
 * Two rules this file exists to hold:
 *
 * - **No account enumeration.** `user-not-found`, `wrong-password` and
 *   `invalid-credential` all resolve to the same notice. Telling them apart
 *   is exactly the thing Firebase's Email Enumeration Protection is for, and
 *   undoing that in the copy would undo it in practice.
 * - **Wrong password is not an invitation to sign up again.** The previous
 *   copy ended with "If you are new, create an account first" and attached a
 *   "Create account" button, so mistyping a password looked like being told
 *   the account did not exist. The sign-up and reset entries stay where they
 *   are on the page; they are not promoted into the error.
 */

import type { TranslationKey } from "../i18n/messages";

export type AuthNotice = {
  titleKey: TranslationKey;
  messageKey: TranslationKey;
};

function errorCode(err: unknown): string {
  if (err && typeof err === "object" && "code" in err) {
    return String((err as { code?: unknown }).code ?? "");
  }
  return "";
}

/**
 * `null` means "say nothing": the person closed the Google sheet themselves,
 * and an error banner for a deliberate cancellation is noise.
 */
export function mapAuthError(err: unknown): AuthNotice | null {
  const code = errorCode(err);

  if (
    code.includes("popup-closed-by-user") ||
    code.includes("cancelled-popup-request") ||
    code.includes("user-cancelled")
  ) {
    return null;
  }

  if (code.includes("invalid-email")) {
    return {
      titleKey: "signup.invalidEmailTitle",
      messageKey: "signup.invalidEmailMessage",
    };
  }

  // One notice for all three. See the note above.
  if (
    code.includes("user-not-found") ||
    code.includes("wrong-password") ||
    code.includes("invalid-credential") ||
    code.includes("invalid-login-credentials")
  ) {
    return {
      titleKey: "login.invalidTitle",
      messageKey: "login.invalidMessage",
    };
  }

  if (code.includes("network-request-failed")) {
    return {
      titleKey: "auth.networkErrorTitle",
      messageKey: "auth.networkErrorMessage",
    };
  }

  if (code.includes("too-many-requests")) {
    return {
      titleKey: "auth.tooManyRequestsTitle",
      messageKey: "auth.tooManyRequestsMessage",
    };
  }

  if (code.includes("user-disabled")) {
    return {
      titleKey: "auth.userDisabledTitle",
      messageKey: "auth.userDisabledMessage",
    };
  }

  if (code.includes("popup-blocked")) {
    return {
      titleKey: "auth.popupBlockedTitle",
      messageKey: "auth.popupBlockedMessage",
    };
  }

  if (code.includes("account-exists-with-different-credential")) {
    return {
      titleKey: "auth.signInMethodTitle",
      messageKey: "auth.signInMethodMessage",
    };
  }

  if (code.includes("operation-not-allowed")) {
    return {
      titleKey: "auth.genericErrorTitle",
      messageKey: "signup.emailSignUpDisabled",
    };
  }

  return {
    titleKey: "auth.genericErrorTitle",
    messageKey: "auth.genericErrorMessage",
  };
}
