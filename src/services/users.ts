import { updateProfile } from "firebase/auth";
import {
  doc,
  getDoc,
  setDoc,
} from "firebase/firestore";
import { httpsCallable } from "firebase/functions";
import { auth, db, functions } from "./firebase";
import { generateRandomUsername } from "../utils/randomName";
import { removeUndefined } from "../utils/removeUndefined";

export type UserProfile = {
  id: string;
  displayName?: string;
  displayNameLower?: string;
  email?: string;
  avatarUrl?: string;
  bio?: string;
  createdAt?: unknown;
  followerCount?: number;
  followingCount?: number;
  followingPetsCount?: number;
  onboardingComplete?: boolean;
  pinnedPostId?: string;
  location?: {
    city: string;
    state: string;
    updatedAt?: unknown;
  };
};

const USER_PROFILE_CACHE_MS = 60_000;
const userProfileCache = new Map<
  string,
  { profile: UserProfile | null; expiresAt: number }
>();
const userProfileRequestCache = new Map<string, Promise<UserProfile | null>>();

export function clearUserProfileCache(userId?: string): void {
  if (userId) {
    userProfileCache.delete(userId);
    userProfileRequestCache.delete(userId);
    return;
  }
  userProfileCache.clear();
  userProfileRequestCache.clear();
}

export async function getUserProfile(
  userId: string
): Promise<UserProfile | null> {
  const cached = userProfileCache.get(userId);
  if (cached && cached.expiresAt > Date.now()) {
    return cached.profile;
  }

  const pending = userProfileRequestCache.get(userId);
  if (pending) return pending;

  const request = (async () => {
    const userRef = doc(db, "users", userId);
    const snapshot = await getDoc(userRef);
    if (!snapshot.exists()) {
      userProfileCache.set(userId, {
        profile: null,
        expiresAt: Date.now() + USER_PROFILE_CACHE_MS,
      });
      return null;
    }
    const profile = {
      id: snapshot.id,
      ...(snapshot.data() as Omit<UserProfile, "id">),
    };
    userProfileCache.set(userId, {
      profile,
      expiresAt: Date.now() + USER_PROFILE_CACHE_MS,
    });
    return profile;
  })().finally(() => {
    userProfileRequestCache.delete(userId);
  });

  userProfileRequestCache.set(userId, request);
  return request;
}

export async function updateUserProfile(
  userId: string,
  data: Partial<UserProfile>
): Promise<void> {
  await httpsCallable<
    { displayName?: string; avatarUrl?: string; bio?: string },
    { success: boolean }
  >(functions, "updateUserProfileCallable")(
    removeUndefined({
      displayName: data.displayName,
      avatarUrl: data.avatarUrl,
      bio: data.bio,
    })
  );
  clearUserProfileCache(userId);

  if (auth.currentUser && auth.currentUser.uid === userId) {
    await updateProfile(auth.currentUser, {
      displayName: data.displayName ?? auth.currentUser.displayName ?? undefined,
      photoURL: data.avatarUrl ?? auth.currentUser.photoURL ?? undefined,
    });
  }

  // Name/avatar sync to posts, comments, notifications, participants,
  // reviews, and family is handled by the onUserUpdated Cloud Function
  // triggered by this user document write. No client-side sync needed.
}

export async function createUserProfile(
  userId: string,
  data: Omit<UserProfile, "id">
): Promise<void> {
  const payload = removeUndefined({
    displayName: data.displayName,
    avatarUrl: data.avatarUrl,
    bio: data.bio,
    onboardingComplete: data.onboardingComplete,
  });
  try {
    await httpsCallable<
      {
        displayName?: string;
        avatarUrl?: string;
        bio?: string;
        onboardingComplete?: boolean;
      },
      { displayName: string; avatarUrl: string }
    >(functions, "ensureUserProfileCallable")(payload);
    clearUserProfileCache(userId);
  } catch (error) {
    console.error("Failed to create user profile:", error);
    await new Promise((resolve) => setTimeout(resolve, 1000));
    await httpsCallable<
      {
        displayName?: string;
        avatarUrl?: string;
        bio?: string;
        onboardingComplete?: boolean;
      },
      { displayName: string; avatarUrl: string }
    >(functions, "ensureUserProfileCallable")(payload);
    clearUserProfileCache(userId);
  }
}

export function validateUsername(
  username: string
): { valid: boolean; error?: string } {
  const normalized = username.trim();
  if (normalized.length < 3) {
    return { valid: false, error: "Username must be at least 3 characters" };
  }
  if (normalized.length > 20) {
    return { valid: false, error: "Username must be under 20 characters" };
  }
  if (!/^[a-zA-Z][a-zA-Z0-9_]*$/.test(normalized)) {
    if (/^[0-9]/.test(normalized)) {
      return { valid: false, error: "Username cannot start with a number" };
    }
    if (/^_/.test(normalized)) {
      return {
        valid: false,
        error: "Username cannot start with an underscore",
      };
    }
    return {
      valid: false,
      error: "Only letters, numbers, and underscores allowed",
    };
  }
  return { valid: true };
}

export async function isUsernameTaken(
  username: string,
  excludeUserId?: string
): Promise<boolean> {
  void excludeUserId;
  const normalized = username.trim();
  if (!normalized) {
    return false;
  }
  const result = await httpsCallable<
    { displayName: string },
    { available: boolean; taken: boolean }
  >(functions, "checkDisplayNameAvailabilityCallable")({
    displayName: normalized,
  });
  return result.data.taken;
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
