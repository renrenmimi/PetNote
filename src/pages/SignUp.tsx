import { useMemo, useState } from "react";
import { GoogleButton } from "../components/GoogleButton";
import { Link, useLocation, useNavigate } from "react-router-dom";
import { AuthNotice } from "../components/AuthNotice";
import { LanguageSelector } from "../components/LanguageSelector";
import { PasswordVisibilityButton } from "../components/PasswordVisibilityButton";
import { useAuth } from "../hooks/useAuth";
import { useToast } from "../contexts/ToastContext";
import { useLanguage } from "../hooks/useLanguage";
import { emailFieldProps, newPasswordFieldProps } from "../utils/formFields";
import { mapAuthError } from "../utils/authErrors";
import { AuthShell } from "../components/AuthShell";
import { PasswordStrengthIndicator } from "../components/PasswordStrengthIndicator";
import { validatePassword } from "../utils/passwordValidator";

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


type SignUpNotice = {
  title: string;
  message: string;
  actionLabel?: string;
  action?: () => void;
};

export function SignUp() {
  const navigate = useNavigate();
  const location = useLocation();
  const { signUp, signInWithGoogle } = useAuth();
  const { showToast } = useToast();
  const { t } = useLanguage();
  const initialEmail =
    typeof (location.state as { email?: unknown } | null)?.email === "string"
      ? String((location.state as { email: string }).email)
      : "";
  // Where the person was trying to go before being asked to sign in. Login
  // already consumed this; SignUp threw it away and always landed on the feed,
  // so an invitation link or a deep link into the composer was lost by the
  // time the account existed.
  const fromLocation = (
    location.state as { from?: { pathname?: string; search?: string } } | null
  )?.from;
  const redirectTo = fromLocation?.pathname
    ? `${fromLocation.pathname}${fromLocation.search ?? ""}`
    : "/";
  const [email, setEmail] = useState(initialEmail);
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [showConfirm, setShowConfirm] = useState(false);
  const [loading, setLoading] = useState(false);
  const [googleLoading, setGoogleLoading] = useState(false);
  const [notice, setNotice] = useState<SignUpNotice | null>(null);

  const validation = useMemo(() => validatePassword(password), [password]);
  const passwordsMatch = password === confirmPassword;
  const canSubmit =
    email.trim() !== "" &&
    password.length >= 8 &&
    confirmPassword.length > 0 &&
    passwordsMatch &&
    validation.isValid &&
    !loading;

  const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!canSubmit) return;

    setLoading(true);
    setNotice(null);
    const normalizedEmail = email.trim();
    try {
      const outcome = await signUp(normalizedEmail, password);
      // The account exists. Anything else that went wrong is a "finish setting
      // up" problem, not a failed sign-up — the old code reported both the
      // same way, so a failed profile write sent people back to sign up again
      // and straight into email-already-in-use on their own new account.
      if (!outcome.verificationSent) {
        showToast(
          `Account created, but we couldn't send the verification email to ${normalizedEmail}. Use "Resend email" on the banner.`,
          "warning"
        );
      } else if (!outcome.profileCreated) {
        showToast(
          "Account created. We're still finishing your profile setup.",
          "warning"
        );
      }
      // Keep the destination the person was heading for.
      navigate(redirectTo, { replace: true });
    } catch (err) {
      const code =
        err && typeof err === "object" && "code" in err
          ? String((err as { code?: string }).code)
          : "";
      // Note: the email and both password fields are deliberately NOT cleared
      // here. Making somebody retype a password because a request failed is
      // its own small punishment, and it defeats the password manager.
      if (code.includes("email-already-in-use")) {
        setNotice({
          title: t("signup.emailExistsTitle"),
          message: t("signup.emailExistsMessage"),
          actionLabel: t("signup.emailExistsAction"),
          action: () =>
            navigate("/login", {
              state: { email: normalizedEmail, ...(fromLocation ? { from: fromLocation } : {}) },
            }),
        });
      } else if (code.includes("invalid-email")) {
        setNotice({
          title: t("signup.invalidEmailTitle"),
          message: t("signup.invalidEmailMessage"),
        });
      } else if (code.includes("weak-password")) {
        setNotice({
          title: t("signup.weakPasswordTitle"),
          message: t("signup.weakPasswordMessage"),
        });
      } else if (code.includes("network-request-failed")) {
        setNotice({
          title: t("auth.networkErrorTitle"),
          message: t("auth.networkErrorMessage"),
        });
      } else if (code.includes("too-many-requests")) {
        setNotice({
          title: t("auth.tooManyRequestsTitle"),
          message: t("auth.tooManyRequestsMessage"),
        });
      } else if (code.includes("operation-not-allowed")) {
        setNotice({
          title: t("auth.genericErrorTitle"),
          message: t("signup.emailSignUpDisabled"),
        });
      } else {
        // Shared mapping for everything sign-up has no special copy for. It
        // never returns a raw SDK string, which is what used to reach this
        // branch: "Firebase: Error (auth/...)" tells a person nothing they
        // can act on.
        const notice = mapAuthError(err);
        if (notice) {
          setNotice({
            title: t(notice.titleKey),
            message: t(notice.messageKey),
          });
        }
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
      // null when the Google sheet was dismissed on purpose — no banner.
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
      title={t("signup.heading")}
      subtitle={t("signup.tagline")}
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
              placeholder={t("signup.passwordPlaceholder")}
              {...newPasswordFieldProps}
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
          <div className="mt-2">
            <PasswordStrengthIndicator password={password} />
          </div>
        </label>

        <label className="block">
          <span className="mb-1 block text-sm font-medium text-slate-600 dark:text-slate-300">
            {t("signup.confirmPassword")}
          </span>
          <div className="flex items-center gap-3 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 transition-all duration-200 focus-within:border-purple-400 focus-within:ring-2 focus-within:ring-purple-200 dark:border-slate-700 dark:bg-slate-800">
            <LockIcon />
            <input
              type={showConfirm ? "text" : "password"}
              placeholder={t("signup.confirmPasswordPlaceholder")}
              {...newPasswordFieldProps}
              className="w-full bg-transparent text-sm text-slate-700 outline-none placeholder:text-slate-400 dark:text-white dark:placeholder:text-slate-500"
              value={confirmPassword}
              onChange={(event) => setConfirmPassword(event.target.value)}
              required
            />
            <PasswordVisibilityButton
              visible={showConfirm}
              onToggle={() => setShowConfirm((prev) => !prev)}
              showLabel={t("auth.show")}
              hideLabel={t("auth.hide")}
            />
          </div>
        </label>

        {!passwordsMatch && confirmPassword ? (
          <p className="text-xs text-red-500">{t("signup.passwordMismatch")}</p>
        ) : null}

        <button
          type="submit"
          disabled={!canSubmit}
          className="w-full rounded-xl bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2.5 text-sm font-semibold text-white shadow-lg transition-all duration-200 hover:scale-[1.02] hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
        >
          {loading ? t("signup.creatingAccount") : t("signup.signUp")}
        </button>
        <p className="text-center text-xs text-gray-500 dark:text-gray-400">
          {t("signup.agreePrefix")}{" "}
          <Link
            to="/terms"
            className="font-semibold text-purple-600 underline underline-offset-2"
          >
            {t("settings.terms")}
          </Link>{" "}
          {t("signup.and")}{" "}
          <Link
            to="/privacy"
            className="font-semibold text-purple-600 underline underline-offset-2"
          >
            {t("settings.privacy")}
          </Link>
        </p>
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
        {t("signup.haveAccount")}
        <Link
          to="/login"
          state={fromLocation ? { from: fromLocation } : undefined}
          className="ml-1 font-semibold text-purple-600 hover:text-purple-500"
        >
          {t("signup.loginCta")}
        </Link>
      </p>
    </AuthShell>
  );
}
