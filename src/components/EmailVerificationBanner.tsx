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
    <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-left text-sm text-amber-700 shadow-[0_12px_30px_-20px_rgba(15,23,42,0.5)] dark:border-amber-500/40 dark:bg-amber-500/10 dark:text-amber-200">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0 text-left">
          <p className="text-sm font-semibold text-amber-800 dark:text-amber-300">
            Verify your email to start posting and commenting
          </p>
          <p className="mt-1 text-xs text-amber-700 dark:text-amber-400">
            Check your inbox for a verification link from PetNote.
          </p>
          <button
            type="button"
            onClick={handleResend}
            disabled={sending}
            className="mt-2 text-left text-xs font-semibold text-amber-800 underline transition hover:text-amber-900 disabled:cursor-not-allowed disabled:opacity-70 dark:text-amber-300 dark:hover:text-amber-200"
          >
            {sending ? "Sending..." : "Resend Email"}
          </button>
          {sent ? (
            <p className="mt-1 text-xs font-semibold text-emerald-600 dark:text-emerald-300">
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
    </div>
  );
}
