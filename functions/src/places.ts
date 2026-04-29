import { createHash } from "node:crypto";
import { onDocumentCreated, onDocumentDeleted } from "firebase-functions/v2/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { admin, db } from "./platform";
import { getNotificationActor } from "./notifications";
import {
  applyReviewAggregationDelta,
  getDefaultAvatar,
  LOCATION_PHOTO_PREVIEW_LIMIT,
  mergeCappedStrings,
  optionalTrimmedString,
  requiredTrimmedString,
  validateCoordinateRange,
  VALIDATION_LIMITS,
} from "./shared";
import { getAccessiblePet } from "./pets";

const allowedPlaceCategories = new Set([
  "dog_park",
  "hiking_trail",
  "beach",
  "community_park",
  "cafe",
  "green_space",
  "pet_store",
  "vet",
  "other",
]);

const allowedPlaceFeatures = new Set([
  "off_leash",
  "fenced",
  "water_access",
  "waste_bags",
  "parking",
  "restrooms",
  "seating",
  "shade",
  "lighting",
  "beach_access",
  "trails",
  "food_nearby",
]);

function locationPhotoEntryId(url: string): string {
  return createHash("sha1").update(url).digest("hex");
}

async function writeLocationPhotoEntries(
  locationId: string,
  photoUrls: string[],
  source: "place" | "review" | "location_photo",
  addedBy?: string
): Promise<void> {
  if (photoUrls.length === 0) return;
  const batch = db.batch();
  photoUrls.forEach((url) => {
    const entryRef = db.doc(
      `locations/${locationId}/photoEntries/${locationPhotoEntryId(url)}`
    );
    batch.set(
      entryRef,
      {
        url,
        source,
        addedBy: addedBy || "",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  });
  await batch.commit();
}

async function appendLocationPhotoPreviews(
  locationId: string,
  photoUrls: string[],
  incrementTotalPhotos: boolean
): Promise<void> {
  if (photoUrls.length === 0) return;
  const locationRef = db.doc(`locations/${locationId}`);
  await db.runTransaction(async (transaction) => {
    const locationSnap = await transaction.get(locationRef);
    if (!locationSnap.exists) {
      throw new HttpsError("not-found", "Location not found.");
    }
    const data = locationSnap.data() ?? {};
    transaction.update(locationRef, {
      photos: mergeCappedStrings(
        data.photos,
        photoUrls,
        LOCATION_PHOTO_PREVIEW_LIMIT
      ),
      locationPhotos: mergeCappedStrings(
        data.locationPhotos,
        photoUrls,
        LOCATION_PHOTO_PREVIEW_LIMIT
      ),
      ...(incrementTotalPhotos
        ? { totalPhotos: admin.firestore.FieldValue.increment(photoUrls.length) }
        : {}),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
}

function buildLocationId(lat: number, lng: number, name: string): string {
  // 5 decimals ~= 1.1m precision (vs. the previous 4 decimals / ~11m which
  // collapsed neighbouring distinct places into the same doc).
  const normalize = (value: number) =>
    value
      .toFixed(5)
      .replace("-", "m")
      .replace(".", "");
  const normalizedName = name.trim().toLowerCase();
  // Short name hash keeps truly-same places deduplicated while preventing
  // collisions between different venues that happen to share coordinates
  // (multi-tenant buildings, strip malls, same park with different entries).
  const nameHash = normalizedName
    ? createHash("sha1").update(normalizedName).digest("hex").slice(0, 6)
    : "noname";
  return `${normalize(lat)}_${normalize(lng)}_${nameHash}`;
}

function sanitizePlaceDraft(value: unknown): {
  name: string;
  category: string;
  description: string;
  address: string;
  lat: number;
  lng: number;
  city: string;
  state: string;
  features: string[];
  photos: string[];
  source: "user" | "meetup";
} {
  const data =
    value && typeof value === "object" ? (value as Record<string, unknown>) : {};

  const name = requiredTrimmedString(
    data.name,
    VALIDATION_LIMITS.placeName,
    "Place name"
  );
  const address = requiredTrimmedString(
    data.address,
    VALIDATION_LIMITS.address,
    "Address"
  );
  const lat = typeof data.lat === "number" ? data.lat : Number.NaN;
  const lng = typeof data.lng === "number" ? data.lng : Number.NaN;
  if (!validateCoordinateRange(lat, lng)) {
    throw new HttpsError("invalid-argument", "Place name, address, and coordinates are required.");
  }

  const category =
    typeof data.category === "string" && allowedPlaceCategories.has(data.category)
      ? data.category
      : "other";
  const description = optionalTrimmedString(
    data.description,
    VALIDATION_LIMITS.placeDescription,
    "Place description"
  );
  const city = optionalTrimmedString(data.city, VALIDATION_LIMITS.city, "City");
  const state = optionalTrimmedString(data.state, VALIDATION_LIMITS.state, "State");
  const features = Array.isArray(data.features)
    ? Array.from(
        new Set(
          data.features.filter(
            (feature): feature is string =>
              typeof feature === "string" && allowedPlaceFeatures.has(feature)
          )
        )
      )
    : [];
  const photos = Array.isArray(data.photos)
    ? data.photos
        .filter((photo): photo is string => typeof photo === "string" && photo.trim().length > 0)
        .slice(0, 5)
        .map((photo) => optionalTrimmedString(photo, VALIDATION_LIMITS.url, "Photo URL"))
    : [];
  const source = data.source === "meetup" ? "meetup" : "user";

  return {
    name,
    category,
    description,
    address,
    lat,
    lng,
    city,
    state,
    features,
    photos,
    source,
  };
}

export async function getOrCreatePublicMeetupLocation(params: {
  organizerId: string;
  organizerName: string;
  location: {
    name: string;
    address: string;
    lat: number;
    lng: number;
    city?: string;
    state?: string;
  };
}): Promise<string> {
  const locationId = buildLocationId(
    params.location.lat,
    params.location.lng,
    params.location.name
  );
  const locationRef = db.doc(`locations/${locationId}`);
  const locationSnap = await locationRef.get();
  if (!locationSnap.exists) {
    await locationRef.set({
      name: params.location.name,
      category: "community_park",
      description: "",
      address: params.location.address,
      lat: params.location.lat,
      lng: params.location.lng,
      city: params.location.city || "",
      state: params.location.state || "",
      features: [],
      photos: [],
      locationPhotos: [],
      addedBy: params.organizerId,
      addedByName: params.organizerName,
      averageRating: 0,
      totalRatings: 0,
      totalPhotos: 0,
      totalCheckins: 0,
      verifiedByCheckins: false,
      tags: [],
      source: "meetup",
      verified: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
  return locationId;
}

export const onReviewCreated = onDocumentCreated(
  "locations/{locationId}/reviews/{reviewId}",
  async (event) => {
    const reviewData = event.data?.data() ?? {};
    if (reviewData?.userId) {
      const actor = await getNotificationActor(reviewData.userId);
      const reviewRef = db.doc(`locations/${event.params.locationId}/reviews/${event.params.reviewId}`);
      await reviewRef.update({
        userName: actor.fromUserName,
        userAvatar: actor.fromUserAvatar,
      });
    }
    const rating = typeof reviewData.rating === "number" ? reviewData.rating : 0;
    const tagsToAdd = Array.isArray(reviewData.tags)
      ? (reviewData.tags as unknown[]).filter(
          (tag): tag is string => typeof tag === "string" && tag.length > 0
        )
      : [];
    const photosToAdd = Array.isArray(reviewData.photos)
      ? (reviewData.photos as unknown[]).filter(
          (photo): photo is string => typeof photo === "string" && photo.length > 0
        )
      : [];
    await Promise.all([
      applyReviewAggregationDelta(event.params.locationId, {
        ratingSum: rating,
        count: 1,
        tagsToAdd,
        photosToAdd,
      }),
      writeLocationPhotoEntries(
        event.params.locationId,
        photosToAdd,
        "review",
        typeof reviewData.userId === "string" ? reviewData.userId : undefined
      ),
    ]);
  }
);

export const onReviewDeleted = onDocumentDeleted(
  "locations/{locationId}/reviews/{reviewId}",
  async (event) => {
    const reviewData = event.data?.data() ?? {};
    const rating = typeof reviewData.rating === "number" ? reviewData.rating : 0;
    // Intentionally does not remove tags/photos: they may still be
    // referenced by other remaining reviews, and arrayRemove without that
    // knowledge would lose real data. Stale entries get cleaned up on a
    // periodic full recompute if ever needed.
    await applyReviewAggregationDelta(event.params.locationId, {
      ratingSum: -rating,
      count: -1,
    });
  }
);

async function adjustLocationCheckinCount(
  locationId: string,
  delta: 1 | -1
): Promise<void> {
  const locationRef = db.doc(`locations/${locationId}`);
  await db.runTransaction(async (t) => {
    const snap = await t.get(locationRef);
    if (!snap.exists) return;
    const prev =
      typeof snap.data()?.totalCheckins === "number"
        ? (snap.data() as { totalCheckins: number }).totalCheckins
        : 0;
    const next = Math.max(0, prev + delta);
    t.update(locationRef, {
      totalCheckins: next,
      verifiedByCheckins: next >= 3,
    });
  });
}

export const onCheckinCreated = onDocumentCreated(
  "locations/{locationId}/checkins/{checkinId}",
  async (event) => {
    const locationId = event.params.locationId;

    const checkinData = event.data?.data();
    if (checkinData?.userId) {
      const actor = await getNotificationActor(checkinData.userId);
      const checkinRef = db.doc(`locations/${locationId}/checkins/${event.params.checkinId}`);
      await checkinRef.update({
        userName: actor.fromUserName,
        userAvatar: actor.fromUserAvatar,
      });
    }

    // Transaction-based +1 instead of counting every check-in on the
    // location. Keeps verifiedByCheckins consistent with the stored total.
    await adjustLocationCheckinCount(locationId, 1);
  }
);

export const onCheckinDeleted = onDocumentDeleted(
  "locations/{locationId}/checkins/{checkinId}",
  async (event) => {
    await adjustLocationCheckinCount(event.params.locationId, -1);
  }
);

export const addPlaceCallable = onCall(async (request) => {
  const callerAuth = request.auth;
  const callerUid = callerAuth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");
  if (callerAuth.token.email_verified !== true) {
    throw new HttpsError("permission-denied", "Verify your email before creating places.");
  }

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot create places.");
  }

  const place = sanitizePlaceDraft(request.data);
  const locationId = buildLocationId(place.lat, place.lng, place.name);
  const locationRef = db.doc(`locations/${locationId}`);
  let alreadyExisted = false;

  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(locationRef);
    if (snapshot.exists) {
      alreadyExisted = true;
      return;
    }

    transaction.set(
      locationRef,
      {
        name: place.name,
        category: place.category,
        description: place.description,
        address: place.address,
        lat: place.lat,
        lng: place.lng,
        city: place.city,
        state: place.state,
        features: place.features,
        locationPhotos: place.photos,
        photos: place.photos,
        addedBy: callerUid,
        addedByName: caller.fromUserName,
        averageRating: 0,
        totalRatings: 0,
        totalPhotos: place.photos.length,
        totalCheckins: 0,
        verifiedByCheckins: false,
        tags: [],
        source: place.source,
        verified: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }
    );
  });

  if (!alreadyExisted) {
    await writeLocationPhotoEntries(locationId, place.photos, "place", callerUid);
  }

  return { locationId, alreadyExisted };
});

export const addLocationPhotosCallable = onCall(async (request) => {
  const callerAuth = request.auth;
  const callerUid = callerAuth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");
  if (callerAuth.token.email_verified !== true) {
    throw new HttpsError("permission-denied", "Verify your email before adding place photos.");
  }

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot add place photos.");
  }

  const data = request.data as { locationId?: string; photoUrls?: unknown };
  if (!data.locationId || typeof data.locationId !== "string") {
    throw new HttpsError("invalid-argument", "Missing locationId.");
  }
  const photoUrls = Array.isArray(data.photoUrls)
    ? data.photoUrls
        .filter((photo): photo is string => typeof photo === "string" && photo.trim().length > 0)
        .slice(0, 5)
        .map((photo) => optionalTrimmedString(photo, VALIDATION_LIMITS.url, "Photo URL"))
    : [];
  if (photoUrls.length === 0) {
    return { success: true };
  }

  const locationRef = db.doc(`locations/${data.locationId}`);
  const locationSnap = await locationRef.get();
  if (!locationSnap.exists) {
    throw new HttpsError("not-found", "Location not found.");
  }

  const locationData = locationSnap.data() ?? {};
  const canUpdate = locationData.addedBy === callerUid || caller.role === "admin";
  if (!canUpdate) {
    throw new HttpsError("permission-denied", "Cannot add photos to this location.");
  }

  await appendLocationPhotoPreviews(data.locationId, photoUrls, true);
  await writeLocationPhotoEntries(data.locationId, photoUrls, "location_photo", callerUid);

  return { success: true };
});

export const submitReviewCallable = onCall(async (request) => {
  const callerAuth = request.auth;
  const callerUid = callerAuth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");
  if (callerAuth.token.email_verified !== true) {
    throw new HttpsError("permission-denied", "Verify your email before reviewing.");
  }

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot review locations.");
  }

  const data = request.data as {
    locationId?: string;
    meetupId?: string;
    rating?: number;
    comment?: string;
    photos?: string[];
    tags?: string[];
    petFriendly?: { space?: number; safety?: number; cleanliness?: number };
  };

  if (!data.locationId || typeof data.locationId !== "string") {
    throw new HttpsError("invalid-argument", "Missing locationId.");
  }
  if (typeof data.rating !== "number" || data.rating < 1 || data.rating > 5) {
    throw new HttpsError("invalid-argument", "Rating must be between 1 and 5.");
  }

  const locationRef = db.doc(`locations/${data.locationId}`);
  const locationSnap = await locationRef.get();
  if (!locationSnap.exists) {
    throw new HttpsError("not-found", "Location not found.");
  }

  if (data.meetupId) {
    const meetupRef = db.doc(`meetups/${data.meetupId}`);
    const participantRef = db.doc(`meetups/${data.meetupId}/participants/${callerUid}`);
    const [meetupSnap, participantSnap] = await Promise.all([meetupRef.get(), participantRef.get()]);
    if (!meetupSnap.exists) {
      throw new HttpsError("not-found", "Meetup not found.");
    }
    const meetupData = meetupSnap.data() ?? {};
    if (meetupData.organizerId !== callerUid && !participantSnap.exists) {
      throw new HttpsError("permission-denied", "Only meetup participants can attach meetup reviews.");
    }
    if (meetupData.status !== "completed" || meetupData.isRatingOpen !== true) {
      throw new HttpsError("permission-denied", "Meetup reviews open only after the meetup is completed.");
    }
  }

  const reviewId = data.meetupId ? `${callerUid}_${data.meetupId}` : callerUid;
  const reviewRef = db.doc(`locations/${data.locationId}/reviews/${reviewId}`);

  // Use .create() so concurrent submissions can't both pass a stale
  // existence check and overwrite each other; Firestore rejects the
  // second call with ALREADY_EXISTS.
  try {
    await reviewRef.create({
      userId: callerUid,
      userName: caller.fromUserName,
      userAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
      meetupId: data.meetupId,
      rating: data.rating,
      comment: optionalTrimmedString(
        data.comment,
        VALIDATION_LIMITS.reviewComment,
        "Review comment"
      ),
      photos: Array.isArray(data.photos)
        ? data.photos
            .filter((p): p is string => typeof p === "string" && p.trim().length > 0)
            .slice(0, 3)
            .map((photo) => optionalTrimmedString(photo, VALIDATION_LIMITS.url, "Photo URL"))
        : [],
      tags: Array.isArray(data.tags)
        ? data.tags
            .filter((t): t is string => typeof t === "string" && t.trim().length > 0)
            .slice(0, 12)
            .map((tag) => optionalTrimmedString(tag, VALIDATION_LIMITS.tag, "Review tag"))
        : [],
      petFriendly: {
        space: typeof data.petFriendly?.space === "number" ? data.petFriendly.space : data.rating,
        safety: typeof data.petFriendly?.safety === "number" ? data.petFriendly.safety : data.rating,
        cleanliness:
          typeof data.petFriendly?.cleanliness === "number"
            ? data.petFriendly.cleanliness
            : data.rating,
      },
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (error) {
    if (
      typeof error === "object" &&
      error !== null &&
      "code" in error &&
      (error as { code?: number | string }).code === 6
    ) {
      throw new HttpsError("already-exists", "You have already reviewed this location.");
    }
    throw error;
  }

  return { id: reviewId };
});

export const checkInCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot check in.");
  }

  const data = request.data as {
    locationId?: string;
    photoUrl?: string;
    caption?: string;
    petId?: string;
  };

  if (!data.locationId || typeof data.locationId !== "string") {
    throw new HttpsError("invalid-argument", "Missing locationId.");
  }
  if (!data.photoUrl || typeof data.photoUrl !== "string") {
    throw new HttpsError("invalid-argument", "Missing photoUrl.");
  }
  const photoUrl = requiredTrimmedString(
    data.photoUrl,
    VALIDATION_LIMITS.url,
    "Photo URL"
  );

  const locationRef = db.doc(`locations/${data.locationId}`);
  const locationSnap = await locationRef.get();
  if (!locationSnap.exists) {
    throw new HttpsError("not-found", "Location not found.");
  }

  let petName: string | undefined;
  if (data.petId) {
    const petData = await getAccessiblePet(data.petId, callerUid);
    if (!petData) {
      throw new HttpsError("permission-denied", "You do not have access to this pet.");
    }
    petName =
      typeof petData.name === "string" && petData.name.trim().length > 0
        ? petData.name
        : undefined;
  }

  const dayKey = new Date().toISOString().slice(0, 10);
  const checkinId = `${callerUid}_${dayKey}`;
  const checkinRef = db.doc(`locations/${data.locationId}/checkins/${checkinId}`);

  // Use .create() for atomic "once per user per day" semantics. Two
  // rapid-fire submissions can't both pass an existence check and then
  // overwrite each other.
  try {
    await checkinRef.create({
      userId: callerUid,
      userName: caller.fromUserName,
      userAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
      photoUrl,
      caption: optionalTrimmedString(
        data.caption,
        VALIDATION_LIMITS.checkInCaption,
        "Check-in caption"
      ),
      petId: data.petId,
      petName,
      locationId: data.locationId,
      dayKey,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (error) {
    if (
      typeof error === "object" &&
      error !== null &&
      "code" in error &&
      (error as { code?: number | string }).code === 6
    ) {
      throw new HttpsError("already-exists", "You already checked in here today.");
    }
    throw error;
  }

  return { id: checkinId };
});
