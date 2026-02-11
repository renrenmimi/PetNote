import { useMemo, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import PawIcon from "../components/PawIcon";
import { PasswordStrengthIndicator } from "../components/PasswordStrengthIndicator";
import { validatePassword } from "../utils/passwordValidator";
import { useToast } from "../contexts/ToastContext";

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

export function SignUp() {
  const navigate = useNavigate();
  const { signUp, signInWithGoogle } = useAuth();
  const { showToast } = useToast();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [showConfirm, setShowConfirm] = useState(false);
  const [loading, setLoading] = useState(false);
  const [googleLoading, setGoogleLoading] = useState(false);

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
    try {
      await signUp(email.trim(), password);
      navigate("/", { replace: true });
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Sign up failed. Please try again.";
      showToast(message, "error");
    } finally {
      setLoading(false);
    }
  };

  const handleGoogle = async () => {
    setGoogleLoading(true);
    try {
      await signInWithGoogle();
      navigate("/", { replace: true });
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Google sign-in failed.";
      showToast(message, "error");
    } finally {
      setGoogleLoading(false);
    }
  };

  return (
    <main className="flex min-h-screen items-center justify-center bg-gradient-to-br from-purple-500 to-pink-500 px-4">
      <div className="w-full max-w-md rounded-3xl bg-white p-8 shadow-2xl dark:bg-slate-900">
        <div className="mb-8 text-center">
          <div className="flex justify-center">
            <PawIcon size={48} />
          </div>
          <h1 className="mt-2 text-2xl font-semibold text-slate-900 dark:text-white">
            PetNote
          </h1>
          <p className="mt-1 text-sm text-slate-500 dark:text-slate-300">
            Create an account to start sharing your pet's story
          </p>
        </div>

        <form className="space-y-4" onSubmit={handleSubmit}>
          <label className="block">
            <span className="mb-1 block text-sm font-medium text-slate-600 dark:text-slate-300">
              Email
            </span>
            <div className="flex items-center gap-3 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 transition-all duration-200 focus-within:border-purple-400 focus-within:ring-2 focus-within:ring-purple-200 dark:border-slate-700 dark:bg-slate-800">
              <MailIcon />
              <input
                type="email"
                placeholder="you@example.com"
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
              Password
            </span>
            <div className="flex items-center gap-3 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 transition-all duration-200 focus-within:border-purple-400 focus-within:ring-2 focus-within:ring-purple-200 dark:border-slate-700 dark:bg-slate-800">
              <LockIcon />
              <input
                type={showPassword ? "text" : "password"}
                placeholder="At least 8 characters"
                autoComplete="new-password"
                className="w-full bg-transparent text-sm text-slate-700 outline-none placeholder:text-slate-400 dark:text-white dark:placeholder:text-slate-500"
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                required
              />
              <button
                type="button"
                onClick={() => setShowPassword((prev) => !prev)}
                className="text-xs text-slate-400 transition-all duration-200 hover:text-purple-500 dark:text-slate-500"
              >
                {showPassword ? "Hide" : "Show"}
              </button>
            </div>
            <div className="mt-2">
              <PasswordStrengthIndicator password={password} />
            </div>
          </label>

          <label className="block">
            <span className="mb-1 block text-sm font-medium text-slate-600 dark:text-slate-300">
              Confirm password
            </span>
            <div className="flex items-center gap-3 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 transition-all duration-200 focus-within:border-purple-400 focus-within:ring-2 focus-within:ring-purple-200 dark:border-slate-700 dark:bg-slate-800">
              <LockIcon />
              <input
                type={showConfirm ? "text" : "password"}
                placeholder="Re-enter your password"
                autoComplete="new-password"
                className="w-full bg-transparent text-sm text-slate-700 outline-none placeholder:text-slate-400 dark:text-white dark:placeholder:text-slate-500"
                value={confirmPassword}
                onChange={(event) => setConfirmPassword(event.target.value)}
                required
              />
              <button
                type="button"
                onClick={() => setShowConfirm((prev) => !prev)}
                className="text-xs text-slate-400 transition-all duration-200 hover:text-purple-500 dark:text-slate-500"
              >
                {showConfirm ? "Hide" : "Show"}
              </button>
            </div>
          </label>

          {!passwordsMatch && confirmPassword ? (
            <p className="text-xs text-red-500">Passwords don't match</p>
          ) : null}

          <button
            type="submit"
            disabled={!canSubmit}
            className="w-full rounded-xl bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2.5 text-sm font-semibold text-white shadow-lg transition-all duration-200 hover:scale-[1.02] hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
          >
            {loading ? "Creating account..." : "Sign Up"}
          </button>
          <p className="text-center text-xs text-gray-500 dark:text-gray-400">
            By signing up, you agree to our{" "}
            <Link
              to="/terms"
              className="font-semibold text-purple-600 underline underline-offset-2"
            >
              Terms of Service
            </Link>{" "}
            and{" "}
            <Link
              to="/privacy"
              className="font-semibold text-purple-600 underline underline-offset-2"
            >
              Privacy Policy
            </Link>
          </p>
        </form>

        <div className="my-6 flex items-center gap-3 text-xs text-slate-400 dark:text-slate-500">
          <span className="h-px flex-1 bg-slate-200 dark:bg-slate-700" />
          Or
          <span className="h-px flex-1 bg-slate-200 dark:bg-slate-700" />
        </div>

        <button
          type="button"
          onClick={handleGoogle}
          disabled={googleLoading}
          className="flex w-full items-center justify-center gap-3 rounded-xl border border-slate-200 bg-white px-4 py-2.5 text-sm font-semibold text-slate-700 transition-all duration-200 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-70 dark:border-slate-700 dark:bg-slate-900 dark:text-slate-200 dark:hover:bg-slate-800"
        >
          <GoogleIcon />
          {googleLoading ? "Connecting..." : "Continue with Google"}
        </button>

        <p className="mt-6 text-center text-sm text-slate-500 dark:text-slate-300">
          Already have an account?
          <Link
            to="/login"
            className="ml-1 font-semibold text-purple-600 hover:text-purple-500"
          >
            Sign in
          </Link>
        </p>
      </div>
    </main>
  );
}
