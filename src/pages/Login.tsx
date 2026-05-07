import { useState } from "react";
import { Link, useLocation, useNavigate } from "react-router-dom";
import { AuthNotice } from "../components/AuthNotice";
import { LanguageSelector } from "../components/LanguageSelector";
import { PasswordVisibilityButton } from "../components/PasswordVisibilityButton";
import { useAuth } from "../hooks/useAuth";
import { useLanguage } from "../hooks/useLanguage";
import PawIcon from "../components/PawIcon";

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

function GoogleIcon() {
  return (
    <svg className="h-5 w-5" viewBox="0 0 48 48" aria-hidden="true">
      <path
        fill="#EA4335"
        d="M24 9.5c3.54 0 6.7 1.22 9.19 3.6l6.87-6.87C35.87 2.38 30.33 0 24 0 14.62 0 6.5 5.38 2.56 13.22l8.02 6.22C12.59 13.09 17.87 9.5 24 9.5z"
      />
      <path
        fill="#4285F4"
        d="M46.5 24.5c0-1.56-.14-3.06-.4-4.5H24v9h12.65c-.55 2.96-2.18 5.47-4.61 7.16l7.11 5.52c4.16-3.84 6.35-9.5 6.35-17.18z"
      />
      <path
        fill="#FBBC05"
        d="M10.58 28.87A14.5 14.5 0 0 1 9.5 24c0-1.7.29-3.35.81-4.9l-8.02-6.22A23.98 23.98 0 0 0 0 24c0 3.86.92 7.5 2.56 10.78l8.02-6.91z"
      />
      <path
        fill="#34A853"
        d="M24 48c6.33 0 11.64-2.08 15.52-5.64l-7.11-5.52c-2 1.35-4.56 2.16-8.41 2.16-6.13 0-11.41-3.59-13.42-8.69l-8.02 6.91C6.5 42.62 14.62 48 24 48z"
      />
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
  const [email, setEmail] = useState(initialEmail);
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [googleLoading, setGoogleLoading] = useState(false);
  const [notice, setNotice] = useState<LoginNotice | null>(null);
  const isDisabled = loading || password.length < 8 || !email.trim();

  const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setLoading(true);
    setNotice(null);
    const normalizedEmail = email.trim();

    try {
      await signIn(normalizedEmail, password);
      navigate("/", { replace: true });
    } catch (err) {
      const code =
        err && typeof err === "object" && "code" in err
          ? String((err as { code?: string }).code)
          : "";

      if (code.includes("invalid-email")) {
        setNotice({
          title: t("signup.invalidEmailTitle"),
          message: t("signup.invalidEmailMessage"),
        });
      } else if (
        code.includes("user-not-found") ||
        code.includes("wrong-password") ||
        code.includes("invalid-credential")
      ) {
        // Show a generic "invalid credentials" message with a sign-up
        // CTA. We used to call fetchSignInMethodsForEmail here to figure
        // out whether the email belonged to a Google-only account, but
        // that API was deprecated by Firebase under Email Enumeration
        // Protection (default since 2023-09) and now returns an empty
        // array regardless. The "Continue with Google" button below
        // covers the Google-only path without leaking account existence.
        setNotice({
          title: t("login.invalidTitle"),
          message: t("login.invalidMessage"),
          actionLabel: t("login.noAccountAction"),
          action: () =>
            navigate("/signup", { state: { email: normalizedEmail } }),
        });
      } else {
        setNotice({
          title: t("auth.genericErrorTitle"),
          message: err instanceof Error ? err.message : t("login.loginFailed"),
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
      navigate("/", { replace: true });
    } catch (err) {
      setNotice({
        title: t("auth.genericErrorTitle"),
        message: err instanceof Error ? err.message : t("login.googleFailed"),
      });
    } finally {
      setGoogleLoading(false);
    }
  };

  return (
    <main className="flex min-h-screen items-center justify-center bg-gradient-to-br from-purple-500 to-pink-500 px-4">
      <div className="w-full max-w-md rounded-3xl bg-white p-8 shadow-2xl dark:bg-slate-900">
        <div className="mb-6 flex justify-end">
          <LanguageSelector compact />
        </div>
        <div className="mb-8 text-center">
          <div className="flex justify-center">
            <PawIcon size={48} />
          </div>
          <h1 className="mt-2 text-2xl font-semibold text-slate-900 dark:text-white">
            {t("common.appName")}
          </h1>
          <p className="mx-auto mt-3 inline-flex rounded-full bg-purple-50 px-3 py-1 text-xs font-bold uppercase tracking-wide text-purple-600 dark:bg-purple-500/10 dark:text-purple-200">
            {t("login.badge")}
          </p>
          <h2 className="mt-3 text-xl font-semibold text-slate-900 dark:text-white">
            {t("login.heading")}
          </h2>
          <p className="mt-1 text-sm text-slate-500 dark:text-slate-300">
            {t("login.tagline")}
          </p>
        </div>

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
                type="email"
                placeholder={t("auth.emailPlaceholder")}
                autoComplete="email"
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
                autoComplete="current-password"
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

        <button
          type="button"
          onClick={handleGoogle}
          disabled={googleLoading}
          className="flex w-full items-center justify-center gap-3 rounded-xl border border-slate-200 bg-white px-4 py-2.5 text-sm font-semibold text-slate-700 transition-all duration-200 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-70 dark:border-slate-700 dark:bg-slate-900 dark:text-slate-200 dark:hover:bg-slate-800"
        >
          <GoogleIcon />
          {googleLoading ? t("login.connecting") : t("login.continueWithGoogle")}
        </button>

        <p className="mt-6 text-center text-sm text-slate-500 dark:text-slate-300">
          {t("login.noAccount")}
          <Link
            to="/signup"
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
      </div>
    </main>
  );
}
