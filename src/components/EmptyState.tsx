type EmptyStateProps = {
  icon: string;
  title: string;
  description: string;
  actionText?: string;
  onAction?: () => void;
};

export function EmptyState({
  icon,
  title,
  description,
  actionText,
  onAction,
}: EmptyStateProps) {
  return (
    <div className="rounded-2xl bg-white p-8 text-center shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
      <div className="text-4xl">{icon}</div>
      <h3 className="mt-3 text-base font-semibold text-slate-900 dark:text-white">
        {title}
      </h3>
      <p className="mt-1 text-sm text-slate-500 dark:text-slate-300">
        {description}
      </p>
      {actionText && onAction ? (
        <button
          type="button"
          onClick={onAction}
          className="mt-4 rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-xs font-semibold text-white transition-all duration-200 hover:brightness-110"
        >
          {actionText}
        </button>
      ) : null}
    </div>
  );
}
