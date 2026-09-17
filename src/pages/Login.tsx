import { useState } from "react";
import { GoogleButton } from "../components/GoogleButton";
import { Link, useLocation, useNavigate } from "react-router-dom";
import { AuthNotice } from "../components/AuthNotice";
import { LanguageSelector } from "../components/LanguageSelector";
import { PasswordVisibilityButton } from "../components/PasswordVisibilityButton";
import { useAuth } from "../hooks/useAuth";
import { useLanguage } from "../hooks/useLanguage";
import { emailFieldProps, currentPasswordFieldProps } from "../utils/formFields";
import { mapAuthError } from "../utils/authErrors";
import { AuthShell } from "../components/AuthShell";

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


type LoginNotice = {
  title: string;
  message: string;
  actionLabel?: string;
  action?: () => void;
  tone?: "error" | "info" | "success";
};

export function Login() {
  const navigate = useNavigate();
  const location = useLocation();
  const { signIn, signInWithGoogle } = useAuth();
  const { t } = useLanguage();
  const initialEmail =
    typeof (location.state as { email?: unknown } | null)?.email === "string"
      ? String((location.state as { email: string }).email)
      : "";
  // RequireAuth (and BottomNav) pass the page the user was trying to reach;
  // without consuming it here every login dumped deep links onto the feed.
  const fromLocation = (
    location.state as { from?: { pathname?: string; search?: string } } | null
  )?.from;
  const redirectTo = fromLocation?.pathname
    ? `${fromLocation.pathname}${fromLocation.search ?? ""}`
    : "/";
  const [email, setEmail] = useState(initialEmail);
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [googleLoading, setGoogleLoading] = useState(false);
  const [notice, setNotice] = useState<LoginNotice | null>(null);
  const isDisabled = loading || !password || !email.trim();

  const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setLoading(true);
    setNotice(null);
    const normalizedEmail = email.trim();

    try {
      await signIn(normalizedEmail, password);
      navigate(redirectTo, { replace: true });
    } catch (err) {
      // One mapping for every code, shared with the Google path below and
      // with sign-up. No branch falls back on err.message: the raw Firebase
      // string used to end up on screen here. And no branch offers "create
      // an account" — mistyping a password is not evidence of not having one,
      // and the sign-up link is already on this page.
      const notice = mapAuthError(err);
      if (notice) {
        setNotice({
          title: t(notice.titleKey),
          message: t(notice.messageKey),
        });
      }
    } finally {
      setLoading(false);
    }
  };

  const handleGoogle = async () => {
    setGoogleLoading(true);
    setNotice(null);
    try {
      await signInWithGoogle();
      navigate(redirectTo, { replace: true });
    } catch (err) {
      // mapAuthError returns null when the person dismissed the Google
      // sheet themselves; an error banner for that is noise.
      const notice = mapAuthError(err);
      if (notice) {
        setNotice({
          title: t(notice.titleKey),
          message: t(notice.messageKey),
        });
      }
    } finally {
      setGoogleLoading(false);
    }
  };

  return (
    <AuthShell
      title={t("login.heading")}
      subtitle={t("login.tagline")}
      exitLabel={t("auth.backToBrowsing")}
      topRight={<LanguageSelector compact />}
    >

      {notice ? (
        <div className="mb-4">
          <AuthNotice
            title={notice.title}
            message={notice.message}
            actionLabel={notice.actionLabel}
            onAction={notice.action}
            onDismiss={() => setNotice(null)}
            closeLabel={t("auth.noticeClose")}
            tone={notice.tone}
          />
        </div>
      ) : null}

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
              className="w-full bg-transparent text-sm text-slate-700 outline-none placeholder:text-slate-400 dark:text-white dark:placeholder:text-slate-500"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              required
            />
          </div>
        </label>

        <label className="block">
          <span className="mb-1 block text-sm font-medium text-slate-600 dark:text-slate-300">
            {t("auth.password")}
          </span>
          <div className="flex items-center gap-3 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 transition-all duration-200 focus-within:border-purple-400 focus-within:ring-2 focus-within:ring-purple-200 dark:border-slate-700 dark:bg-slate-800">
            <LockIcon />
            <input
              type={showPassword ? "text" : "password"}
              placeholder={t("login.passwordPlaceholder")}
              {...currentPasswordFieldProps}
              className="w-full bg-transparent text-sm text-slate-700 outline-none placeholder:text-slate-400 dark:text-white dark:placeholder:text-slate-500"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              required
            />
            <PasswordVisibilityButton
              visible={showPassword}
              onToggle={() => setShowPassword((prev) => !prev)}
              showLabel={t("auth.show")}
              hideLabel={t("auth.hide")}
            />
          </div>
          <div className="mt-2 text-right">
            <Link
              to="/forgot-password"
              className="text-xs text-slate-400 transition-all duration-200 hover:text-purple-500 dark:text-slate-500"
            >
              {t("login.forgotPassword")}
            </Link>
          </div>
        </label>

        <button
          type="submit"
          disabled={isDisabled}
          className="w-full rounded-xl bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2.5 text-sm font-semibold text-white shadow-lg transition-all duration-200 hover:scale-[1.02] hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
        >
          {loading ? t("login.signingIn") : t("login.signIn")}
        </button>
      </form>

      <div className="my-6 flex items-center gap-3 text-xs text-slate-400 dark:text-slate-500">
        <span className="h-px flex-1 bg-slate-200 dark:bg-slate-700" />
        {t("common.or")}
        <span className="h-px flex-1 bg-slate-200 dark:bg-slate-700" />
      </div>

      <GoogleButton
        onClick={handleGoogle}
        loading={googleLoading}
        label={t("login.continueWithGoogle")}
        loadingLabel={t("login.connecting")}
      />

      <p className="mt-6 text-center text-sm text-slate-500 dark:text-slate-300">
        {t("login.noAccount")}
        {/* Carries the destination across, so signing up from a deep link
            still lands on the thing the person came for. */}
        <Link
          to="/signup"
          state={fromLocation ? { from: fromLocation } : undefined}
          className="ml-1 font-semibold text-purple-600 hover:text-purple-500"
        >
          {t("login.signUpCta")}
        </Link>
      </p>
      <p className="mt-3 text-center text-xs text-slate-400 dark:text-slate-500">
        <Link to="/terms" className="hover:text-slate-600 dark:hover:text-slate-300">
          {t("settings.terms")}
        </Link>{" "}
        ·{" "}
        <Link to="/privacy" className="hover:text-slate-600 dark:hover:text-slate-300">
          {t("settings.privacy")}
        </Link>
      </p>
    </AuthShell>
  );
}
