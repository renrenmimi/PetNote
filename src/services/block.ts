import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  serverTimestamp,
  setDoc,
  startAfter,
  type QueryConstraint,
  type QueryDocumentSnapshot,
} from "firebase/firestore";
import { db } from "./firebase";
import { getFollowingPets, unfollowPet } from "./follow";

export async function blockUser(
  myUid: string,
  targetUid: string
): Promise<void> {
  if (!myUid || !targetUid || myUid === targetUid) return;
  const blockRef = doc(db, "users", myUid, "blockedUsers", targetUid);
  await setDoc(
    blockRef,
    {
      blockedAt: serverTimestamp(),
    },
    { merge: true }
  );

  // Unfollow any pets owned by the blocked user
  try {
    const { followingPets: myFollowing } = await getFollowingPets(myUid);
    for (const follow of myFollowing) {
      const petRef = doc(db, "pets", follow.petId);
      const petSnap = await getDoc(petRef);
      if (petSnap.exists()) {
        const petData = petSnap.data() as { ownerId?: string; primaryOwnerId?: string };
        if (petData.ownerId === targetUid || petData.primaryOwnerId === targetUid) {
          await unfollowPet(myUid, follow.petId);
        }
      }
    }
  } catch (error) {
    console.error("Failed to unfollow blocked user's pets:", error);
  }
}

export async function unblockUser(
  myUid: string,
  targetUid: string
): Promise<void> {
  if (!myUid || !targetUid) return;
  const blockRef = doc(db, "users", myUid, "blockedUsers", targetUid);
  await deleteDoc(blockRef);
}

export async function checkIfBlocked(
  myUid: string,
  targetUid: string
): Promise<boolean> {
  const blockRef = doc(db, "users", myUid, "blockedUsers", targetUid);
  const snapshot = await getDoc(blockRef);
  return snapshot.exists();
}

// Paginated blocked-user lookup. The realtime hook (useBlockedUsers)
// still subscribes to the full subcollection for filter-set semantics,
// but the BlockedUsers screen now reads through this paged version so a
// moderator-flagged user with thousands of blocks doesn't pull every
// entry on mount.
export async function getBlockedUsers(
  userId: string,
  options?: { limitCount?: number; lastDoc?: QueryDocumentSnapshot }
): Promise<{
  ids: string[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  if (!userId) return { ids: [], lastDoc: null, hasMore: false };
  const limitCount = options?.limitCount ?? 100;
  const blockedRef = collection(db, "users", userId, "blockedUsers");
  const constraints: QueryConstraint[] = [
    orderBy("blockedAt", "desc"),
    limit(limitCount),
  ];
  if (options?.lastDoc) {
    constraints.push(startAfter(options.lastDoc));
  }
  const snapshot = await getDocs(query(blockedRef, ...constraints));
  const ids = snapshot.docs.map((docSnap) => docSnap.id);
  const nextLast =
    (snapshot.docs[snapshot.docs.length - 1] as
      | QueryDocumentSnapshot
      | undefined) ?? null;
  return {
    ids,
    lastDoc: nextLast,
    hasMore: snapshot.docs.length === limitCount,
  };
}
