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
import { getFollowing } from "./follow";

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
  const usersRef = collection(db, "users");
  const snapshot = await getDocs(
    query(usersRef, orderBy("followerCount", "desc"), limit(20))
  );
  const followingIds = currentUserId ? await getFollowing(currentUserId) : [];
  const filtered = snapshot.docs
    .map((docSnap) => ({
      id: docSnap.id,
      ...(docSnap.data() as Omit<UserProfile, "id">),
    }))
    .filter(
      (user) => user.id !== currentUserId && !followingIds.includes(user.id)
    )
    .slice(0, limitCount);
  return filtered;
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
