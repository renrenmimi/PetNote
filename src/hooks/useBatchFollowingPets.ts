import { doc, getDoc } from "firebase/firestore";
import { db } from "../services/firebase";

export async function batchCheckFollowingPets(
  userId: string,
  petIds: string[]
): Promise<Set<string>> {
  if (!userId || petIds.length === 0) return new Set();

  const followed = new Set<string>();
  const unique = Array.from(new Set(petIds.filter(Boolean)));
  const chunkSize = 30;

  for (let i = 0; i < unique.length; i += chunkSize) {
    const chunk = unique.slice(i, i + chunkSize);
    await Promise.all(
      chunk.map(async (petId) => {
        try {
          const snap = await getDoc(
            doc(db, "users", userId, "followingPets", petId)
          );
          if (snap.exists()) followed.add(petId);
        } catch {
          // ignore individual failures
        }
      })
    );
  }

  return followed;
}
