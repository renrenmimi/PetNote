import type { UploadedAsset } from "../services/cloudinary";

/**
 * Whether a failed publish attempt's uploaded media may be deleted.
 *
 * This is a policy question, not a UI one, which is why it lives here: the
 * composer has several exits that used to reclaim assets, and each one made the
 * decision on its own with whatever it happened to know.
 *
 * The failure that produced this module: publishing commits server-side but the
 * response is lost, so the client shows "failed" and keeps the assets for a
 * retry. Then the person changes a photo or filter, or discards the draft, or
 * comes back to an expired draft. Each of those paths deleted the assets — and
 * a post already existed referencing them. The result is a real post pointing
 * at images that no longer exist, which nothing can undo. `handedOff` was a
 * local variable inside one submit call, so none of those exits could know the
 * outcome was uncertain.
 *
 * The rule is therefore: **the composer does not delete uploaded media at
 * all.** Every exit keeps it.
 *
 * In particular, a server answer of `published: false` is *not* grounds to
 * delete. That answer is document existence at one instant, and nothing
 * cancelled the original request — a publish paused just before its `.create()`
 * reports "not published" and then commits, referencing the very assets the
 * answer would have released. Reproduced in the emulator against the real
 * publish handler. Reclaiming on a false answer encoded the premise that "no
 * post right now" means "no post ever", which is the one thing existence
 * cannot establish. Waiting longer or asking twice is not a proof either;
 * releasing an asset would need a server-side protocol that is mutually
 * exclusive with publishing, and that does not exist yet.
 *
 * The last thing still trusted was the draft's own record of whether the media
 * had been handed to a publish call. That record can be stale in the one
 * direction that matters — see `handedOff` below — so it went too.
 *
 * **This is a suspension, not a solution.** The cost is orphaned Cloudinary
 * assets: photos uploaded for a post that was never published are now left on
 * the CDN. That is a bounded, collectable cost. The cost of the alternative is
 * a live post pointing at deleted images, which nothing can undo. Reclaiming
 * them properly needs a media reference model, which is deliberately not being
 * built here.
 */

export type PublishAttempt = {
  /** Stable id for the attempt. Kept for messaging, not for this decision. */
  operationId: string | null;
  /**
   * What the draft recorded about handoff, if anything.
   *
   * **Deliberately ignored by the decision below**, and no longer written by
   * the composer. It is still accepted because a draft persisted by an earlier
   * build can carry it, and the safe thing to do with that value is nothing.
   *
   * It was the last thing trusted to authorise a deletion, and it could be
   * *stale*: assets go into the draft with an explicit `false`, the update to
   * `true` before publishing fails because sessionStorage is full or blocked,
   * publishing continues and commits, and after a reload the draft still says
   * false. Three-state handling fixed "the field is missing"; nothing in the
   * browser can fix "the field is present and out of date". An in-memory true
   * does not correct a false already written to disk.
   */
  handedOff?: boolean;
  assets: UploadedAsset[];
};

/**
 * Why reclaim was withheld.
 *
 * There is no `reclaim: true` variant, and that is the point: automatic CDN
 * reclaim from the composer is **suspended**, and the type makes a deletion
 * along this path unrepresentable rather than leaving it to a reviewer to
 * notice one being reintroduced.
 */
export type ReclaimDecision = {
  reclaim: false;
  reason: "no-assets" | "automatic-reclaim-disabled";
};

/**
 * Whether the composer may delete an attempt's uploaded media. It may not.
 *
 * Kept as a function, and as the single place the composer consults, because
 * the answer is a decision with a rationale rather than an absence of code —
 * and because re-opening it has to come past the tests next to this file.
 *
 * Re-enabling needs more than a better flag. It needs the composer to be
 * unable to publish without having durably recorded that it is publishing, or
 * a server-side release protocol that is mutually exclusive with publishing.
 * Another boolean, a retry around the storage write, or asking whether the
 * post exists yet are all things that have already been tried here and are all
 * insufficient.
 */
export function decideAssetReclaim(attempt: PublishAttempt): ReclaimDecision {
  if (attempt.assets.length === 0) {
    return { reclaim: false, reason: "no-assets" };
  }
  return { reclaim: false, reason: "automatic-reclaim-disabled" };
}
