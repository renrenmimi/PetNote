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
 * The rule is therefore: **media is deleted only when the attempt is known
 * never to have been handed to a publish call.** Everything else keeps it.
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
 * A missing `handedOff` is likewise not evidence of "never handed off" — it is
 * no evidence at all. Older drafts, and drafts whose marker write failed while
 * the publish went ahead, both look like that.
 *
 * This is deliberately the conservative end. The cost is orphaned assets,
 * which a future reference model or reaper can collect; the cost of the other
 * choice is a live post pointing at deleted images, which nothing can undo.
 */

export type PublishAttempt = {
  /** Stable id for the attempt, needed to ask the server what happened. */
  operationId: string | null;
  /**
   * True once media was handed to the publish call, in this attempt or an
   * earlier one. `undefined` means unrecorded, which is not the same as false.
   */
  handedOff: boolean | undefined;
  assets: UploadedAsset[];
};

export type ReclaimDecision =
  | { reclaim: true; assets: UploadedAsset[] }
  | {
      reclaim: false;
      reason: "no-assets" | "outcome-unknown";
    };

/**
 * Decides whether an attempt's uploaded media may be deleted.
 *
 * Synchronous and total: it asks the server nothing, because no server answer
 * available today can license a deletion (see the note above). Keeping it
 * free of I/O is also what makes every call site trivially auditable — there
 * is no path through here that deletes something without `handedOff === false`.
 */
export function decideAssetReclaim(attempt: PublishAttempt): ReclaimDecision {
  if (attempt.assets.length === 0) {
    return { reclaim: false, reason: "no-assets" };
  }
  // Explicitly recorded as never handed to a publish call: no post can exist
  // and none can appear, so this is the only case where deleting is safe.
  if (attempt.handedOff === false) {
    return { reclaim: true, assets: attempt.assets };
  }
  return { reclaim: false, reason: "outcome-unknown" };
}
