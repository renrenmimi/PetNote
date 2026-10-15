import { useNavigate } from "react-router-dom";

import Avatar from "../Avatar";

type PostIdentityProps = {
  petId?: string | null;
  petName?: string | null;
  petAvatarUrl?: string | null;
  authorId: string;
  authorName: string;
  authorAvatarUrl?: string | null;
  timeLabel: string;
  isBirthday?: boolean;
  /** Larger avatar on a detail page, where the post is the whole screen. */
  size?: "list" | "detail";
  /** Follow button, options menu — whatever the page puts on the right. */
  trailing?: React.ReactNode;
};

/**
 * Who a post belongs to, decided once for every screen that shows a post.
 *
 * The same post used to introduce itself differently depending on where you
 * met it. In the feed the pet led — pet avatar, pet name, then "owner · time"
 * as a byline. Open that exact post and the owner led instead, with the pet
 * demoted to a purple "· with Mochi" beside their name. Two answers to "whose
 * post is this", one product.
 *
 * The rule here, applied everywhere:
 *
 * - **A post with a pet is the pet's post.** Pet avatar, pet name, and the
 *   owner in the byline. That matches what PetNote is: the pet is the subject
 *   and the account is who publishes for it.
 * - **Attribution is never dropped.** The owner stays on screen, tappable,
 *   one line down. Demoting them is not the same as hiding them, and "posted
 *   by" is a real relationship that co-owners depend on.
 * - **No pet means no pet.** A post with no `petId`, or whose pet has since
 *   been deleted so `petName` is gone, leads with the author and shows the
 *   time alone. Nothing invents a pet to keep the layout symmetrical.
 *
 * Two lines, not three: name, then owner · time. The old detail header put
 * name, pet and time at three sizes across three rows, so the post spent more
 * height introducing itself than the photo needed to arrive.
 */
export function PostIdentity({
  petId,
  petName,
  petAvatarUrl,
  authorId,
  authorName,
  authorAvatarUrl,
  timeLabel,
  isBirthday = false,
  size = "list",
  trailing,
}: PostIdentityProps) {
  const navigate = useNavigate();

  const hasPet = !!(petId && petName);
  const primaryName = hasPet ? petName! : authorName;
  const primaryAvatar = hasPet ? petAvatarUrl || "" : authorAvatarUrl || "";
  const primaryId = hasPet ? petId! : authorId;
  const primaryHref = hasPet ? `/pet/${petId}` : `/profile/${authorId}`;
  const avatarPx = size === "detail" ? 44 : 40;

  return (
    <header className="flex items-center gap-3">
      {/*
        The avatar goes where the name goes, so to assistive technology it is
        the same control twice — a screen reader read "Mochi, button" twice,
        both leading to the same page. Hidden from the accessibility tree and
        out of the tab order, but still a large tap area on a phone, which is
        the reason to keep it at all. The name button next to it is the
        accessible equivalent.
      */}
      <button
        type="button"
        tabIndex={-1}
        aria-hidden="true"
        onClick={() => navigate(primaryHref)}
        className="shrink-0 transition-transform duration-200 hover:scale-105"
      >
        <Avatar
          src={primaryAvatar}
          alt=""
          userId={primaryId}
          size={avatarPx}
        />
      </button>

      {/*
        min-w-0 on both, because a flex item's default min-width is its
        content: one long unbroken name — or a CJK string, which has no spaces
        to wrap at — pushed the trailing control off the card instead of being
        truncated.
      */}
      <div className="flex min-w-0 flex-1 items-center justify-between gap-2">
        <div className="min-w-0">
          <button
            type="button"
            onClick={() => navigate(primaryHref)}
            className={`block max-w-full truncate font-semibold text-slate-900 transition-colors duration-200 hover:text-purple-600 dark:text-white ${
              size === "detail" ? "text-base" : "text-sm"
            }`}
          >
            {primaryName}
          </button>

          <div className="flex min-w-0 items-center gap-1.5 text-xs text-slate-500 dark:text-slate-400">
            {hasPet ? (
              <>
                <button
                  type="button"
                  onClick={() => navigate(`/profile/${authorId}`)}
                  className="max-w-[9rem] truncate transition-colors duration-200 hover:text-purple-600"
                >
                  {authorName}
                </button>
                <span aria-hidden="true">·</span>
              </>
            ) : null}
            <span className="shrink-0">{timeLabel}</span>
            {isBirthday ? (
              <span className="shrink-0 rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-semibold text-amber-700 dark:bg-amber-500/20 dark:text-amber-200">
                Birthday
              </span>
            ) : null}
          </div>
        </div>

        {trailing ? (
          <div className="flex shrink-0 items-center gap-2">{trailing}</div>
        ) : null}
      </div>
    </header>
  );
}
