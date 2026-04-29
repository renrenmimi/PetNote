import {
  collection,
  documentId,
  getDocs,
  query,
  where,
} from "firebase/firestore";
import { db } from "../services/firebase";

const BATCH_SIZE = 10;

export async function batchCheckBookmarks(
  userId: string,
  postIds: string[]
): Promise<Set<string>> {
  if (!userId || postIds.length === 0) return new Set();

  const bookmarkedIds = new Set<string>();
  const unique = Array.from(new Set(postIds.filter(Boolean)));
  const bookmarksRef = collection(db, "users", userId, "bookmarks");

  for (let i = 0; i < unique.length; i += BATCH_SIZE) {
    const chunk = unique.slice(i, i + BATCH_SIZE);
    if (chunk.length === 0) continue;
    try {
      const snapshot = await getDocs(
        query(bookmarksRef, where(documentId(), "in", chunk))
      );
      snapshot.forEach((docSnap) => bookmarkedIds.add(docSnap.id));
    } catch {
      // ignore chunk failures so the feed can still render
    }
  }

  return bookmarkedIds;
}
