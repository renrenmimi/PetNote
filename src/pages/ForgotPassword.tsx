import { useState } from "react";
import { Link } from "react-router-dom";
import { fetchSignInMethodsForEmail, sendPasswordResetEmail } from "firebase/auth";
import { LanguageSelector } from "../components/LanguageSelector";
import { useLanguage } from "../hooks/useLanguage";
import PawIcon from "../components/PawIcon";
import { auth } from "../services/firebase";

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

export function ForgotPassword() {
  const { t } = useLanguage();
  const [email, setEmail] = useState("");
  const [loading, setLoading] = useState(false);
  const [status, setStatus] = useState<"idle" | "success" | "error">("idle");
  const [message, setMessage] = useState("");
  const [googleOnly, setGoogleOnly] = useState(false);

  const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!email.trim()) return;
    setLoading(true);
    setStatus("idle");
    setMessage("");
    setGoogleOnly(false);
    try {
      let methods: string[] | null = null;
      try {
        methods = await fetchSignInMethodsForEmail(auth, email.trim());
      } catch {
        methods = null;
      }

      if (methods && methods.length > 0) {
        const hasPassword = methods.includes("password");
        const hasGoogle = methods.includes("google.com");
        if (!hasPassword && hasGoogle) {
          setGoogleOnly(true);
          setStatus("error");
          setMessage(t("forgot.googleOnly"));
          return;
        }
        if (!hasPassword) {
          setStatus("error");
          setMessage(t("forgot.noAccount"));
          return;
        }
      }

      await sendPasswordResetEmail(auth, email.trim());
      setStatus("success");
      setMessage(t("forgot.resetSent"));
    } catch {
      setStatus("error");
      setMessage(t("forgot.fallback"));
    } finally {
      setLoading(false);
    }
  };

  return (
    <main className="flex min-h-screen items-center justify-center bg-gradient-to-br from-purple-500 to-pink-500 px-4">
      <div className="w-full max-w-md rounded-3xl bg-white p-8 shadow-2xl dark:bg-slate-900">
        <div className="mb-6 flex justify-end">
          <LanguageSelector compact />
        </div>
        <div className="mb-6 text-center">
          <div className="flex justify-center">
            <PawIcon size={48} />
          </div>
          <h1 className="mt-2 text-2xl font-semibold text-slate-900 dark:text-white">
            {t("common.appName")}
          </h1>
          <h2 className="mt-4 text-lg font-semibold text-slate-900 dark:text-white">
            {t("forgot.title")}
          </h2>
          <p className="mt-1 text-sm text-slate-500 dark:text-slate-300">
            {t("forgot.subtitle")}
          </p>
        </div>

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

          <button
            type="submit"
            disabled={loading || !email.trim()}
            className="w-full rounded-xl bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2.5 text-sm font-semibold text-white shadow-lg transition-all duration-200 hover:scale-[1.02] hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
          >
            {loading ? t("forgot.sending") : t("forgot.sendReset")}
          </button>
        </form>

        {status !== "idle" ? (
          <div
            className={`mt-4 rounded-xl px-4 py-2 text-sm ${
              status === "success"
                ? "bg-emerald-50 text-emerald-600 dark:bg-emerald-500/10 dark:text-emerald-300"
                : "bg-red-50 text-red-600 dark:bg-red-500/10 dark:text-red-300"
            }`}
          >
            {status === "success" ? "📧 " : ""} {message}
          </div>
        ) : null}

        {googleOnly ? (
          <div className="mt-4 rounded-xl border border-blue-200 bg-blue-50 px-4 py-3 text-sm text-blue-700 dark:border-blue-500/40 dark:bg-blue-500/10 dark:text-blue-200">
            <div className="flex items-center gap-2">
              <GoogleIcon />
              <span>{t("forgot.googleAccount")}</span>
            </div>
            <Link
              to="/login"
              className="mt-2 inline-block rounded-full bg-white px-3 py-1.5 text-xs font-semibold text-blue-600 shadow-sm transition hover:bg-blue-100 dark:bg-slate-900 dark:text-blue-200"
            >
              {t("forgot.googleCta")}
            </Link>
          </div>
        ) : null}

        <p className="mt-6 text-center text-sm text-slate-500 dark:text-slate-300">
          <Link
            to="/login"
            className="font-semibold text-purple-600 hover:text-purple-500"
          >
            {t("forgot.backToLogin")}
          </Link>
        </p>
      </div>
    </main>
  );
}
