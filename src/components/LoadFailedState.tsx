import { useState } from "react";

type LoadFailedStateProps = {
  title: string;
  description: string;
  retryLabel: string;
  retryingLabel?: string;
  /** Return value is ignored; callers may report success however they like. */
  onRetry: () => unknown;
};

/**
 * "We could not load this", as distinct from "there is nothing here".
 *
 * These were the same screen. A feed whose request failed rendered the
 * welcome card — "Share your pet's first moment!" — because the only test
 * was `posts.length === 0`, and the failure itself went out as a toast that
 * had usually vanished by the time anyone read the page. Somebody offline
 * was being told their account was empty.
 *
 * Deliberately not an EmptyState variant: an empty state invites you to
 * create something, and offering that as the response to a failed request is
 * the wrong next step. This one offers the only useful action, which is to
 * try again.
 */
export function LoadFailedState({
  title,
  description,
  retryLabel,
  retryingLabel,
  onRetry,
}: LoadFailedStateProps) {
  const [retrying, setRetrying] = useState(false);

  const handleRetry = async () => {
    if (retrying) return;
    setRetrying(true);
    try {
      await onRetry();
    } finally {
      setRetrying(false);
    }
  };

  return (
    <div
      role="alert"
      className="rounded-2xl bg-white p-8 text-center shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700"
    >
      <div className="text-4xl" aria-hidden="true">
        📡
      </div>
      <h3 className="mt-3 text-base font-semibold text-slate-900 dark:text-white">
        {title}
      </h3>
      <p className="mt-1 text-sm text-slate-500 dark:text-slate-300">
        {description}
      </p>
      <button
        type="button"
        onClick={() => void handleRetry()}
        disabled={retrying}
        className="mt-4 min-h-11 rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-5 py-2 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
      >
        {retrying ? (retryingLabel ?? retryLabel) : retryLabel}
      </button>
    </div>
  );
}
