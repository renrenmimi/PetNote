import {
  collection,
  doc,
  getDoc,
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
    orderBy("likeCount", "desc"),
    orderBy("createdAt", "desc"),
    limit(limitCount)
  );
  const snapshot = await getDocs(postsQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Post, "id">),
  }));
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

  const postCounts = await Promise.all(
    rankedPets.map(async (pet) => {
      const postsSnapshot = await getDocs(
        query(
          collection(db, "posts"),
          where("petId", "==", pet.id),
          limit(100)
        )
      );
      return { petId: pet.id, count: postsSnapshot.size };
    })
  );
  const countMap = new Map(postCounts.map((item) => [item.petId, item.count]));
  return rankedPets.map((pet) => ({
    ...pet,
    postCount: countMap.get(pet.id) ?? 0,
  }));
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

  const results: Array<Pet & { postCount: number }> = [];
  for (const [petId, postCount] of sorted) {
    const petSnap = await getDoc(doc(db, "pets", petId));
    if (petSnap.exists()) {
      results.push({
        id: petSnap.id,
        ...(petSnap.data() as Omit<Pet, "id">),
        postCount,
      });
    }
  }
  return results;
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
