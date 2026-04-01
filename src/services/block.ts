import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  serverTimestamp,
  setDoc,
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
    const myFollowing = await getFollowingPets(myUid);
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

export async function getBlockedUsers(userId: string): Promise<string[]> {
  const blockedRef = collection(db, "users", userId, "blockedUsers");
  const snapshot = await getDocs(blockedRef);
  return snapshot.docs.map((docSnap) => docSnap.id);
}
