import { ArrowDown, Loader2 } from "lucide-react";

export type PullState = "idle" | "pulling" | "armed" | "refreshing";

type PullToRefreshIndicatorProps = {
  state: PullState;
  /** How far the finger has travelled, already damped, in CSS px. */
  distance: number;
  /** Distance at which letting go triggers a refresh. */
  threshold: number;
  pullLabel: string;
  releaseLabel: string;
  refreshingLabel: string;
};

/**
 * The pull-to-refresh affordance.
 *
 * Renders nothing at all when idle. The previous version kept a permanent
 * "Pull to refresh" line above the feed, which is both noise and a lie —
 * it said the same thing whether or not the gesture was available.
 *
 * Progress is the real gesture distance, not a timer: the arrow rotates
 * towards 180° as the finger approaches the threshold and the ring fills by
 * the same fraction, so "let go now" is something you can see rather than
 * guess. Nothing here reports a percentage of the request itself, because
 * the request does not expose progress.
 */
export function PullToRefreshIndicator({
  state,
  distance,
  threshold,
  pullLabel,
  releaseLabel,
  refreshingLabel,
}: PullToRefreshIndicatorProps) {
  if (state === "idle") return null;

  const progress = Math.min(1, distance / threshold);
  const label =
    state === "refreshing"
      ? refreshingLabel
      : state === "armed"
        ? releaseLabel
        : pullLabel;

  return (
    <div
      // polite, not assertive: a refresh is not an interruption. The label is
      // the only thing announced — the arrow is decorative.
      role="status"
      aria-live="polite"
      className="flex flex-col items-center justify-end gap-1 overflow-hidden"
      style={{
        // Grows with the gesture so the feed is pushed down rather than
        // having the indicator sit on top of the first card.
        height: state === "refreshing" ? 44 : Math.min(distance, 72),
      }}
    >
      {state === "refreshing" ? (
        <Loader2
          className="h-5 w-5 animate-spin text-purple-500 motion-reduce:animate-none"
          aria-hidden="true"
        />
      ) : (
        <ArrowDown
          className={`h-5 w-5 transition-colors duration-150 ${
            state === "armed" ? "text-purple-500" : "text-slate-400"
          }`}
          style={{
            // No transition on the rotation: it tracks the finger, and easing
            // it would make the arrow lag behind the gesture.
            transform: `rotate(${progress * 180}deg)`,
            opacity: 0.4 + progress * 0.6,
          }}
          aria-hidden="true"
        />
      )}
      <span className="text-xs text-slate-400 dark:text-slate-500">{label}</span>
    </div>
  );
}
