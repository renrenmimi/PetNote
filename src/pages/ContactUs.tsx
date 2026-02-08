import { useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { useToast } from "../contexts/ToastContext";
import { submitFeedback, type FeedbackType } from "../services/feedback";
import PawIcon from "../components/PawIcon";

const types: Array<{ key: FeedbackType; label: string; emoji: string; color: string; bg: string }> = [
  { key: "bug", label: "Bug Report", emoji: "🐛", color: "border-red-300 text-red-500", bg: "bg-red-50" },
  { key: "feature", label: "Feature Request", emoji: "💡", color: "border-blue-300 text-blue-500", bg: "bg-blue-50" },
  { key: "complaint", label: "Complaint", emoji: "😕", color: "border-orange-300 text-orange-500", bg: "bg-orange-50" },
  { key: "other", label: "Other", emoji: "💬", color: "border-slate-300 text-slate-500", bg: "bg-slate-50" },
];

export function ContactUs() {
  const navigate = useNavigate();
  const { user, profile } = useAuth();
  const { showToast } = useToast();
  const [type, setType] = useState<FeedbackType>("bug");
  const [subject, setSubject] = useState("");
  const [message, setMessage] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [submitted, setSubmitted] = useState(false);

  const remainingSubject = 100 - subject.length;
  const remainingMessage = 1000 - message.length;

  const canSubmit = useMemo(() => {
    return subject.trim().length > 0 && message.trim().length > 0 && !submitting;
  }, [subject, message, submitting]);

  const handleSubmit = async () => {
    if (!user) {
      navigate("/login");
      return;
    }
    if (!canSubmit) return;
    setSubmitting(true);
    try {
      await submitFeedback({
        userId: user.uid,
        userName: profile?.displayName || user.displayName || "PetNote User",
        userEmail: user.email || "",
        type,
        subject: subject.trim(),
        message: message.trim(),
      });
      setSubmitted(true);
      showToast("Thanks for your feedback!", "success");
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to submit feedback.";
      showToast(message, "error");
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="min-h-screen bg-slate-50 pb-20 dark:bg-slate-900">
      <header className="sticky top-0 z-10 bg-white/90 backdrop-blur dark:bg-slate-900/90">
        <div className="mx-auto flex w-full max-w-md items-center gap-3 px-4 py-3">
          <button
            type="button"
            onClick={() => navigate(-1)}
            className="text-xl text-slate-500 hover:text-slate-700 dark:text-slate-300"
          >
            ←
          </button>
          <h1 className="text-base font-semibold text-slate-900 dark:text-white">
            Contact Us
          </h1>
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-5 px-4 py-5">
        {!submitted ? (
          <>
            <div className="rounded-2xl bg-white p-4 text-center shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
              <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-2xl bg-gradient-to-br from-purple-500 to-pink-500">
                <PawIcon size={36} />
              </div>
              <p className="mt-3 text-base font-semibold text-slate-900 dark:text-white">
                We’d love to hear from you! 🐾
              </p>
              <p className="mt-2 text-sm text-slate-500 dark:text-slate-400">
                Found a bug, have a feature idea, or just want to say hi? Send us a message.
              </p>
            </div>

            <section className="space-y-3">
              <p className="text-xs font-semibold uppercase tracking-wide text-slate-400">
                Feedback Type
              </p>
              <div className="grid grid-cols-2 gap-3">
                {types.map((item) => {
                  const active = type === item.key;
                  return (
                    <button
                      key={item.key}
                      type="button"
                      onClick={() => setType(item.key)}
                      className={`rounded-2xl border px-3 py-3 text-left transition-all duration-200 ${
                        active
                          ? `border-transparent bg-gradient-to-r from-purple-500 to-pink-500 text-white shadow-md`
                          : `border-slate-200 bg-white text-slate-600 dark:border-slate-700 dark:bg-slate-800 dark:text-slate-300`
                      }`}
                    >
                      <p className="text-lg">{item.emoji}</p>
                      <p className="mt-1 text-xs font-semibold">
                        {item.label}
                      </p>
                    </button>
                  );
                })}
              </div>
            </section>

            <section className="space-y-3">
              <label className="text-xs font-semibold uppercase tracking-wide text-slate-400">
                Subject
              </label>
              <div className="rounded-2xl border border-slate-200 bg-white px-3 py-2 shadow-sm dark:border-slate-700 dark:bg-slate-800">
                <input
                  type="text"
                  value={subject}
                  maxLength={100}
                  onChange={(event) => setSubject(event.target.value)}
                  placeholder="Brief description of your feedback"
                  className="w-full bg-transparent text-sm text-slate-700 outline-none placeholder:text-slate-400 dark:text-white"
                />
                <p className={`mt-1 text-right text-[11px] ${
                  remainingSubject < 20 ? "text-orange-500" : "text-slate-400"
                }`}
                >
                  {remainingSubject}/100
                </p>
              </div>
            </section>

            <section className="space-y-3">
              <label className="text-xs font-semibold uppercase tracking-wide text-slate-400">
                Message
              </label>
              <div className="rounded-2xl border border-slate-200 bg-white px-3 py-2 shadow-sm dark:border-slate-700 dark:bg-slate-800">
                <textarea
                  value={message}
                  maxLength={1000}
                  onChange={(event) => setMessage(event.target.value)}
                  placeholder="Tell us more details..."
                  rows={5}
                  className="w-full resize-none bg-transparent text-sm text-slate-700 outline-none placeholder:text-slate-400 dark:text-white"
                />
                <p className={`mt-1 text-right text-[11px] ${
                  remainingMessage < 200 ? "text-orange-500" : "text-slate-400"
                }`}
                >
                  {remainingMessage}/1000
                </p>
              </div>
            </section>

            <button
              type="button"
              disabled={!canSubmit}
              onClick={handleSubmit}
              className="w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-3 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
            >
              {submitting ? "Submitting..." : "Submit Feedback"}
            </button>
          </>
        ) : (
          <div className="rounded-2xl bg-white p-6 text-center shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
            <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full bg-emerald-100 text-emerald-600">
              ✓
            </div>
            <p className="mt-4 text-base font-semibold text-slate-900 dark:text-white">
              Thank you for your feedback!
            </p>
            <p className="mt-2 text-sm text-slate-500 dark:text-slate-400">
              We’ll review it shortly. 🐾
            </p>
            <button
              type="button"
              onClick={() => navigate("/")}
              className="mt-4 w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-3 text-sm font-semibold text-white"
            >
              Back to Home
            </button>
          </div>
        )}
      </main>
    </div>
  );
}
