import {
  collection,
  doc,
  documentId,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  startAfter,
  type QueryConstraint,
  type QueryDocumentSnapshot,
  where,
} from "firebase/firestore";
import { httpsCallable } from "firebase/functions";
import { db, functions } from "./firebase";
import { calculateDistance } from "./location";

const DOCUMENT_ID_BATCH_SIZE = 30;

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

export type PetFriendlySubscores = {
  space: number;
  safety: number;
  cleanliness: number;
};

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
  // Server-aggregated fields populated by onReviewCreated / onReviewDeleted
  // and the recompute callable. Optional because legacy locations created
  // before these aggregates existed won't have them until recompute runs.
  petFriendlySum?: PetFriendlySubscores;
  petFriendlyAvg?: PetFriendlySubscores;
  tagCounts?: Record<string, number>;
  topTags?: string[];
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
  const result = await httpsCallable<
    {
      name: string;
      category?: PlaceCategory;
      description?: string;
      address: string;
      lat: number;
      lng: number;
      city: string;
      state: string;
      features?: PlaceFeature[];
      photos?: string[];
      source?: "user" | "meetup";
    },
    { locationId: string; alreadyExisted: boolean }
  >(functions, "addPlaceCallable")({
    name: data.name,
    category: data.category ?? "community_park",
    description: data.description ?? "",
    address: data.address,
    lat: data.lat,
    lng: data.lng,
    city: data.city,
    state: data.state,
    features: data.features ?? [],
    photos: data.photos ?? [],
    source: data.source ?? "meetup",
  });
  return result.data.locationId;
}

export async function submitReview(
  locationId: string,
  reviewData: Omit<Review, "id" | "createdAt">
): Promise<void> {
  await httpsCallable<
    {
      locationId: string;
      meetupId?: string;
      rating: number;
      comment: string;
      photos: string[];
      tags: string[];
      petFriendly: Review["petFriendly"];
    },
    { id: string }
  >(functions, "submitReviewCallable")({
    locationId,
    meetupId: reviewData.meetupId,
    rating: reviewData.rating,
    comment: reviewData.comment,
    photos: reviewData.photos,
    tags: reviewData.tags,
    petFriendly: reviewData.petFriendly,
  });
}

export async function getLocation(locationId: string): Promise<Location | null> {
  const locationRef = doc(db, "locations", locationId);
  const snapshot = await getDoc(locationRef);
  if (!snapshot.exists()) return null;
  return { id: snapshot.id, ...(snapshot.data() as Omit<Location, "id">) };
}

export async function batchGetLocations(
  locationIds: string[]
): Promise<Record<string, Location | null>> {
  const uniqueIds = Array.from(new Set(locationIds.filter(Boolean)));
  const locations: Record<string, Location | null> = {};
  uniqueIds.forEach((id) => {
    locations[id] = null;
  });
  if (uniqueIds.length === 0) return locations;

  const locationsRef = collection(db, "locations");
  for (let i = 0; i < uniqueIds.length; i += DOCUMENT_ID_BATCH_SIZE) {
    const chunk = uniqueIds.slice(i, i + DOCUMENT_ID_BATCH_SIZE);
    const snapshot = await getDocs(
      query(locationsRef, where(documentId(), "in", chunk))
    );
    snapshot.docs.forEach((docSnap) => {
      locations[docSnap.id] = {
        id: docSnap.id,
        ...(docSnap.data() as Omit<Location, "id">),
      };
    });
  }

  return locations;
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
  const result = await httpsCallable<
    {
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
      source: "user";
    },
    { locationId: string; alreadyExisted: boolean }
  >(functions, "addPlaceCallable")({
    name: data.name,
    category: data.category,
    description: data.description,
    address: data.address,
    lat: data.lat,
    lng: data.lng,
    city: data.city,
    state: data.state,
    features: data.features,
    photos: data.photos,
    source: "user",
  });

  return result.data;
}

export async function addPhotosToPlace(
  locationId: string,
  photoUrls: string[]
): Promise<void> {
  await httpsCallable<
    { locationId: string; photoUrls: string[] },
    { success: boolean }
  >(functions, "addLocationPhotosCallable")({
    locationId,
    photoUrls,
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

export async function getReviews(
  locationId: string,
  options?: { limitCount?: number; lastDoc?: QueryDocumentSnapshot }
): Promise<{
  reviews: Review[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  const limitCount = options?.limitCount ?? 50;
  const reviewsRef = collection(db, "locations", locationId, "reviews");
  const constraints: QueryConstraint[] = [
    orderBy("createdAt", "desc"),
    limit(limitCount),
  ];
  if (options?.lastDoc) {
    constraints.push(startAfter(options.lastDoc));
  }
  const snapshot = await getDocs(query(reviewsRef, ...constraints));
  const reviews = snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Review, "id">),
  }));
  const nextLast =
    (snapshot.docs[snapshot.docs.length - 1] as
      | QueryDocumentSnapshot
      | undefined) ?? null;
  return {
    reviews,
    lastDoc: nextLast,
    hasMore: snapshot.docs.length === limitCount,
  };
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
