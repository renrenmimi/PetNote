import { useEffect, useRef, useState } from "react";
import { sendEmailVerification } from "firebase/auth";
import { useAuth } from "../hooks/useAuth";
import { useToast } from "../contexts/ToastContext";

/**
 * The banner for an account whose email is not verified yet.
 *
 * Three things were missing, and all three left people stuck rather than
 * merely mildly inconvenienced:
 *
 * 1. It did not say *which* address the link went to, so a typo in the email
 *    was invisible — the person kept checking an inbox that would never get it.
 * 2. There was no way to tell the app "I followed the link". Nothing in this
 *    tab learns that, because the link is often opened in a different browser
 *    or the mail app's web view, and onAuthStateChanged does not fire for it.
 *    Worse, the callables that gate publishing read `email_verified` off the
 *    ID token, and a cached token keeps saying false for up to an hour — so
 *    even reloading the page could still refuse to post.
 * 3. Resend had no cooldown and no honest failure state, so a failed send
 *    looked the same as a successful one.
 */

const RESEND_COOLDOWN_SECONDS = 60;

type SendState =
  | { kind: "idle" }
  | { kind: "sending" }
  | { kind: "sent" }
  | { kind: "failed"; message: string };

export function EmailVerificationBanner() {
  const { user, refreshUser } = useAuth();
  const { showToast } = useToast();
  const [dismissed, setDismissed] = useState(false);
  const [sendState, setSendState] = useState<SendState>({ kind: "idle" });
  const [cooldown, setCooldown] = useState(0);
  const [checking, setChecking] = useState(false);
  const [checkedAndStillUnverified, setCheckedAndStillUnverified] =
    useState(false);
  const mountedRef = useRef(true);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  useEffect(() => {
    if (cooldown <= 0) return;
    const timer = window.setTimeout(() => setCooldown((s) => s - 1), 1000);
    return () => window.clearTimeout(timer);
  }, [cooldown]);

  if (!user || user.emailVerified || dismissed) {
    return null;
  }

  const handleResend = async () => {
    if (sendState.kind === "sending" || cooldown > 0) return;
    setSendState({ kind: "sending" });
    try {
      await sendEmailVerification(user);
      if (!mountedRef.current) return;
      setSendState({ kind: "sent" });
      // A cooldown so a person tapping repeatedly gets a straight answer
      // instead of Firebase's own rate limiter surfacing as a raw error.
      setCooldown(RESEND_COOLDOWN_SECONDS);
    } catch (err) {
      if (!mountedRef.current) return;
      const message =
        err instanceof Error ? err.message : "We couldn't send that email.";
      setSendState({ kind: "failed", message });
      showToast(message, "error");
    }
  };

  const handleCheckVerified = async () => {
    if (checking) return;
    setChecking(true);
    setCheckedAndStillUnverified(false);
    try {
      const verified = await refreshUser();
      if (!mountedRef.current) return;
      if (verified) {
        // The banner unmounts on the next render because user.emailVerified is
        // now true, and the fresh ID token means publishing works immediately
        // rather than after the old token expires.
        showToast("Email verified — you can post now.", "success");
      } else {
        setCheckedAndStillUnverified(true);
      }
    } catch {
      if (!mountedRef.current) return;
      showToast("Couldn't check just now. Try again in a moment.", "error");
    } finally {
      if (mountedRef.current) setChecking(false);
    }
  };

  const resendLabel =
    sendState.kind === "sending"
      ? "Sending..."
      : cooldown > 0
      ? `Resend in ${cooldown}s`
      : "Resend email";

  return (
    <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-left text-sm text-amber-700 shadow-[0_12px_30px_-20px_rgba(15,23,42,0.5)] dark:border-amber-500/40 dark:bg-amber-500/10 dark:text-amber-200">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0 text-left">
          <p className="text-sm font-semibold text-amber-800 dark:text-amber-300">
            Verify your email to start posting and commenting
          </p>
          {/* The exact address. A mistyped email was previously invisible: the
              banner said "check your inbox" without saying which one. */}
          <p className="mt-1 break-words text-xs text-amber-700 dark:text-amber-400">
            {user.email ? (
              <>
                We sent a link to{" "}
                <span className="font-semibold">{user.email}</span>. Open it,
                then come back here.
              </>
            ) : (
              "Open the verification link we emailed you, then come back here."
            )}
          </p>

          {sendState.kind === "sent" ? (
            <p className="mt-1 text-xs font-semibold text-emerald-600 dark:text-emerald-300">
              Sent. It can take a minute to arrive.
            </p>
          ) : null}
          {sendState.kind === "failed" ? (
            <p className="mt-1 text-xs font-semibold text-rose-600 dark:text-rose-300">
              We couldn&apos;t send it: {sendState.message}
            </p>
          ) : null}
          {checkedAndStillUnverified ? (
            <p className="mt-1 text-xs font-semibold text-amber-800 dark:text-amber-300">
              Still not verified. Open the link in the email first — if it has
              expired, resend it below.
            </p>
          ) : null}

          <div className="mt-2 flex flex-wrap items-center gap-3">
            <button
              type="button"
              onClick={handleCheckVerified}
              disabled={checking}
              className="rounded-full bg-amber-600 px-3 py-1 text-xs font-semibold text-white transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
            >
              {checking ? "Checking..." : "I verified my email"}
            </button>
            <button
              type="button"
              onClick={handleResend}
              disabled={sendState.kind === "sending" || cooldown > 0}
              className="text-left text-xs font-semibold text-amber-800 underline transition hover:text-amber-900 disabled:cursor-not-allowed disabled:no-underline disabled:opacity-70 dark:text-amber-300 dark:hover:text-amber-200"
            >
              {resendLabel}
            </button>
          </div>
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
