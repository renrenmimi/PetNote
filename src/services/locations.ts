import {
  addDoc,
  arrayUnion,
  collection,
  doc,
  getDoc,
  getDocs,
  increment,
  limit,
  orderBy,
  query,
  runTransaction,
  serverTimestamp,
  where,
  updateDoc,
  startAfter,
  type QueryConstraint,
  type QueryDocumentSnapshot,
} from "firebase/firestore";
import { db } from "./firebase";
import { calculateDistance } from "./location";
import { removeUndefined } from "../utils/removeUndefined";

export type PlaceCategory =
  | "dog_park"
  | "hiking_trail"
  | "beach"
  | "community_park"
  | "cafe"
  | "green_space"
  | "pet_store"
  | "vet"
  | "other";

export type PlaceFeature =
  | "off_leash"
  | "fenced"
  | "water_access"
  | "waste_bags"
  | "parking"
  | "restrooms"
  | "seating"
  | "shade"
  | "lighting"
  | "beach_access"
  | "trails"
  | "food_nearby";

export type Location = {
  id: string;
  name: string;
  address: string;
  lat: number;
  lng: number;
  city: string;
  state: string;
  category: PlaceCategory;
  description: string;
  features: PlaceFeature[];
  locationPhotos?: string[];
  photos: string[];
  addedBy: string;
  addedByName: string;
  averageRating: number;
  totalRatings: number;
  totalPhotos: number;
  totalCheckins?: number;
  verifiedByCheckins?: boolean;
  tags: string[];
  source: "user" | "meetup";
  verified: boolean;
  createdAt?: unknown;
  updatedAt?: unknown;
};

export type Review = {
  id: string;
  userId: string;
  userName: string;
  userAvatar: string;
  meetupId?: string;
  rating: number;
  comment: string;
  photos: string[];
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
  category?: PlaceCategory;
  description?: string;
  features?: PlaceFeature[];
  photos?: string[];
  addedBy?: string;
  addedByName?: string;
  source?: "user" | "meetup";
}): Promise<string> {
  const locationId = buildLocationId(data.lat, data.lng);
  const locationRef = doc(db, "locations", locationId);
  const snapshot = await getDoc(locationRef);
  if (!snapshot.exists()) {
    await runTransaction(db, async (transaction) => {
      const fresh = await transaction.get(locationRef);
      if (!fresh.exists()) {
        transaction.set(
          locationRef,
          removeUndefined({
            ...data,
            category: data.category ?? "community_park",
            description: data.description ?? "",
            features: data.features ?? [],
            locationPhotos: data.photos ?? [],
            photos: data.photos ?? [],
            addedBy: data.addedBy ?? "",
            addedByName: data.addedByName ?? "",
            averageRating: 0,
            totalRatings: 0,
            totalPhotos: data.photos?.length ?? 0,
            totalCheckins: 0,
            verifiedByCheckins: false,
            tags: [],
            source: data.source ?? "meetup",
            verified: false,
            createdAt: serverTimestamp(),
            updatedAt: serverTimestamp(),
          })
        );
      }
    });
  }
  // If location already exists, just return the ID.
  // Don't try to merge-update — only the original creator or admin
  // has update permission per firestore.rules.
  return locationId;
}

export async function submitReview(
  locationId: string,
  reviewData: Omit<Review, "id" | "createdAt">
): Promise<void> {
  // Only create the review document. Location aggregation (averageRating,
  // totalRatings, photos, tags, totalPhotos) is maintained exclusively by
  // the onReviewCreated Cloud Function to prevent client-side tampering.
  const reviewsRef = collection(db, "locations", locationId, "reviews");
  await addDoc(reviewsRef, removeUndefined({
    ...reviewData,
    createdAt: serverTimestamp(),
  }));
}

export async function getLocation(locationId: string): Promise<Location | null> {
  const locationRef = doc(db, "locations", locationId);
  const snapshot = await getDoc(locationRef);
  if (!snapshot.exists()) return null;
  return { id: snapshot.id, ...(snapshot.data() as Omit<Location, "id">) };
}

export async function getPlaces(options: {
  category?: PlaceCategory;
  sortBy: "nearby" | "top_rated" | "most_reviewed" | "newest";
  userLat?: number;
  userLng?: number;
  limit: number;
  lastDoc?: QueryDocumentSnapshot;
}): Promise<{
  places: Location[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  const locationsRef = collection(db, "locations");
  const constraints: QueryConstraint[] = [];
  if (options.category && options.category !== "other") {
    constraints.push(where("category", "==", options.category));
  }
  if (options.sortBy === "top_rated") {
    constraints.push(orderBy("averageRating", "desc"), orderBy("totalRatings", "desc"));
  } else if (options.sortBy === "most_reviewed") {
    constraints.push(orderBy("totalRatings", "desc"));
  } else {
    constraints.push(orderBy("createdAt", "desc"));
  }
  constraints.push(limit(options.limit));
  if (options.lastDoc) constraints.push(startAfter(options.lastDoc));
  const placesQuery = query(locationsRef, ...constraints);
  const snapshot = await getDocs(placesQuery);
  let places = snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Location, "id">),
  }));

  if (options.sortBy === "nearby" && options.userLat && options.userLng) {
    places = places
      .map((place) => ({
        place,
        distance: calculateDistance(
          options.userLat!,
          options.userLng!,
          place.lat,
          place.lng
        ),
      }))
      .sort((a, b) => a.distance - b.distance)
      .map((item) => item.place);
  }

  const nextLast = snapshot.docs[snapshot.docs.length - 1] ?? null;
  return {
    places,
    lastDoc: nextLast,
    hasMore: snapshot.docs.length === options.limit,
  };
}

export async function searchPlaces(queryText: string): Promise<Location[]> {
  const needle = queryText.trim();
  if (!needle) return [];
  const locationsRef = collection(db, "locations");
  const placesQuery = query(
    locationsRef,
    where("name", ">=", needle),
    where("name", "<=", `${needle}\uf8ff`),
    orderBy("name"),
    limit(20)
  );
  const snapshot = await getDocs(placesQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Location, "id">),
  }));
}

export async function addPlace(data: {
  name: string;
  category: PlaceCategory;
  description: string;
  address: string;
  lat: number;
  lng: number;
  city: string;
  state: string;
  features: PlaceFeature[];
  photos: string[];
  addedBy: string;
  addedByName: string;
}): Promise<{ locationId: string; alreadyExisted: boolean }> {
  const locationId = buildLocationId(data.lat, data.lng);
  const locationRef = doc(db, "locations", locationId);
  let alreadyExisted = false;
  await runTransaction(db, async (transaction) => {
    const snapshot = await transaction.get(locationRef);
    if (snapshot.exists()) {
      alreadyExisted = true;
      return;
    }
    transaction.set(locationRef, {
      ...data,
      locationPhotos: data.photos,
      averageRating: 0,
      totalRatings: 0,
      totalPhotos: data.photos.length,
      tags: [],
      source: "user",
      verified: false,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    });
  });

  return { locationId, alreadyExisted };
}

export async function addPhotosToPlace(
  locationId: string,
  photoUrls: string[]
): Promise<void> {
  const locationRef = doc(db, "locations", locationId);
  await updateDoc(locationRef, {
    locationPhotos: arrayUnion(...photoUrls),
    photos: arrayUnion(...photoUrls),
    totalPhotos: increment(photoUrls.length || 0),
    updatedAt: serverTimestamp(),
  });
}

export async function findNearbyPlace(
  lat: number,
  lng: number
): Promise<Location | null> {
  const locationsRef = collection(db, "locations");
  const latMin = lat - 0.001;
  const latMax = lat + 0.001;
  const q = query(
    locationsRef,
    where("lat", ">=", latMin),
    where("lat", "<=", latMax),
    limit(20)
  );
  const snapshot = await getDocs(q);
  const found = snapshot.docs
    .map((docSnap) => ({
      id: docSnap.id,
      ...(docSnap.data() as Omit<Location, "id">),
    }))
    .find((place) => Math.abs(place.lng - lng) <= 0.001);
  return found ?? null;
}

export async function getPlacesByCategory(
  category: PlaceCategory,
  limitCount = 10
): Promise<Location[]> {
  const locationsRef = collection(db, "locations");
  const locationsQuery = query(
    locationsRef,
    where("category", "==", category),
    orderBy("averageRating", "desc"),
    limit(limitCount)
  );
  const snapshot = await getDocs(locationsQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Location, "id">),
  }));
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
  meetupId?: string
): Promise<Review | null> {
  const reviewsRef = collection(db, "locations", locationId, "reviews");
  const reviewsQuery = meetupId
    ? query(
        reviewsRef,
        where("userId", "==", userId),
        where("meetupId", "==", meetupId),
        limit(1)
      )
    : query(reviewsRef, where("userId", "==", userId), orderBy("createdAt", "desc"), limit(1));
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
