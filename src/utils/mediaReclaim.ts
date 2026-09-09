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
 * The rule is therefore: an attempt whose outcome is not *known* to have failed
 * keeps its media. Deleting is only allowed when we are sure nothing
 * references it — either because it never reached the backend, or because the
 * server says the operation did not publish.
 */

export type PublishAttempt = {
  /** Stable id for the attempt, needed to ask the server what happened. */
  operationId: string | null;
  /** True once media was handed to the publish call, in this attempt or an earlier one. */
  handedOff: boolean;
  assets: UploadedAsset[];
};

export type ReclaimDecision =
  | { reclaim: true; assets: UploadedAsset[] }
  | {
      reclaim: false;
      reason: "no-assets" | "never-handed-off" | "outcome-unknown" | "published";
    };

/** Asks the server whether an operation id produced a post. */
export type PublishStatusLookup = (
  operationId: string
) => Promise<{ published: boolean }>;

export async function decideAssetReclaim(
  attempt: PublishAttempt,
  lookupPublishStatus: PublishStatusLookup
): Promise<ReclaimDecision> {
  if (attempt.assets.length === 0) {
    return { reclaim: false, reason: "no-assets" };
  }
  // Never reached a publish call, so no post can reference it.
  if (!attempt.handedOff) {
    return { reclaim: true, assets: attempt.assets };
  }
  // Handed off, so a post may exist. Without an operation id there is no way
  // to find out, and "I don't know" has to mean "keep".
  if (!attempt.operationId) {
    return { reclaim: false, reason: "outcome-unknown" };
  }
  try {
    const status = await lookupPublishStatus(attempt.operationId);
    if (status.published) {
      return { reclaim: false, reason: "published" };
    }
    return { reclaim: true, assets: attempt.assets };
  } catch {
    // Offline, rate-limited, anything. Fails closed: an orphan asset is
    // recoverable later, a post with dead image URLs is not.
    return { reclaim: false, reason: "outcome-unknown" };
  }
}
