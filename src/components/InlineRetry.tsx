import { useState } from "react";
import { RotateCw } from "lucide-react";

type InlineRetryProps = {
  /** What failed, in the page's own words: "Trending tags", "Reviews". */
  label: string;
  onRetry: () => unknown;
};

/**
 * One module failed; the rest of the page did not.
 *
 * A page is not one request. A profile is its header, its pets and its posts;
 * a place is its details, its photos and its reviews. Replacing all of it with
 * a full-screen error because one of those failed throws away content that
 * arrived perfectly well — so this is deliberately small, sits where the
 * missing module would have been, and leaves everything around it alone.
 *
 * `LoadFailedState` is the other half of the pair, for when the thing that
 * failed *is* the page.
 */
export function InlineRetry({ label, onRetry }: InlineRetryProps) {
  const [retrying, setRetrying] = useState(false);

  const handle = async () => {
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
      className="flex items-center justify-between gap-3 rounded-xl bg-slate-50 px-3 py-2.5 text-sm text-slate-500 ring-1 ring-slate-100 dark:bg-slate-800/60 dark:text-slate-400 dark:ring-slate-700"
    >
      <span>{label} could not load.</span>
      <button
        type="button"
        onClick={() => void handle()}
        disabled={retrying}
        className="flex min-h-9 items-center gap-1.5 rounded-lg px-2.5 font-semibold text-purple-600 transition-colors hover:text-purple-500 disabled:opacity-60 dark:text-purple-300"
      >
        <RotateCw
          size={15}
          className={retrying ? "animate-spin motion-reduce:animate-none" : ""}
          aria-hidden="true"
        />
        {retrying ? "Retrying" : "Retry"}
      </button>
    </div>
  );
}
