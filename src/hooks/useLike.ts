import { useCallback, useEffect, useRef, useState } from "react";
import {
  checkIfLiked,
  likePost,
  unlikePost,
  type LikeMutationResult,
} from "../services/posts";

export type LikeFailureReason = "post-missing" | "request-failed";

type UseLikeOptions = {
  /**
   * Fired when the shown state changes because of *this user's own tap* —
   * including the rollback after a failure. Never fired when the hook adopts
   * a fresher value from props, so a parent that mirrors this back in as
   * `initialLiked` cannot start a loop.
   */
  onLikedChange?: (liked: boolean) => void;
  onFailure?: (reason: LikeFailureReason) => void;
};

type UseLikeResult = {
  isLiked: boolean;
  likeCount: number;
  toggleLike: () => void;
  /** True while a request for this post is in flight. */
  loading: boolean;
};

/**
 * Like state for one post, updated optimistically.
 *
 * The heart and the local count move on the tap; the request follows. This
 * used to be the other way round — `await likePost(...)` and only then
 * `setIsLiked` — so on a phone the heart did not move until the round trip
 * finished, and `catch {}` in PostCard meant a rejected write looked
 * identical to a successful one.
 *
 * Two things make optimism safe here rather than just fast:
 *
 * 1. **Intent, not a queue of requests.** Every tap records the desired end
 *    state. One request runs at a time; when it settles, if the desire has
 *    moved on, another runs. Tapping like/unlike/like quickly costs one
 *    request, not three, and a slow response for an older intent can never
 *    land on top of a newer one.
 * 2. **The count offset is separate from the count.** The server's
 *    `likeCount` is maintained by the onLikeCreated / onLikeDeleted triggers,
 *    not by this client, so after a successful write the aggregate lags. We
 *    hold a ±1 offset on top of whatever count the parent passes and drop it
 *    only once the parent's own number has moved to match — otherwise the
 *    same like is counted twice, or the number visibly flicks back down.
 *
 * Optimism stops at the network. A rejected write — including a rules denial
 * — rolls the UI back and reports the failure; it is never presented as a
 * queued success.
 */
export function useLike(
  postId: string,
  userId: string | null,
  initialCount = 0,
  initialLiked?: boolean,
  options: UseLikeOptions = {}
): UseLikeResult {
  const { onLikedChange, onFailure } = options;

  // What we show, and what we believe the server holds. Both render: the
  // count is derived from the gap between them, so the +1 appears on the tap
  // rather than when the write comes back.
  const [liked, setLiked] = useState(initialLiked ?? false);
  const [confirmed, setConfirmed] = useState(initialLiked ?? false);
  // The parent's count, and the contribution of a *confirmed* write that the
  // aggregate has not caught up with yet.
  const [baseCount, setBaseCount] = useState(initialCount);
  const [countAdjust, setCountAdjust] = useState(0);
  const [loading, setLoading] = useState(false);

  const desiredRef = useRef(initialLiked ?? false);
  // What we believe the server holds. A ref, not state: nothing renders
  // from it directly, and the drain loop has to read it synchronously.
  const confirmedRef = useRef(initialLiked ?? false);
  const inFlightRef = useRef(false);
  const mountedRef = useRef(true);
  // The parent count at the moment the offset was taken, so we can tell
  // "the trigger landed" from "the parent re-sent the same stale number".
  const baseAtAdjustRef = useRef(initialCount);
  const baseCountRef = useRef(initialCount);
  // Latest callbacks, so a parent passing inline closures does not need to
  // memoise them to keep toggleLike stable.
  const onLikedChangeRef = useRef(onLikedChange);
  const onFailureRef = useRef(onFailure);

  useEffect(() => {
    onLikedChangeRef.current = onLikedChange;
    onFailureRef.current = onFailure;
  }, [onLikedChange, onFailure]);

  useEffect(() => {
    // Re-arm on each mount; StrictMode's setup→cleanup→setup would otherwise
    // leave this false after the first dev-only cleanup.
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  // Switching accounts, or reusing this card for a different post,
  // invalidates every belief about it — including an offset we were holding.
  useEffect(() => {
    const fresh = initialLiked ?? false;
    desiredRef.current = fresh;
    confirmedRef.current = fresh;
    setLiked(fresh);
    setConfirmed(fresh);
    setCountAdjust(0);
    baseAtAdjustRef.current = baseCountRef.current;
    // initialLiked is deliberately not a dependency: this is about identity
    // changing, and the effect below handles a new value for the same post.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [postId, userId]);

  // The parent's count moved. Drop our offset once it accounts for us.
  useEffect(() => {
    setBaseCount(initialCount);
    baseCountRef.current = initialCount;
    setCountAdjust((prev) => {
      if (prev === 0) return 0;
      const expected = baseAtAdjustRef.current + prev;
      if (prev > 0 && initialCount >= expected) return 0;
      if (prev < 0 && initialCount <= expected) return 0;
      return prev;
    });
  }, [initialCount]);

  // A batch like-status query that started before this user's tap must not
  // overwrite it, so props are only adopted while nothing is unconfirmed.
  useEffect(() => {
    if (initialLiked === undefined) return;
    if (inFlightRef.current || countAdjust !== 0) return;
    desiredRef.current = initialLiked;
    confirmedRef.current = initialLiked;
    setLiked(initialLiked);
    setConfirmed(initialLiked);
  }, [initialLiked, countAdjust]);

  // Single-post fallback for callers that have no batched answer.
  useEffect(() => {
    let ignore = false;
    if (!userId) {
      desiredRef.current = false;
      confirmedRef.current = false;
      setLiked(false);
      setConfirmed(false);
      setCountAdjust(0);
      return;
    }
    if (initialLiked !== undefined) return;

    const load = async () => {
      try {
        const serverLiked = await checkIfLiked(postId, userId);
        if (ignore || inFlightRef.current || countAdjust !== 0) return;
        desiredRef.current = serverLiked;
        confirmedRef.current = serverLiked;
        setLiked(serverLiked);
        setConfirmed(serverLiked);
      } catch {
        // Leave whatever we already believe; a failed status read is not
        // evidence that the post is unliked.
      }
    };

    void load();
    return () => {
      ignore = true;
    };
    // countAdjust is read as a guard, not tracked: re-running on every offset
    // change would re-query on each tap.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [postId, userId, initialLiked]);

  const rollBack = useCallback((reason: LikeFailureReason) => {
    const truth = confirmedRef.current;
    desiredRef.current = truth;
    setLiked(truth);
    onLikedChangeRef.current?.(truth);
    onFailureRef.current?.(reason);
  }, []);

  const drain = useCallback(async () => {
    if (!userId || inFlightRef.current) return;
    inFlightRef.current = true;
    setLoading(true);
    try {
      while (mountedRef.current && desiredRef.current !== confirmedRef.current) {
        const want = desiredRef.current;
        let result: LikeMutationResult;
        try {
          result = want
            ? await likePost(postId, userId)
            : await unlikePost(postId, userId);
        } catch {
          if (mountedRef.current) rollBack("request-failed");
          return;
        }
        if (!mountedRef.current) return;

        if (result === "post-not-found") {
          rollBack("post-missing");
          return;
        }

        const wasConfirmed = confirmedRef.current;
        confirmedRef.current = want;
        setConfirmed(want);

        // Only a write that actually changed something will move the
        // aggregate. "unchanged" means the server already agreed, so its
        // count already includes this like and an offset would double it.
        if (result === "changed" && want !== wasConfirmed) {
          setCountAdjust((prev) => {
            baseAtAdjustRef.current = baseCountRef.current;
            return prev + (want ? 1 : -1);
          });
        }
      }
    } finally {
      inFlightRef.current = false;
      if (mountedRef.current) setLoading(false);
    }
  }, [postId, rollBack, userId]);

  const toggleLike = useCallback(() => {
    if (!userId) return;
    const next = !desiredRef.current;
    desiredRef.current = next;
    setLiked(next);
    onLikedChangeRef.current?.(next);
    // A request is already running; it will pick the new desire up when it
    // settles rather than racing a second one against it.
    if (inFlightRef.current) return;
    void drain();
  }, [drain, userId]);

  // Three parts, and each one has to be separate from the others:
  //   baseCount    what the parent last told us the server says
  //   countAdjust  a confirmed write the aggregate trigger has not applied yet
  //   pending      this tap, not yet confirmed — this is what makes the
  //                number move at the same moment as the heart
  const pending = liked === confirmed ? 0 : liked ? 1 : -1;

  return {
    isLiked: liked,
    likeCount: Math.max(0, baseCount + countAdjust + pending),
    toggleLike,
    loading,
  };
}
