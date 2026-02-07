import { useState } from "react";
import { sendEmailVerification } from "firebase/auth";
import { useAuth } from "../hooks/useAuth";
import { useToast } from "../contexts/ToastContext";

export function EmailVerificationBanner() {
  const { user } = useAuth();
  const { showToast } = useToast();
  const [dismissed, setDismissed] = useState(false);
  const [sending, setSending] = useState(false);
  const [sent, setSent] = useState(false);

  if (!user || user.emailVerified || dismissed) {
    return null;
  }

  const handleResend = async () => {
    if (sending) return;
    setSending(true);
    try {
      await sendEmailVerification(user);
      setSent(true);
      showToast("Verification email sent!", "success");
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to send verification email.";
      showToast(message, "error");
    } finally {
      setSending(false);
    }
  };

  return (
    <div className="rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-700 shadow-[0_12px_30px_-20px_rgba(15,23,42,0.5)] dark:border-amber-500/40 dark:bg-amber-500/10 dark:text-amber-200">
      <div className="flex items-start justify-between gap-3">
        <div className="space-y-1">
          <p className="font-semibold">Please verify your email address</p>
          <p className="text-xs text-amber-600/80 dark:text-amber-200/80">
            We&apos;ll send you a quick verification email.
          </p>
          {sent ? (
            <p className="text-xs font-semibold text-emerald-600 dark:text-emerald-300">
              Verification email sent!
            </p>
          ) : null}
        </div>
        <button
          type="button"
          onClick={() => setDismissed(true)}
          className="text-sm text-amber-500 transition hover:text-amber-700 dark:text-amber-200"
          aria-label="Dismiss banner"
        >
          ✕
        </button>
      </div>
      <div className="mt-3 flex items-center gap-2">
        <button
          type="button"
          onClick={handleResend}
          disabled={sending}
          className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-1.5 text-xs font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
        >
          {sending ? "Sending..." : "Resend verification email"}
        </button>
      </div>
    </div>
  );
}
