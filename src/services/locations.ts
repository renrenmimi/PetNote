import {
  arrayUnion,
  collection,
  doc,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  runTransaction,
  serverTimestamp,
  where,
} from "firebase/firestore";
import { db } from "./firebase";

export type Location = {
  id: string;
  name: string;
  address: string;
  lat: number;
  lng: number;
  city: string;
  state: string;
  averageRating: number;
  totalRatings: number;
  tags: string[];
  createdAt?: unknown;
};

export type Review = {
  id: string;
  userId: string;
  userName: string;
  userAvatar: string;
  meetupId: string;
  rating: number;
  comment: string;
  tags: string[];
  petFriendly: {
    space: number;
    safety: number;
    cleanliness: number;
  };
  createdAt?: unknown;
};

export const buildLocationId = (lat: number, lng: number): string => {
  const normalize = (value: number) =>
    value
      .toFixed(4)
      .replace("-", "m")
      .replace(".", "");
  return `${normalize(lat)}_${normalize(lng)}`;
};

export async function getOrCreateLocation(data: {
  name: string;
  address: string;
  lat: number;
  lng: number;
  city: string;
  state: string;
}): Promise<string> {
  const locationId = buildLocationId(data.lat, data.lng);
  const locationRef = doc(db, "locations", locationId);
  const snapshot = await getDoc(locationRef);
  if (!snapshot.exists()) {
    await runTransaction(db, async (transaction) => {
      const fresh = await transaction.get(locationRef);
      if (!fresh.exists()) {
        transaction.set(locationRef, {
          ...data,
          averageRating: 0,
          totalRatings: 0,
          tags: [],
          createdAt: serverTimestamp(),
        });
      }
    });
  } else {
    await runTransaction(db, async (transaction) => {
      transaction.set(
        locationRef,
        {
          name: data.name,
          address: data.address,
          city: data.city,
          state: data.state,
        },
        { merge: true }
      );
    });
  }
  return locationId;
}

export async function submitReview(
  locationId: string,
  reviewData: Omit<Review, "id" | "createdAt">
): Promise<void> {
  const locationRef = doc(db, "locations", locationId);
  const reviewsRef = collection(db, "locations", locationId, "reviews");
  const reviewRef = doc(reviewsRef);

  await runTransaction(db, async (transaction) => {
    const snapshot = await transaction.get(locationRef);
    const current = snapshot.exists()
      ? (snapshot.data() as Location)
      : {
          averageRating: 0,
          totalRatings: 0,
          tags: [],
        };
    const totalRatings = (current.totalRatings || 0) + 1;
    const averageRating =
      ((current.averageRating || 0) * (current.totalRatings || 0) +
        reviewData.rating) /
      totalRatings;

    transaction.set(reviewRef, {
      ...reviewData,
      createdAt: serverTimestamp(),
    });
    const updatePayload: Record<string, unknown> = {
      averageRating: Number(averageRating.toFixed(2)),
      totalRatings,
    };
    if (reviewData.tags.length > 0) {
      updatePayload.tags = arrayUnion(...reviewData.tags);
    }
    transaction.set(locationRef, updatePayload, { merge: true });
  });
}

export async function getLocation(locationId: string): Promise<Location | null> {
  const locationRef = doc(db, "locations", locationId);
  const snapshot = await getDoc(locationRef);
  if (!snapshot.exists()) return null;
  return { id: snapshot.id, ...(snapshot.data() as Omit<Location, "id">) };
}

export async function getReviews(locationId: string): Promise<Review[]> {
  const reviewsRef = collection(db, "locations", locationId, "reviews");
  const reviewsQuery = query(reviewsRef, orderBy("createdAt", "desc"));
  const snapshot = await getDocs(reviewsQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Review, "id">),
  }));
}

export async function hasUserReviewed(
  locationId: string,
  userId: string,
  meetupId: string
): Promise<boolean> {
  const reviewsRef = collection(db, "locations", locationId, "reviews");
  const reviewsQuery = query(
    reviewsRef,
    where("userId", "==", userId),
    where("meetupId", "==", meetupId),
    limit(1)
  );
  const snapshot = await getDocs(reviewsQuery);
  return !snapshot.empty;
}

export async function getUserReview(
  locationId: string,
  userId: string,
  meetupId: string
): Promise<Review | null> {
  const reviewsRef = collection(db, "locations", locationId, "reviews");
  const reviewsQuery = query(
    reviewsRef,
    where("userId", "==", userId),
    where("meetupId", "==", meetupId),
    limit(1)
  );
  const snapshot = await getDocs(reviewsQuery);
  if (snapshot.empty) return null;
  const docSnap = snapshot.docs[0];
  return { id: docSnap.id, ...(docSnap.data() as Omit<Review, "id">) };
}

export async function getTopRatedLocations(
  city: string,
  limitCount = 5
): Promise<Location[]> {
  const locationsRef = collection(db, "locations");
  const locationsQuery = query(
    locationsRef,
    where("city", "==", city),
    orderBy("averageRating", "desc"),
    orderBy("totalRatings", "desc"),
    limit(limitCount)
  );
  const snapshot = await getDocs(locationsQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Location, "id">),
  }));
}
