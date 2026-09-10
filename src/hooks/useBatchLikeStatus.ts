import {
  collectionGroup,
  doc,
  getCountFromServer,
  getDoc,
  getDocs,
  orderBy,
  query,
  where,
} from "firebase/firestore";
import { db } from "../services/firebase";

const CHUNK_SIZE = 30;

/**
 * Per-session answer to "does this user still have like documents from before
 * the `postId` field existed?"
 *
 * `false` means every one of their likes is reachable by the batched
 * collection-group query below, so the per-post fallback probe can be skipped
 * entirely. `undefined` means not determined yet.
 */
const hasLegacyLikes = new Map<string, boolean>();

/**
 * Decides once whether the fallback probes are needed for this user.
 *
 * Two aggregate counts, both servable by indexes that are already deployed:
 * the total number of this user's likes, and the number that carry a `postId`.
 * `orderBy` imposes field existence in Firestore, so ordering by `postId` is
 * what excludes the legacy documents — and if the two counts agree, there are
 * none.
 *
 * Aggregate queries are billed per batch of index entries scanned rather than
 * per document, so this is cheap even for someone with thousands of likes, and
 * it runs once per user per session rather than once per feed page.
 *
 * Fails closed: any error means "assume legacy likes exist" and keep probing.
 * Being slow is recoverable; showing an unfilled heart on a post the person
 * has already liked is not, because tapping it then tries to like it twice.
 */
async function determineLegacyLikes(userId: string): Promise<boolean> {
  const cached = hasLegacyLikes.get(userId);
  if (cached !== undefined) return cached;
  try {
    const base = query(
      collectionGroup(db, "likes"),
      where("userId", "==", userId)
    );
    const [total, withPostId] = await Promise.all([
      getCountFromServer(base),
      getCountFromServer(query(base, orderBy("postId"))),
    ]);
    const result = total.data().count !== withPostId.data().count;
    hasLegacyLikes.set(userId, result);
    return result;
  } catch {
    hasLegacyLikes.set(userId, true);
    return true;
  }
}

/**
 * Which of `postIds` this user has liked.
 *
 * One batched collection-group query per chunk of 30, using the `postId` field
 * that `likePost` writes.
 *
 * The per-post `getDoc` fallback exists for like documents written before that
 * field landed: they do not match the batched query, so without it an old like
 * would render as unliked. But it fired for every postId the batch did *not*
 * return — which is every post the person has not liked, i.e. most of them. A
 * feed of ten unliked posts cost one query plus ten document reads.
 *
 * It is now gated on determineLegacyLikes, so a user whose likes are all
 * migrated pays one aggregate pair per session and no probes at all. The
 * fallback is kept rather than deleted because the backfill
 * (functions/scripts/backfill-like-postid.js) has not been proven complete in
 * production, and removing a compatibility path before that is how the bug
 * comes back.
 */
export async function batchCheckLikes(
  userId: string,
  postIds: string[]
): Promise<Set<string>> {
  if (!userId || postIds.length === 0) return new Set();

  const likedPostIds = new Set<string>();
  const unique = Array.from(new Set(postIds.filter(Boolean)));
  const needsProbes = await determineLegacyLikes(userId);

  for (let i = 0; i < unique.length; i += CHUNK_SIZE) {
    const chunk = unique.slice(i, i + CHUNK_SIZE);
    if (chunk.length === 0) continue;
    let batchFailed = false;
    try {
      const snapshot = await getDocs(
        query(
          collectionGroup(db, "likes"),
          where("userId", "==", userId),
          where("postId", "in", chunk)
        )
      );
      snapshot.docs.forEach((docSnap) => {
        const data = docSnap.data() as { postId?: string };
        if (data.postId) likedPostIds.add(data.postId);
      });
    } catch {
      // Index missing or transient failure. The probes below are the only way
      // to get a truthful answer, so they run regardless of the legacy check.
      batchFailed = true;
    }

    if (!needsProbes && !batchFailed) continue;

    const missing = chunk.filter((postId) => !likedPostIds.has(postId));
    if (missing.length === 0) continue;
    await Promise.all(
      missing.map(async (postId) => {
        try {
          const likeDoc = await getDoc(
            doc(db, "posts", postId, "likes", userId)
          );
          if (likeDoc.exists()) likedPostIds.add(postId);
        } catch {
          // ignore individual failures
        }
      })
    );
  }

  return likedPostIds;
}

/** Test/sign-out hook: forgets the per-user legacy determination. */
export function clearLegacyLikeCache(userId?: string): void {
  if (userId) hasLegacyLikes.delete(userId);
  else hasLegacyLikes.clear();
}
