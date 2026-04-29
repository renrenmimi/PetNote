import {
  collection,
  documentId,
  getDocs,
  query,
  where,
} from "firebase/firestore";
import { db } from "../services/firebase";

const BATCH_SIZE = 10;

export async function batchCheckFollowingPets(
  userId: string,
  petIds: string[]
): Promise<Set<string>> {
  if (!userId || petIds.length === 0) return new Set();

  const followed = new Set<string>();
  const unique = Array.from(new Set(petIds.filter(Boolean)));
  const followingRef = collection(db, "users", userId, "followingPets");

  for (let i = 0; i < unique.length; i += BATCH_SIZE) {
    const chunk = unique.slice(i, i + BATCH_SIZE);
    if (chunk.length === 0) continue;
    try {
      const snapshot = await getDocs(
        query(followingRef, where(documentId(), "in", chunk))
      );
      snapshot.forEach((docSnap) => followed.add(docSnap.id));
    } catch {
      // ignore chunk failures so the feed can still render
    }
  }

  return followed;
}
