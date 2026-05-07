import { useState } from "react";
import { Link } from "react-router-dom";
import { sendPasswordResetEmail } from "firebase/auth";
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

export function ForgotPassword() {
  const { t } = useLanguage();
  const [email, setEmail] = useState("");
  const [loading, setLoading] = useState(false);
  const [status, setStatus] = useState<"idle" | "success" | "error">("idle");
  const [message, setMessage] = useState("");
  const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!email.trim()) return;
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
