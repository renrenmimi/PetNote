import {
  collection,
  doc,
  getDoc,
  getDocs,
  increment,
  runTransaction,
  serverTimestamp,
  setDoc,
} from "firebase/firestore";
import { db } from "./firebase";
import { createNotification } from "./notifications";
import { getUserProfile } from "./users";

export async function followUser(
  myUid: string,
  targetUid: string
): Promise<void> {
  if (myUid === targetUid) return;
  const followingRef = doc(db, "users", myUid, "following", targetUid);
  const followerRef = doc(db, "users", targetUid, "followers", myUid);
  const myUserRef = doc(db, "users", myUid);
  const targetUserRef = doc(db, "users", targetUid);
  let didFollow = false;

  await runTransaction(db, async (transaction) => {
    const followSnap = await transaction.get(followingRef);
    if (followSnap.exists()) return;

    transaction.set(followingRef, { createdAt: serverTimestamp() });
    transaction.set(followerRef, { createdAt: serverTimestamp() });
    transaction.set(
      myUserRef,
      { followingCount: increment(1) },
      { merge: true }
    );
    transaction.set(
      targetUserRef,
      { followerCount: increment(1) },
      { merge: true }
    );
    didFollow = true;
  });

  if (didFollow) {
    const profile = await getUserProfile(myUid);
    await createNotification({
      userId: targetUid,
      type: "follow",
      fromUserId: myUid,
      fromUserName: profile?.displayName || "PetNote User",
      fromUserAvatar:
        profile?.avatarUrl || "https://i.pravatar.cc/150?img=12",
      message: "started following you",
    });
  }
}

export async function unfollowUser(
  myUid: string,
  targetUid: string
): Promise<void> {
  if (myUid === targetUid) return;
  const followingRef = doc(db, "users", myUid, "following", targetUid);
  const followerRef = doc(db, "users", targetUid, "followers", myUid);
  const myUserRef = doc(db, "users", myUid);
  const targetUserRef = doc(db, "users", targetUid);

  await runTransaction(db, async (transaction) => {
    const followSnap = await transaction.get(followingRef);
    if (!followSnap.exists()) return;

    transaction.delete(followingRef);
    transaction.delete(followerRef);
    transaction.set(
      myUserRef,
      { followingCount: increment(-1) },
      { merge: true }
    );
    transaction.set(
      targetUserRef,
      { followerCount: increment(-1) },
      { merge: true }
    );
  });
}

export async function checkIfFollowing(
  myUid: string,
  targetUid: string
): Promise<boolean> {
  const followingRef = doc(db, "users", myUid, "following", targetUid);
  const snapshot = await getDoc(followingRef);
  return snapshot.exists();
}

export async function getFollowers(uid: string): Promise<string[]> {
  const followersRef = collection(db, "users", uid, "followers");
  const snapshot = await getDocs(followersRef);
  return snapshot.docs.map((docSnap) => docSnap.id);
}

export async function getFollowing(uid: string): Promise<string[]> {
  const followingRef = collection(db, "users", uid, "following");
  const snapshot = await getDocs(followingRef);
  return snapshot.docs.map((docSnap) => docSnap.id);
}

export async function ensureUserDoc(
  uid: string,
  payload?: Record<string, unknown>
): Promise<void> {
  const userRef = doc(db, "users", uid);
  await setDoc(
    userRef,
    { followerCount: 0, followingCount: 0, ...payload },
    { merge: true }
  );
}
