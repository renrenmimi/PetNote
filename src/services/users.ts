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
  limit,
} from "firebase/firestore";
import { auth, db } from "./firebase";
import { generateRandomUsername } from "../utils/randomName";

export type UserProfile = {
  id: string;
  displayName?: string;
  email?: string;
  avatarUrl?: string;
  bio?: string;
  createdAt?: unknown;
  followerCount?: number;
  followingCount?: number;
  followingPetsCount?: number;
  role?: "admin" | "user";
  banned?: boolean;
  onboardingComplete?: boolean;
  pinnedPostId?: string;
  location?: {
    lat: number;
    lng: number;
    city: string;
    state: string;
    updatedAt?: unknown;
  };
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
  const payload = {
    ...data,
    createdAt: data.createdAt ?? serverTimestamp(),
    followerCount: data.followerCount ?? 0,
    followingCount: data.followingCount ?? 0,
    followingPetsCount: data.followingPetsCount ?? 0,
  };
  try {
    await setDoc(userRef, payload, { merge: true });
  } catch (error) {
    console.error("Failed to create user profile:", error);
    await new Promise((resolve) => setTimeout(resolve, 1000));
    await setDoc(userRef, payload, { merge: true });
  }
}

export async function isUsernameTaken(
  username: string,
  excludeUserId?: string
): Promise<boolean> {
  const normalized = username.trim();
  if (!normalized) {
    return false;
  }

  const usersRef = collection(db, "users");
  const usersQuery = query(
    usersRef,
    where("displayName", "==", normalized),
    limit(10)
  );
  const snapshot = await getDocs(usersQuery);
  if (snapshot.empty) {
    return false;
  }
  if (!excludeUserId) {
    return true;
  }
  return snapshot.docs.some((docSnap) => docSnap.id !== excludeUserId);
}

export async function generateUniqueUsername(): Promise<string> {
  let attempt = 0;
  let username = generateRandomUsername();
  while (attempt < 10) {
    const taken = await isUsernameTaken(username);
    if (!taken) {
      return username;
    }
    username = generateRandomUsername();
    attempt += 1;
  }
  return `${generateRandomUsername()}${Date.now().toString().slice(-4)}`.slice(
    0,
    30
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

export async function completeOnboarding(userId: string): Promise<void> {
  const userRef = doc(db, "users", userId);
  await setDoc(userRef, { onboardingComplete: true }, { merge: true });
}

export async function checkOnboarding(userId: string): Promise<boolean> {
  const profile = await getUserProfile(userId);
  return !!profile?.onboardingComplete;
}
