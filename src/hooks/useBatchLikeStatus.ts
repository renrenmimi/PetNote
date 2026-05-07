import {
  collectionGroup,
  doc,
  getDoc,
  getDocs,
  query,
  where,
} from "firebase/firestore";
import { db } from "../services/firebase";

const CHUNK_SIZE = 30;

// Single batched query per chunk via the collectionGroup index instead
// of one getDoc per post. Each like doc carries a `postId` field (added
// when likePost runs) so we can filter the collection group on
// (userId, postId in chunk) and resolve up to 30 posts in one read.
//
// Legacy like docs created before the postId field landed won't match
// the collectionGroup query, so we fall back to the per-post getDoc
// probe for any postId that didn't appear in the batch result. That
// fallback shrinks naturally as users re-toggle their old likes.
export async function batchCheckLikes(
  userId: string,
  postIds: string[]
): Promise<Set<string>> {
  if (!userId || postIds.length === 0) return new Set();

  const likedPostIds = new Set<string>();
  const unique = Array.from(new Set(postIds.filter(Boolean)));

  for (let i = 0; i < unique.length; i += CHUNK_SIZE) {
    const chunk = unique.slice(i, i + CHUNK_SIZE);
    if (chunk.length === 0) continue;
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
      // Index missing or transient failure — fall through to the per-post
      // probe so the UI still reflects the truth.
    }

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
