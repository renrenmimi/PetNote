import { updateProfile } from "firebase/auth";
import {
  collection,
  doc,
  getDoc,
  getDocs,
  query,
  setDoc,
  where,
  writeBatch,
  serverTimestamp,
} from "firebase/firestore";
import { auth, db } from "./firebase";

export type UserProfile = {
  id: string;
  displayName?: string;
  email?: string;
  avatarUrl?: string;
  bio?: string;
  createdAt?: unknown;
  followerCount?: number;
  followingCount?: number;
};

export async function getUserProfile(
  userId: string
): Promise<UserProfile | null> {
  const userRef = doc(db, "users", userId);
  const snapshot = await getDoc(userRef);
  if (!snapshot.exists()) {
    return null;
  }
  return {
    id: snapshot.id,
    ...(snapshot.data() as Omit<UserProfile, "id">),
  };
}

export async function updateUserProfile(
  userId: string,
  data: Partial<UserProfile>
): Promise<void> {
  const userRef = doc(db, "users", userId);
  await setDoc(userRef, data, { merge: true });

  if (auth.currentUser && auth.currentUser.uid === userId) {
    await updateProfile(auth.currentUser, {
      displayName: data.displayName ?? auth.currentUser.displayName ?? undefined,
      photoURL: data.avatarUrl ?? auth.currentUser.photoURL ?? undefined,
    });
  }

  if (data.displayName || data.avatarUrl) {
    const postsRef = collection(db, "posts");
    const postsQuery = query(postsRef, where("authorId", "==", userId));
    const snapshot = await getDocs(postsQuery);
    const batch = writeBatch(db);
    snapshot.docs.forEach((docSnap) => {
      batch.update(docSnap.ref, {
        ...(data.displayName ? { authorName: data.displayName } : {}),
        ...(data.avatarUrl ? { authorAvatar: data.avatarUrl } : {}),
      });
    });
    await batch.commit();
  }
}

export async function createUserProfile(
  userId: string,
  data: Omit<UserProfile, "id">
): Promise<void> {
  const userRef = doc(db, "users", userId);
  await setDoc(
    userRef,
    {
      ...data,
      createdAt: data.createdAt ?? serverTimestamp(),
      followerCount: data.followerCount ?? 0,
      followingCount: data.followingCount ?? 0,
    },
    { merge: true }
  );
}

export async function getUsersByIds(
  ids: string[]
): Promise<UserProfile[]> {
  const results = await Promise.all(
    ids.map(async (id) => {
      const profile = await getUserProfile(id);
      return profile;
    })
  );
  return results.filter(Boolean) as UserProfile[];
}
