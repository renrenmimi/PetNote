import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { useAuth } from "../hooks/useAuth";
import { reportContent, type ReportTargetType } from "../services/report";
import { useToast } from "../contexts/ToastContext";

type ReportModalProps = {
  open: boolean;
  onClose: () => void;
  targetType: ReportTargetType;
  targetId: string;
};

const reasons = [
  "Spam",
  "Inappropriate content",
  "Harassment",
  "Animal abuse 🐾",
  "Misinformation",
  "Other",
];

export function ReportModal({
  open,
  onClose,
  targetType,
  targetId,
}: ReportModalProps) {
  const { user } = useAuth();
  const { showToast } = useToast();
  const [selected, setSelected] = useState<string>("");
  const [customReason, setCustomReason] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const remaining = 500 - customReason.length;
  const counterTone =
    remaining <= 0
      ? "text-red-500"
      : remaining <= 100
      ? "text-amber-500"
      : "text-slate-400 dark:text-slate-500";

  useEffect(() => {
    if (!open) {
      setSelected("");
      setCustomReason("");
    }
  }, [open]);

  if (!open) return null;

  const handleSubmit = async () => {
    if (!user || submitting) return;
    const reason =
      selected === "Other" ? customReason.trim() || "Other" : selected;
    if (!reason) return;
    setSubmitting(true);
    try {
      const trimmedDetail = customReason.trim();
      await reportContent({
        reporterId: user.uid,
        reporterName: user.displayName || "PetNote User",
        ...(user.photoURL ? { reporterAvatar: user.photoURL } : {}),
        targetType,
        targetId,
        reason,
        ...(selected === "Other" && trimmedDetail
          ? { description: trimmedDetail }
          : {}),
      });
      showToast("Thank you for reporting. We'll review this shortly.", "success");
      onClose();
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to submit report.";
      showToast(message, "error");
    } finally {
      setSubmitting(false);
    }
  };

  // Portal to <body> so ancestors carrying transforms (e.g. PostCard's
  // hover lift) can't become the containing block for this fixed overlay.
  return createPortal(
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      onClick={onClose}
    >
      <div
        className="w-full max-w-sm rounded-2xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)] dark:bg-slate-800"
        onClick={(event) => event.stopPropagation()}
      >
        <h3 className="text-base font-semibold text-slate-900 dark:text-white">
          Report this {targetType}
        </h3>
        <>
          <div className="mt-4 space-y-2">
            {reasons.map((reason) => (
              <button
                key={reason}
                type="button"
                onClick={() => setSelected(reason)}
                className={`flex w-full items-center gap-3 rounded-xl border px-3 py-2 text-left text-sm transition-all duration-200 ${
                  selected === reason
                    ? "border-purple-400 bg-purple-50 text-purple-700 dark:bg-purple-500/10 dark:text-purple-200"
                    : "border-slate-200 text-slate-600 hover:border-purple-300 dark:border-slate-700 dark:text-slate-300"
                }`}
              >
                <span
                  className={`flex h-5 w-5 items-center justify-center rounded-full border text-xs ${
                    selected === reason
                      ? "border-purple-500 bg-purple-500 text-white"
                      : "border-slate-300 text-transparent dark:border-slate-600"
                  }`}
                >
                  ✓
                </span>
                {reason}
              </button>
            ))}
          </div>

          {selected === "Other" ? (
            <div className="mt-3 space-y-2">
              <textarea
                value={customReason}
                onChange={(event) => setCustomReason(event.target.value)}
                placeholder="Tell us more..."
                maxLength={500}
                rows={3}
                className="w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-700 dark:text-white"
              />
              <p className={`text-right text-[10px] ${counterTone}`}>
                {customReason.length}/500
              </p>
            </div>
          ) : null}

          <div className="mt-4 flex items-center justify-end gap-2">
            <button
              type="button"
              onClick={onClose}
              className="rounded-full px-4 py-2 text-sm font-semibold text-slate-500 transition-all duration-200 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
            >
              Cancel
            </button>
            <button
              type="button"
              onClick={handleSubmit}
              disabled={
                submitting ||
                !selected ||
                (selected === "Other" && (!customReason || customReason.length > 500))
              }
              className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
            >
              {submitting ? "Submitting..." : "Submit Report"}
            </button>
          </div>
        </>
      </div>
    </div>,
    document.body
  );
}
