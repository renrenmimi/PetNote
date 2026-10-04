import { Bookmark, Heart, MessageCircle, Send } from "lucide-react";

type PostActionsProps = {
  liked: boolean;
  onLike: () => void;
  onComment: () => void;
  onShare: () => void;
  bookmarked: boolean;
  onBookmark: () => void;
  /** Set while a like or bookmark write is in flight, for the scale nudge. */
  likeAnimating?: boolean;
  bookmarkAnimating?: boolean;
};

/**
 * Like, comment, share, save — one row, one set of rules, every screen.
 *
 * These four controls existed twice, and differed in every way they could:
 *
 * - The feed's comment button was a lucide `MessageCircle`; the detail page's
 *   was the emoji 💬, which renders as a colour bitmap at its own baseline
 *   and weight next to three line icons, and cannot take a tint.
 * - `HeartIcon`, `BookmarkIcon` and `ShareIcon` were declared **twice**: once
 *   at module scope in PostDetail, and once *inside PostCard's render
 *   function*, which recreates the component type on every render and makes
 *   React remount the subtree rather than update it.
 * - Sizing came from `text-2xl` on the button in some places and an explicit
 *   `size={26}` in others, so the same icon was a different size depending on
 *   which file drew it.
 * - Only the comment button had a 44pt target. The heart and the share arrow
 *   were 24px of glyph with no padding.
 *
 * So: one component, module-scope icons, explicit sizes, and `.tap-target` on
 * every control. Colour is never the only signal — `aria-pressed` carries the
 * state, the label says what the tap will do, and fill plus weight change
 * with it so it survives greyscale.
 *
 * `onComment` differs by design and is the caller's decision: in a list it
 * opens the post, on the post it scrolls to the comments. Same control, same
 * name, same target; different destination because the destination genuinely
 * differs.
 */
export function PostActions({
  liked,
  onLike,
  onComment,
  onShare,
  bookmarked,
  onBookmark,
  likeAnimating = false,
  bookmarkAnimating = false,
}: PostActionsProps) {
  return (
    <div className="flex items-center justify-between">
      <div className="flex items-center gap-1">
        <button
          type="button"
          onClick={onLike}
          aria-pressed={liked}
          aria-label={liked ? "Unlike" : "Like"}
          className={`tap-target relative flex h-11 w-11 items-center justify-center transition-transform duration-200 ${
            likeAnimating ? "scale-110" : "scale-100"
          } ${liked ? "text-red-500" : "text-slate-600 hover:text-red-400 dark:text-slate-300"}`}
        >
          <Heart
            size={24}
            strokeWidth={liked ? 2.2 : 1.8}
            fill={liked ? "currentColor" : "none"}
            aria-hidden="true"
          />
        </button>

        <button
          type="button"
          onClick={onComment}
          aria-label="Comment"
          className="tap-target flex h-11 w-11 items-center justify-center text-slate-600 transition-colors duration-200 hover:text-purple-500 dark:text-slate-300"
        >
          <MessageCircle size={24} strokeWidth={1.8} aria-hidden="true" />
        </button>

        <button
          type="button"
          onClick={onShare}
          aria-label="Share"
          className="tap-target flex h-11 w-11 items-center justify-center text-slate-600 transition-colors duration-200 hover:text-purple-500 dark:text-slate-300"
        >
          {/* Rotated so it reads as "send", which is what the old hand-rolled
              path drew; lucide's Send points up-right by default. */}
          <Send
            size={22}
            strokeWidth={1.8}
            className="-translate-y-px"
            aria-hidden="true"
          />
        </button>
      </div>

      <button
        type="button"
        onClick={onBookmark}
        aria-pressed={bookmarked}
        aria-label={bookmarked ? "Remove bookmark" : "Save"}
        className={`tap-target flex h-11 w-11 items-center justify-center transition-transform duration-200 ${
          bookmarkAnimating ? "scale-110" : "scale-100"
        } ${
          bookmarked
            ? "text-purple-600 dark:text-purple-300"
            : "text-slate-600 hover:text-purple-500 dark:text-slate-300"
        }`}
      >
        <Bookmark
          size={24}
          strokeWidth={bookmarked ? 2.2 : 1.8}
          fill={bookmarked ? "currentColor" : "none"}
          aria-hidden="true"
        />
      </button>
    </div>
  );
}
