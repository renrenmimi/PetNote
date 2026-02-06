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
import { unfollowUser } from "./follow";

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
  await Promise.all([
    unfollowUser(myUid, targetUid),
    unfollowUser(targetUid, myUid),
  ]);
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
