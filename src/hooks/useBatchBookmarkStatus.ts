import { collection, getDocs } from "firebase/firestore";
import { db } from "../services/firebase";

export async function batchCheckBookmarks(
  userId: string,
  postIds: string[]
): Promise<Set<string>> {
  if (!userId || postIds.length === 0) return new Set();

  const bookmarkedIds = new Set<string>();
  const postIdSet = new Set(postIds);

  const snapshot = await getDocs(collection(db, `users/${userId}/bookmarks`));
  snapshot.forEach((docSnap) => {
    if (postIdSet.has(docSnap.id)) {
      bookmarkedIds.add(docSnap.id);
    }
  });

  return bookmarkedIds;
}
