import { useLanguage } from "../hooks/useLanguage";

export type ToastType = "success" | "error" | "warning" | "info";

export type ToastItem = {
  id: string;
  message: string;
  type: ToastType;
};

const toneClasses: Record<ToastType, string> = {
  success: "bg-emerald-500 text-white",
  error: "bg-red-500 text-white",
  warning: "bg-amber-500 text-white",
  info: "bg-blue-500 text-white",
};

const toneIcon: Record<ToastType, string> = {
  success: "✓",
  error: "✕",
  warning: "⚠",
  info: "ℹ",
};

type ToastProps = {
  toast: ToastItem;
  onDismiss: (id: string) => void;
};

export function Toast({ toast, onDismiss }: ToastProps) {
  const { t } = useLanguage();

  return (
    <div
      role="status"
      aria-live="polite"
      aria-atomic="true"
      className={`flex w-full max-w-xs items-center gap-3 rounded-xl px-4 py-2 text-xs font-semibold shadow-lg transition-all duration-300 ${toneClasses[toast.type]}`}
    >
      <span className="text-sm" aria-hidden="true">{toneIcon[toast.type]}</span>
      <span className="flex-1">{toast.message}</span>
      <button
        type="button"
        onClick={() => onDismiss(toast.id)}
        className="text-sm opacity-80 transition hover:opacity-100"
        aria-label={t("common.close")}
      >
        ✕
      </button>
    </div>
  );
}
