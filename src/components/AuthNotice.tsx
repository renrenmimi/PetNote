type AuthNoticeProps = {
  title: string;
  message: string;
  actionLabel?: string;
  closeLabel?: string;
  onAction?: () => void;
  onDismiss?: () => void;
  tone?: "error" | "info" | "success";
};

const toneClasses = {
  error:
    "border-red-200 bg-red-50 text-red-700 dark:border-red-500/40 dark:bg-red-500/10 dark:text-red-200",
  info:
    "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-500/40 dark:bg-blue-500/10 dark:text-blue-200",
  success:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-500/40 dark:bg-emerald-500/10 dark:text-emerald-200",
};

export function AuthNotice({
  title,
  message,
  actionLabel,
  closeLabel = "Close",
  onAction,
  onDismiss,
  tone = "error",
}: AuthNoticeProps) {
  return (
    <div
      role="alert"
      className={`rounded-2xl border px-4 py-3 text-left text-sm shadow-sm ${toneClasses[tone]}`}
    >
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="font-semibold">{title}</p>
          <p className="mt-1 text-xs leading-5 opacity-90">{message}</p>
        </div>
        {onDismiss ? (
          <button
            type="button"
            onClick={onDismiss}
            className="text-base leading-none opacity-70 transition hover:opacity-100"
            aria-label={closeLabel}
          >
            x
          </button>
        ) : null}
      </div>
      {actionLabel && onAction ? (
        <button
          type="button"
          onClick={onAction}
          className="mt-3 rounded-full bg-white px-3 py-1.5 text-xs font-semibold text-slate-700 shadow-sm transition hover:scale-[1.02] dark:bg-slate-900 dark:text-white"
        >
          {actionLabel}
        </button>
      ) : null}
    </div>
  );
}
