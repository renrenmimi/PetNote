import {
  collection,
  doc,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  startAfter,
  type QueryConstraint,
  type QueryDocumentSnapshot,
} from "firebase/firestore";
import { httpsCallable } from "firebase/functions";
import { db, functions } from "./firebase";

export type FollowingPet = {
  id: string;
  petId: string;
  petName: string;
  petAvatar: string;
  followedAt?: unknown;
};

export type PetFollower = {
  id: string;
  userId: string;
  userName: string;
  userAvatar: string;
  followedAt?: unknown;
};

/**
 * Short-lived cache for the *first* page of a user's followed pets.
 *
 * The same list is read by four different callers — the following-feed query
 * in services/posts.ts, the Feed's empty-state count, meetup eligibility and
 * explore suggestions — and switching to the Following tab hit two of them
 * back to back, so up to 200 documents were read twice for one action.
 *
 * Only the unpaginated first page is cached: a `lastDoc` cursor makes each
 * page a distinct question, and caching those would mean reasoning about
 * cursor identity for no benefit. Follow and unfollow invalidate it, so the
 * window a stale answer can survive is bounded by a deliberate write, not by
 * the TTL — the TTL is only a backstop for changes made in another tab or on
 * another device.
 */
const FOLLOWING_CACHE_MS = 30_000;
type FollowingPage = {
  followingPets: FollowingPet[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
};
const followingCache = new Map<
  string,
  { page: FollowingPage; expiresAt: number }
>();

export function clearFollowingCache(userId?: string): void {
  if (userId) followingCache.delete(userId);
  else followingCache.clear();
}

export async function followPet(_userId: string, petId: string): Promise<void> {
  if (!petId) return;
  await httpsCallable<{ petId: string }, { success: boolean }>(
    functions,
    "followPetCallable"
  )({ petId });
  clearFollowingCache();
}

export async function unfollowPet(_userId: string, petId: string): Promise<void> {
  if (!petId) return;
  await httpsCallable<{ petId: string }, { success: boolean }>(
    functions,
    "unfollowPetCallable"
  )({ petId });
  clearFollowingCache();
}

export async function checkIfFollowingPet(
  userId: string,
  petId: string
): Promise<boolean> {
  if (!userId || !petId) return false;
  const followingRef = doc(db, "users", userId, "followingPets", petId);
  const snapshot = await getDoc(followingRef);
  return snapshot.exists();
}

export async function getFollowingPets(
  userId: string,
  options?: { limitCount?: number; lastDoc?: QueryDocumentSnapshot }
): Promise<{
  followingPets: FollowingPet[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  if (!userId) {
    return { followingPets: [], lastDoc: null, hasMore: false };
  }
  // Default 200 keeps the first page generous enough for power users while
  // still bounding cost: feed-building and eligibility checks operate on
  // this list, and users following more than 200 pets can keep paginating.
  const limitCount = options?.limitCount ?? 200;
  const cacheable = !options?.lastDoc && limitCount === 200;
  if (cacheable) {
    const cached = followingCache.get(userId);
    if (cached && cached.expiresAt > Date.now()) {
      return cached.page;
    }
  }
  const followingRef = collection(db, "users", userId, "followingPets");
  const constraints: QueryConstraint[] = [
    orderBy("followedAt", "desc"),
    limit(limitCount),
  ];
  if (options?.lastDoc) {
    constraints.push(startAfter(options.lastDoc));
  }
  const snapshot = await getDocs(query(followingRef, ...constraints));
  const followingPets = snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<FollowingPet, "id">),
  }));
  const nextLast =
    (snapshot.docs[snapshot.docs.length - 1] as
      | QueryDocumentSnapshot
      | undefined) ?? null;
  const page: FollowingPage = {
    followingPets,
    lastDoc: nextLast,
    hasMore: snapshot.docs.length === limitCount,
  };
  if (cacheable) {
    followingCache.set(userId, {
      page,
      expiresAt: Date.now() + FOLLOWING_CACHE_MS,
    });
  }
  return page;
}

export async function getPetFollowers(
  petId: string,
  options?: { limitCount?: number; lastDoc?: QueryDocumentSnapshot }
): Promise<{
  followers: PetFollower[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  if (!petId) {
    return { followers: [], lastDoc: null, hasMore: false };
  }
  const limitCount = options?.limitCount ?? 100;
  const followersRef = collection(db, "pets", petId, "followers");
  const constraints: QueryConstraint[] = [
    orderBy("followedAt", "desc"),
    limit(limitCount),
  ];
  if (options?.lastDoc) {
    constraints.push(startAfter(options.lastDoc));
  }
  const snapshot = await getDocs(query(followersRef, ...constraints));
  const followers = snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<PetFollower, "id">),
  }));
  const nextLast =
    (snapshot.docs[snapshot.docs.length - 1] as
      | QueryDocumentSnapshot
      | undefined) ?? null;
  return {
    followers,
    lastDoc: nextLast,
    hasMore: snapshot.docs.length === limitCount,
  };
}
