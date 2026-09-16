import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { Check } from "lucide-react";
import { sendPasswordResetEmail } from "firebase/auth";
import { LanguageSelector } from "../components/LanguageSelector";
import { PasswordStrengthIndicator } from "../components/PasswordStrengthIndicator";
import { PasswordVisibilityButton } from "../components/PasswordVisibilityButton";
import { VerificationCodeInput } from "../components/VerificationCodeInput";
import { useLanguage } from "../hooks/useLanguage";
import type { TranslationKey } from "../i18n/messages";
import { AuthShell } from "../components/AuthShell";
import { auth } from "../services/firebase";
import { emailFieldProps, newPasswordFieldProps } from "../utils/formFields";
import {
  classifyResetFailure,
  confirmPasswordResetCode,
  passwordResetOtpEnabled,
  requestPasswordResetCode,
  RESET_CODE_LENGTH,
  type ResetCodeFailure,
} from "../services/passwordReset";

function MailIcon() {
  return (
    <svg
      className="h-5 w-5 text-slate-400 dark:text-slate-500"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M4 6h16a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2Z" />
      <path d="m22 8-10 6L2 8" />
    </svg>
  );
}

function LockIcon() {
  return (
    <svg
      className="h-5 w-5 text-slate-400 dark:text-slate-500"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <rect x="3" y="11" width="18" height="10" rx="2" />
      <path d="M7 11V7a5 5 0 0 1 10 0v4" />
    </svg>
  );
}

/**
 * Seconds before another send is offered. Matches the server's cooldown, so
 * the button does not re-enable into a request the server will refuse. The
 * code's own lifetime comes from the server's response rather than being
 * repeated here.
 */
const RESEND_COOLDOWN_SECONDS = 60;

/**
 * Counts down to zero and stays there. Used for the resend cooldown so the
 * button says how long is left rather than just being dead.
 */
function useCountdown(): [number, (seconds: number) => void] {
  const [remaining, setRemaining] = useState(0);
  const timerRef = useRef<number | null>(null);

  useEffect(() => {
    if (remaining <= 0) return;
    timerRef.current = window.setTimeout(
      () => setRemaining((value) => Math.max(0, value - 1)),
      1000
    );
    return () => {
      if (timerRef.current) window.clearTimeout(timerRef.current);
    };
  }, [remaining]);

  return [remaining, setRemaining];
}

// Typed against TranslationKey so a missing or misspelled key is a compile
// error rather than the key text appearing on screen.
const failureKey: Record<ResetCodeFailure, TranslationKey> = {
  "wrong-code": "forgot.codeWrong",
  expired: "forgot.codeExpired",
  "already-used": "forgot.codeUsed",
  "too-many": "forgot.codeTooMany",
  "weak-password": "signup.weakPasswordMessage",
  "google-only": "forgot.codeGoogleOnly",
  "account-unavailable": "forgot.codeAccountUnavailable",
  "not-configured": "forgot.codeNotConfigured",
  offline: "auth.networkErrorMessage",
  unknown: "auth.genericErrorMessage",
};

export function ForgotPassword() {
  const { t } = useLanguage();
  const [email, setEmail] = useState("");
  const [loading, setLoading] = useState(false);
  const [status, setStatus] = useState<"idle" | "success" | "error">("idle");
  const [message, setMessage] = useState("");
  const [cooldown, setCooldown] = useCountdown();

  // Only used by the code flow.
  const [step, setStep] = useState<"email" | "code">("email");
  const [challengeId, setChallengeId] = useState<string | null>(null);
  const [code, setCode] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [done, setDone] = useState(false);

  const trimmedEmail = email.trim();
  // Checked in the handlers as well as in `disabled`: a disabled attribute is
  // a hint, and a double submit can still arrive from a fast double tap or a
  // repeated Enter before React re-renders.
  const busyRef = useRef(false);

  const sendLink = useCallback(async () => {
    if (busyRef.current) return;
    busyRef.current = true;
    setLoading(true);
    setStatus("idle");
    setMessage("");
    try {
      // Don't probe with fetchSignInMethodsForEmail first — Firebase
      // disables it under Email Enumeration Protection (default for new
      // projects since 2023-09), so it returns an empty array regardless
      // of whether an account exists. sendPasswordResetEmail itself
      // succeeds silently for unknown emails when protection is on,
      // which is the privacy-correct behavior; we surface the same
      // "if the email exists, a link was sent" message either way.
      await sendPasswordResetEmail(auth, trimmedEmail);
      setStatus("success");
      setMessage(t("forgot.resetSent"));
      setCooldown(RESEND_COOLDOWN_SECONDS);
    } catch (err) {
      // A failure that says something about *this request* — offline, rate
      // limited — has to be reported as such. The old code showed the
      // neutral "if an account exists, we've sent a link" line for every
      // error, so sending with no connection looked like it had worked.
      //
      // Anything that might say something about the *account* keeps the
      // neutral line: which errors those are is Firebase's business, and
      // guessing would reopen enumeration.
      const errorCode =
        err && typeof err === "object" && "code" in err
          ? String((err as { code?: unknown }).code ?? "")
          : "";
      setStatus("error");
      if (errorCode.includes("network-request-failed")) {
        setMessage(t("auth.networkErrorMessage"));
      } else if (errorCode.includes("too-many-requests")) {
        setMessage(t("auth.tooManyRequestsMessage"));
      } else if (errorCode.includes("invalid-email")) {
        setMessage(t("signup.invalidEmailMessage"));
      } else {
        setMessage(t("forgot.fallback"));
      }
    } finally {
      busyRef.current = false;
      setLoading(false);
    }
  }, [setCooldown, t, trimmedEmail]);

  const sendCode = useCallback(
    async (resendOf: string | null) => {
      if (busyRef.current) return;
      busyRef.current = true;
      setLoading(true);
      setStatus("idle");
      setMessage("");
      try {
        const result = await requestPasswordResetCode(
          trimmedEmail,
          resendOf ?? undefined
        );
        setChallengeId(result.challengeId);
        setStep("code");
        setCode("");
        setCooldown(RESEND_COOLDOWN_SECONDS);
        setStatus("success");
        // Neutral by construction: the server answers identically whether or
        // not the address has an account, and this copy says "if".
        setMessage(
          t("forgot.codeSentBody", {
            email: trimmedEmail,
            length: RESET_CODE_LENGTH,
            minutes: Math.round(result.expiresInSeconds / 60),
          })
        );
      } catch (err) {
        setStatus("error");
        setMessage(t(failureKey[classifyResetFailure(err)]));
      } finally {
        busyRef.current = false;
        setLoading(false);
      }
    },
    [setCooldown, t, trimmedEmail]
  );

  const submitCode = useCallback(async () => {
    if (busyRef.current || !challengeId) return;
    busyRef.current = true;
    setLoading(true);
    setStatus("idle");
    setMessage("");
    try {
      await confirmPasswordResetCode({ challengeId, code, newPassword });
      setDone(true);
      setStatus("success");
      setMessage(t("forgot.resetDone"));
    } catch (err) {
      const failure = classifyResetFailure(err);
      setStatus("error");
      setMessage(t(failureKey[failure]));
      if (failure === "expired" || failure === "too-many") {
        // The code is spent either way; make the next action obvious.
        setCooldown(0);
      }
    } finally {
      busyRef.current = false;
      setLoading(false);
    }
  }, [challengeId, code, newPassword, setCooldown, t]);

  const handleSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!trimmedEmail) return;
    void (passwordResetOtpEnabled ? sendCode(null) : sendLink());
  };

  const showSpamHint = status === "success" && !done;

  return (
    <AuthShell
      title={step === "code" ? t("forgot.codeSentTitle") : t("forgot.title")}
      subtitle={
        step === "email"
          ? t(
              passwordResetOtpEnabled
                ? "forgot.subtitleCode"
                : "forgot.subtitle"
            )
          : undefined
      }
      exitLabel={t("auth.backToBrowsing")}
      topRight={<LanguageSelector compact />}
    >

        {step === "email" ? (
          <form className="space-y-4" onSubmit={handleSubmit}>
            <label className="block">
              <span className="mb-1 block text-sm font-medium text-slate-600 dark:text-slate-300">
                {t("auth.email")}
              </span>
              <div className="flex items-center gap-3 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 transition-all duration-200 focus-within:border-purple-400 focus-within:ring-2 focus-within:ring-purple-200 dark:border-slate-700 dark:bg-slate-800">
                <MailIcon />
                <input
                  {...emailFieldProps}
                  placeholder={t("auth.emailPlaceholder")}
                  className="w-full bg-transparent text-slate-700 outline-none placeholder:text-slate-400 dark:text-white dark:placeholder:text-slate-500"
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                  required
                />
              </div>
            </label>

            <button
              type="submit"
              disabled={loading || !trimmedEmail}
              className="w-full rounded-xl bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2.5 text-sm font-semibold text-white shadow-lg transition-all duration-200 hover:scale-[1.02] hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
            >
              {loading
                ? t("forgot.sending")
                : t(
                    passwordResetOtpEnabled
                      ? "forgot.sendCode"
                      : "forgot.sendReset"
                  )}
            </button>
          </form>
        ) : null}

        {step === "code" && !done ? (
          <form
            className="space-y-4"
            onSubmit={(event) => {
              event.preventDefault();
              void submitCode();
            }}
          >
            {/*
              A password manager will not offer to save a new password unless
              it can tell which account the password belongs to, and the only
              signal it has is a username field in the same form. This one is
              not for the person to read or edit — the address was entered on
              the previous step — so it is hidden from sight and from the
              accessibility tree, and left readOnly so nothing here can change
              it. Without it, iOS Keychain and 1Password save an orphan entry
              or nothing at all.
            */}
            <input
              type="email"
              name="username"
              autoComplete="username"
              value={trimmedEmail}
              readOnly
              tabIndex={-1}
              aria-hidden="true"
              className="sr-only"
            />

            <VerificationCodeInput
              value={code}
              onChange={setCode}
              length={RESET_CODE_LENGTH}
              label={t("forgot.codeLabel")}
              hint={t("forgot.codeHint", { length: RESET_CODE_LENGTH })}
              disabled={loading}
              autoFocus
            />

            <label className="block">
              <span className="mb-1 block text-sm font-medium text-slate-600 dark:text-slate-300">
                {t("forgot.newPasswordLabel")}
              </span>
              <div className="flex items-center gap-3 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 transition-all duration-200 focus-within:border-purple-400 focus-within:ring-2 focus-within:ring-purple-200 dark:border-slate-700 dark:bg-slate-800">
                <LockIcon />
                <input
                  type={showPassword ? "text" : "password"}
                  {...newPasswordFieldProps}
                  placeholder={t("forgot.newPasswordPlaceholder")}
                  className="w-full bg-transparent text-slate-700 outline-none placeholder:text-slate-400 dark:text-white dark:placeholder:text-slate-500"
                  value={newPassword}
                  onChange={(event) => setNewPassword(event.target.value)}
                  required
                />
                <PasswordVisibilityButton
                  visible={showPassword}
                  onToggle={() => setShowPassword((prev) => !prev)}
                  showLabel={t("auth.show")}
                  hideLabel={t("auth.hide")}
                />
              </div>
              <div className="mt-2">
                <PasswordStrengthIndicator password={newPassword} />
              </div>
            </label>

            <button
              type="submit"
              disabled={
                loading ||
                code.length !== RESET_CODE_LENGTH ||
                newPassword.length === 0
              }
              className="w-full rounded-xl bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2.5 text-sm font-semibold text-white shadow-lg transition-all duration-200 hover:scale-[1.02] hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
            >
              {loading
                ? t("forgot.settingPassword")
                : t("forgot.setPassword")}
            </button>
          </form>
        ) : null}

        {done ? (
          <div className="rounded-2xl bg-emerald-50 p-5 text-center dark:bg-emerald-500/10">
            <Check
              size={32}
              strokeWidth={2.4}
              className="mx-auto text-emerald-600 dark:text-emerald-300"
              aria-hidden="true"
            />
            <h3 className="mt-2 text-base font-semibold text-emerald-700 dark:text-emerald-200">
              {t("forgot.doneTitle")}
            </h3>
            {/* Says the sessions were revoked, because they were: the server
                calls revokeRefreshTokens, and somebody who has just reset a
                password usually wants to know that. */}
            <p className="mt-1 text-sm text-emerald-600 dark:text-emerald-300">
              {t("forgot.doneBody")}
            </p>
            <Link
              to="/login"
              className="mt-4 inline-block w-full rounded-xl bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2.5 text-sm font-semibold text-white shadow-lg transition-all duration-200 hover:brightness-110"
            >
              {t("forgot.goToLogin")}
            </Link>
          </div>
        ) : null}

        {status !== "idle" && !done ? (
          <div
            role="status"
            aria-live="polite"
            className={`mt-4 rounded-xl px-4 py-2 text-sm ${
              status === "success"
                ? "bg-emerald-50 text-emerald-600 dark:bg-emerald-500/10 dark:text-emerald-300"
                : "bg-red-50 text-red-600 dark:bg-red-500/10 dark:text-red-300"
            }`}
          >
            {message}
          </div>
        ) : null}

        {showSpamHint ? (
          <p className="mt-3 text-center text-xs text-slate-400 dark:text-slate-500">
            {t("forgot.spamHint")}
          </p>
        ) : null}

        {!done && (status === "success" || step === "code") ? (
          <div className="mt-4 flex flex-col items-center gap-2">
            <button
              type="button"
              disabled={loading || cooldown > 0}
              onClick={() =>
                void (passwordResetOtpEnabled
                  ? sendCode(challengeId)
                  : sendLink())
              }
              className="text-sm font-semibold text-purple-600 transition hover:text-purple-500 disabled:cursor-not-allowed disabled:text-slate-400 dark:disabled:text-slate-500"
            >
              {cooldown > 0
                ? t("forgot.resendIn", { seconds: cooldown })
                : passwordResetOtpEnabled
                  ? t("forgot.resend")
                  : t("forgot.resendLink")}
            </button>
            <button
              type="button"
              onClick={() => {
                // Back to the address field with everything about the old
                // attempt dropped, including the challenge.
                setStep("email");
                setChallengeId(null);
                setCode("");
                setNewPassword("");
                setStatus("idle");
                setMessage("");
                setCooldown(0);
              }}
              className="text-xs text-slate-400 underline underline-offset-2 transition hover:text-purple-500 dark:text-slate-500"
            >
              {t("forgot.changeEmail")}
            </button>
          </div>
        ) : null}

        {!done ? (
          <p className="mt-6 text-center text-sm text-slate-500 dark:text-slate-300">
            <Link
              to="/login"
              className="font-semibold text-purple-600 hover:text-purple-500"
            >
              {t("forgot.backToLogin")}
            </Link>
          </p>
        ) : null}
    </AuthShell>
  );
}
