import {
  collection,
  getDocs,
  limit,
  orderBy,
  query,
  Timestamp,
  where,
} from "firebase/firestore";
import { db } from "./firebase";
import type { Post } from "./posts";
import type { UserProfile } from "./users";
import type { Pet } from "./pets";
import type { Location } from "./locations";
import type { Meetup } from "./meetups";
import { getFollowingPets } from "./follow";

export async function getTrendingPosts(limitCount = 6): Promise<Post[]> {
  const postsRef = collection(db, "posts");
  const since = Timestamp.fromDate(
    new Date(Date.now() - 7 * 24 * 60 * 60 * 1000)
  );
  const postsQuery = query(
    postsRef,
    where("createdAt", ">=", since),
    orderBy("createdAt", "desc"),
    limit(Math.max(limitCount * 10, 50))
  );
  const snapshot = await getDocs(postsQuery);
  return snapshot.docs
    .map((docSnap) => ({
      id: docSnap.id,
      ...(docSnap.data() as Omit<Post, "id">),
    }))
    .sort((a, b) => {
      const likeDelta = (b.likeCount ?? 0) - (a.likeCount ?? 0);
      if (likeDelta !== 0) return likeDelta;
      return (b.createdAt?.toMillis?.() ?? 0) - (a.createdAt?.toMillis?.() ?? 0);
    })
    .slice(0, limitCount);
}

export async function getSuggestedUsers(
  currentUserId: string,
  limitCount = 8
): Promise<UserProfile[]> {
  // Deprecated in follow-pet model. Kept only for compatibility.
  void currentUserId;
  void limitCount;
  return [];
}

export async function getSuggestedPets(
  currentUserId: string,
  limitCount = 8
): Promise<Array<Pet & { postCount: number }>> {
  const petsRef = collection(db, "pets");
  const [petSnapshot, followingPets] = await Promise.all([
    getDocs(query(petsRef, orderBy("followerCount", "desc"), limit(50))),
    currentUserId ? getFollowingPets(currentUserId) : Promise.resolve([]),
  ]);
  const followedIds = new Set(followingPets.map((item) => item.petId));

  const rankedPets = petSnapshot.docs
    .map((docSnap) => ({
      id: docSnap.id,
      ...(docSnap.data() as Omit<Pet, "id">),
    }))
    .filter((pet) => !followedIds.has(pet.id))
    .slice(0, limitCount);

  return rankedPets.map((pet) => {
    const storedPostCount = (pet as Pet & { postCount?: unknown }).postCount;
    return {
      ...pet,
      postCount: typeof storedPostCount === "number" ? storedPostCount : 0,
    };
  });
}

export async function getPopularPets(limitCount = 8): Promise<Array<Pet & { postCount: number }>> {
  const postsRef = collection(db, "posts");
  const snapshot = await getDocs(query(postsRef, orderBy("createdAt", "desc"), limit(120)));
  const counts = new Map<string, number>();
  snapshot.docs.forEach((docSnap) => {
    const data = docSnap.data() as Post;
    if (data.petId) {
      counts.set(data.petId, (counts.get(data.petId) || 0) + 1);
    }
  });

  const sorted = Array.from(counts.entries())
    .sort((a, b) => b[1] - a[1])
    .slice(0, limitCount);

  const petIds = sorted.map(([petId]) => petId);
  if (petIds.length === 0) return [];

  // Batch fetch all pet documents instead of N+1 individual queries
  const petsRef = collection(db, "pets");
  const petMap = new Map<string, Pet>();
  const chunkSize = 10;
  for (let i = 0; i < petIds.length; i += chunkSize) {
    const chunk = petIds.slice(i, i + chunkSize);
    const petSnapshot = await getDocs(query(petsRef, where("__name__", "in", chunk)));
    petSnapshot.docs.forEach((petDoc) => {
      petMap.set(petDoc.id, { id: petDoc.id, ...(petDoc.data() as Omit<Pet, "id">) });
    });
  }

  return sorted
    .filter(([petId]) => petMap.has(petId))
    .map(([petId, postCount]) => ({
      ...petMap.get(petId)!,
      postCount,
    }));
}

export async function getTopRatedPlaces(limitCount = 5): Promise<Location[]> {
  const locationsRef = collection(db, "locations");
  const snapshot = await getDocs(
    query(
      locationsRef,
      orderBy("averageRating", "desc"),
      orderBy("totalRatings", "desc"),
      limit(limitCount)
    )
  );
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Location, "id">),
  }));
}

export async function getUpcomingMeetupPreview(
  limitCount = 3
): Promise<Meetup[]> {
  const meetupsRef = collection(db, "meetups");
  const snapshot = await getDocs(
    query(
      meetupsRef,
      where("status", "==", "upcoming"),
      orderBy("date", "asc"),
      limit(limitCount)
    )
  );
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Meetup, "id">),
  }));
}
