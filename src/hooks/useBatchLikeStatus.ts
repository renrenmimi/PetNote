import { doc, getDoc } from "firebase/firestore";
import { db } from "../services/firebase";

export async function batchCheckLikes(
  userId: string,
  postIds: string[]
): Promise<Set<string>> {
  if (!userId || postIds.length === 0) return new Set();

  const likedPostIds = new Set<string>();
  const unique = Array.from(new Set(postIds.filter(Boolean)));
  const batches: string[][] = [];
  for (let i = 0; i < unique.length; i += 30) {
    batches.push(unique.slice(i, i + 30));
  }

  for (const batch of batches) {
    await Promise.all(
      batch.map(async (postId) => {
        try {
          const likeDoc = await getDoc(doc(db, "posts", postId, "likes", userId));
          if (likeDoc.exists()) likedPostIds.add(postId);
        } catch {
          // ignore individual failures
        }
      })
    );
  }

  return likedPostIds;
}
