import { HttpsError } from "firebase-functions/v2/https";
import { db } from "./platform";

/**
 * Server-side enforcement for "block".
 *
 * Until now a block was only a document in the blocker's own private
 * subcollection (`users/{blocker}/blockedUsers/{blocked}`) that the client
 * read to filter its own feed. Nothing on the server consulted it, so a
 * blocked account could still comment on the blocker's posts and still join
 * the blocker's meetup — which for a product built around meeting strangers
 * and their animals in person is the case that actually matters.
 *
 * ## What a block means here, and what it deliberately does not
 *
 * A block stops *interaction between the two humans*, in both directions. It
 * is symmetric on purpose: if either person has blocked the other, neither
 * gets to initiate. Blocking somebody and then commenting under their post
 * would be a way to have the last word.
 *
 * A block does **not** hide published content. Posts, comments and meetup
 * rosters are world-readable by design — they are readable while logged out —
 * so no server check could make them private, and the UI must not claim
 * otherwise. `src/components/PostCard.tsx` says what is actually true now.
 *
 * ## Whose block counts, when a pet has several owners
 *
 * PetNote's whole point is that one pet can have several equal human owners,
 * which raises a real question: if one co-owner has blocked somebody, is that
 * person barred from the pet's posts?
 *
 * No — the pair checked is the two humans directly involved: the commenter
 * and the post's `authorId`, the joiner and the meetup's `organizerId`. That
 * is what the person clicking "Block @someone" asked for, and it is the only
 * reading that does not let one co-owner silently impose their personal
 * blocklist on another co-owner's conversations. Barring somebody from a
 * whole pet's content is a different, stronger control (an exclusion list on
 * the pet, or on a meetup) and it should be built as such rather than
 * smuggled in through one person's private block list.
 */

async function hasBlock(blockerUid: string, blockedUid: string): Promise<boolean> {
  const snap = await db.doc(`users/${blockerUid}/blockedUsers/${blockedUid}`).get();
  return snap.exists;
}

/**
 * Throws `permission-denied` when `callerUid` and `targetUid` have a block
 * between them in either direction.
 *
 * The message is intentionally the same regardless of who blocked whom: a
 * caller must not be able to use the error to discover that a specific person
 * has blocked them, and the blocker's list is private data.
 */
export async function assertNoBlockBetween(
  callerUid: string,
  targetUid: string,
  action: string
): Promise<void> {
  if (!callerUid || !targetUid || callerUid === targetUid) return;
  const [targetBlockedCaller, callerBlockedTarget] = await Promise.all([
    hasBlock(targetUid, callerUid),
    hasBlock(callerUid, targetUid),
  ]);
  if (targetBlockedCaller || callerBlockedTarget) {
    throw new HttpsError(
      "permission-denied",
      `${action} is unavailable between you and this account.`
    );
  }
}
