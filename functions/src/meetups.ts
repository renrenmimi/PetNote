import { onDocumentDeleted } from "firebase-functions/v2/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { admin, db } from "./platform";
import { getNotificationActor } from "./notifications";
import { batchChunked, getDefaultAvatar, stripUndefined } from "./shared";
import { getOrCreatePublicMeetupLocation } from "./places";

const allowedMeetupDogSizes = new Set([
  "any",
  "small",
  "medium",
  "large",
  "small_medium",
  "medium_large",
]);

const allowedMeetupPetTypes = new Set([
  "any",
  "dog",
  "cat",
  "any_dog",
  "any_cat",
  "other",
]);

function sanitizeMeetupLocation(value: unknown): {
  name: string;
  address: string;
  lat: number;
  lng: number;
  city?: string;
  state?: string;
} {
  const location =
    value && typeof value === "object"
      ? (value as Record<string, unknown>)
      : {};

  const name = typeof location.name === "string" ? location.name.trim() : "";
  const address =
    typeof location.address === "string" ? location.address.trim() : "";
  const lat = typeof location.lat === "number" ? location.lat : Number.NaN;
  const lng = typeof location.lng === "number" ? location.lng : Number.NaN;

  if (!name || !address || !Number.isFinite(lat) || !Number.isFinite(lng)) {
    throw new HttpsError("invalid-argument", "Meetup location is invalid.");
  }

  const city =
    typeof location.city === "string" && location.city.trim().length > 0
      ? location.city.trim()
      : undefined;
  const state =
    typeof location.state === "string" && location.state.trim().length > 0
      ? location.state.trim()
      : undefined;

  return { name, address, lat, lng, city, state };
}

function toStoredMeetupLocation(location: {
  name: string;
  address: string;
  lat: number;
  lng: number;
  city?: string;
  state?: string;
}): {
  name: string;
  address: string;
  lat: number;
  lng: number;
  city: string;
  state: string;
} {
  return {
    name: location.name,
    address: location.address,
    lat: location.lat,
    lng: location.lng,
    city: location.city || "",
    state: location.state || "",
  };
}

function sanitizeMeetupRequirements(value: unknown): {
  dogSize: string;
  petType: string;
  customPetType?: string;
  maxPets: number;
  mustHavePosts: boolean;
  mustHavePetProfile: boolean;
  minFollowers: number;
  additionalNotes: string;
} {
  const requirements =
    value && typeof value === "object"
      ? (value as Record<string, unknown>)
      : {};

  const dogSize =
    typeof requirements.dogSize === "string" &&
    allowedMeetupDogSizes.has(requirements.dogSize)
      ? requirements.dogSize
      : "any";
  const petType =
    typeof requirements.petType === "string" &&
    allowedMeetupPetTypes.has(requirements.petType)
      ? requirements.petType
      : "any";
  const customPetType =
    petType === "other" &&
    typeof requirements.customPetType === "string" &&
    requirements.customPetType.trim().length > 0
      ? requirements.customPetType.trim()
      : undefined;

  const maxPetsValue =
    typeof requirements.maxPets === "number" && Number.isFinite(requirements.maxPets)
      ? requirements.maxPets
      : 0;
  const minFollowersValue =
    typeof requirements.minFollowers === "number" &&
    Number.isFinite(requirements.minFollowers)
      ? requirements.minFollowers
      : 0;

  return stripUndefined({
    dogSize,
    petType,
    customPetType,
    maxPets: Math.max(0, Math.floor(maxPetsValue)),
    mustHavePosts: requirements.mustHavePosts === true,
    mustHavePetProfile: requirements.mustHavePetProfile === true,
    minFollowers: Math.max(0, Math.floor(minFollowersValue)),
    additionalNotes:
      typeof requirements.additionalNotes === "string"
        ? requirements.additionalNotes.trim()
        : "",
  });
}

export const onParticipantDeleted = onDocumentDeleted(
  "meetups/{meetupId}/participants/{participantId}",
  async (event) => {
    const meetupRef = db.doc(`meetups/${event.params.meetupId}`);
    const meetupSnap = await meetupRef.get();
    if (!meetupSnap.exists) return;
    await meetupRef.update({
      participantCount: admin.firestore.FieldValue.increment(-1),
    });
  }
);

export const createMeetupCallable = onCall(async (request) => {
  const callerAuth = request.auth;
  const callerUid = callerAuth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");
  if (callerAuth.token.email_verified !== true) {
    throw new HttpsError("permission-denied", "Verify your email before creating meetups.");
  }

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot create meetups.");
  }

  const data = request.data as {
    title?: string;
    description?: string;
    coverImage?: string;
    dateMillis?: number;
    duration?: number;
    location?: unknown;
    locationVisibility?: "everyone" | "participants_only";
    requirements?: unknown;
  };

  const title = typeof data.title === "string" ? data.title.trim() : "";
  const description =
    typeof data.description === "string" ? data.description.trim() : "";
  if (!title || !description) {
    throw new HttpsError("invalid-argument", "Meetup title and description are required.");
  }

  const dateMillis =
    typeof data.dateMillis === "number" ? data.dateMillis : Number.NaN;
  if (!Number.isFinite(dateMillis) || dateMillis <= Date.now()) {
    throw new HttpsError("invalid-argument", "Meetup date must be in the future.");
  }

  const duration =
    typeof data.duration === "number" && Number.isFinite(data.duration)
      ? data.duration
      : 60;
  const locationVisibility =
    data.locationVisibility === "everyone" ? "everyone" : "participants_only";
  const location = sanitizeMeetupLocation(data.location);
  const requirements = sanitizeMeetupRequirements(data.requirements);
  const isPrivate = locationVisibility === "participants_only";

  let locationId: string | undefined;
  if (!isPrivate) {
    locationId = await getOrCreatePublicMeetupLocation({
      organizerId: callerUid,
      organizerName: caller.fromUserName,
      location,
    });
  }

  const publicLocation = isPrivate
    ? toStoredMeetupLocation({
        name: location.name,
        address: "",
        lat: 0,
        lng: 0,
        city: location.city,
        state: location.state,
      })
    : toStoredMeetupLocation(location);

  const meetupRef = await db.collection("meetups").add(
    stripUndefined({
      organizerId: callerUid,
      organizerName: caller.fromUserName,
      organizerAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
      title,
      description,
      coverImage:
        typeof data.coverImage === "string" && data.coverImage.trim().length > 0
          ? data.coverImage.trim()
          : undefined,
      date: admin.firestore.Timestamp.fromMillis(dateMillis),
      duration,
      location: publicLocation,
      locationId,
      locationVisibility,
      requirements,
      status: "upcoming",
      participantCount: 0,
      isRatingOpen: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    })
  );

  if (isPrivate) {
    await db.doc(`meetups/${meetupRef.id}/private/address`).set({
      address: location.address,
      lat: location.lat,
      lng: location.lng,
      name: location.name,
      city: location.city || "",
      state: location.state || "",
    });
  }

  return { id: meetupRef.id };
});

export const updateMeetupCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot edit meetups.");
  }

  const data = request.data as {
    meetupId?: string;
    title?: string;
    description?: string;
    coverImage?: string;
    dateMillis?: number;
    duration?: number;
    location?: unknown;
    locationVisibility?: "everyone" | "participants_only";
    requirements?: unknown;
  };

  if (!data.meetupId || typeof data.meetupId !== "string") {
    throw new HttpsError("invalid-argument", "Missing meetupId.");
  }

  const meetupRef = db.doc(`meetups/${data.meetupId}`);
  const meetupSnap = await meetupRef.get();
  if (!meetupSnap.exists) {
    throw new HttpsError("not-found", "Meetup not found.");
  }

  const existing = meetupSnap.data() ?? {};
  const organizerId =
    typeof existing.organizerId === "string" ? existing.organizerId : "";
  if (!organizerId) {
    throw new HttpsError("failed-precondition", "Meetup organizer is missing.");
  }
  if (callerUid !== organizerId && caller.role !== "admin") {
    throw new HttpsError("permission-denied", "Cannot edit this meetup.");
  }

  const title = typeof data.title === "string" ? data.title.trim() : "";
  const description =
    typeof data.description === "string" ? data.description.trim() : "";
  if (!title || !description) {
    throw new HttpsError("invalid-argument", "Meetup title and description are required.");
  }

  const dateMillis =
    typeof data.dateMillis === "number" ? data.dateMillis : Number.NaN;
  if (!Number.isFinite(dateMillis)) {
    throw new HttpsError("invalid-argument", "Meetup date is invalid.");
  }

  const duration =
    typeof data.duration === "number" && Number.isFinite(data.duration)
      ? data.duration
      : 60;
  const locationVisibility =
    data.locationVisibility === "everyone" ? "everyone" : "participants_only";
  const location = sanitizeMeetupLocation(data.location);
  const requirements = sanitizeMeetupRequirements(data.requirements);
  const isPrivate = locationVisibility === "participants_only";
  const organizerActor = await getNotificationActor(organizerId);

  let locationId: string | undefined;
  if (!isPrivate) {
    locationId = await getOrCreatePublicMeetupLocation({
      organizerId,
      organizerName: organizerActor.fromUserName,
      location,
    });
  }

  const publicLocation = isPrivate
    ? toStoredMeetupLocation({
        name: location.name,
        address: "",
        lat: 0,
        lng: 0,
        city: location.city,
        state: location.state,
      })
    : toStoredMeetupLocation(location);

  const updates = stripUndefined({
    title,
    description,
    coverImage:
      typeof data.coverImage === "string" && data.coverImage.trim().length > 0
        ? data.coverImage.trim()
        : undefined,
    date: admin.firestore.Timestamp.fromMillis(dateMillis),
    duration,
    location: publicLocation,
    locationVisibility,
    requirements,
    organizerName: organizerActor.fromUserName,
    organizerAvatar:
      organizerActor.fromUserAvatar || getDefaultAvatar(organizerId),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    ...(isPrivate
      ? { locationId: admin.firestore.FieldValue.delete() }
      : { locationId }),
  });

  await meetupRef.update(updates);

  const privateRef = db.doc(`meetups/${data.meetupId}/private/address`);
  if (isPrivate) {
    await privateRef.set({
      address: location.address,
      lat: location.lat,
      lng: location.lng,
      name: location.name,
      city: location.city || "",
      state: location.state || "",
    });
  } else {
    await privateRef.delete().catch(() => undefined);
  }

  return { success: true };
});

export const cancelMeetupCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot cancel meetups.");
  }

  const { meetupId } = request.data as { meetupId?: string };
  if (!meetupId || typeof meetupId !== "string") {
    throw new HttpsError("invalid-argument", "Missing meetupId.");
  }

  const meetupRef = db.doc(`meetups/${meetupId}`);
  const meetupSnap = await meetupRef.get();
  if (!meetupSnap.exists) {
    throw new HttpsError("not-found", "Meetup not found.");
  }

  const meetupData = meetupSnap.data() ?? {};
  if (meetupData.organizerId !== callerUid && caller.role !== "admin") {
    throw new HttpsError("permission-denied", "Cannot cancel this meetup.");
  }

  await meetupRef.update({
    status: "cancelled",
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { success: true };
});

export const joinMeetupCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot join meetups.");
  }

  const { meetupId, petId } = request.data as {
    meetupId: string; petId?: string;
  };

  const meetupRef = db.doc(`meetups/${meetupId}`);
  const participantRef = db.doc(`meetups/${meetupId}/participants/${callerUid}`);

  return await db.runTransaction(async (t) => {
    const meetupSnap = await t.get(meetupRef);
    if (!meetupSnap.exists) throw new HttpsError("not-found", "Meetup not found.");
    const meetup = meetupSnap.data() as Record<string, unknown>;

    const participantSnap = await t.get(participantRef);
    if (participantSnap.exists) return { success: true };

    if (meetup.status === "cancelled" || meetup.status === "completed") {
      return { success: false, error: "Meetup is no longer accepting participants." };
    }

    const requirements = meetup.requirements as Record<string, unknown> ?? {};
    const isOrganizer = meetup.organizerId === callerUid;
    const maxPets = typeof requirements.maxPets === "number" ? requirements.maxPets : 0;
    const currentCount = typeof meetup.participantCount === "number" ? meetup.participantCount : 0;
    if (maxPets > 0 && currentCount >= maxPets) {
      return { success: false, error: "Meetup is full." };
    }

    let participantPetId = "";
    let participantPetName = "Organizer";
    let participantPetAvatar = getDefaultAvatar(callerUid);
    let participantPetSpecies: string | undefined;

    if (petId) {
      const petRef = db.doc(`pets/${petId}`);
      const familyRef = db.doc(`pets/${petId}/family/${callerUid}`);
      const [petSnap, familySnap] = await Promise.all([t.get(petRef), t.get(familyRef)]);
      if (!petSnap.exists) {
        throw new HttpsError("not-found", "Pet not found.");
      }
      const petData = petSnap.data() ?? {};
      const canAccess =
        petData.ownerId === callerUid ||
        petData.primaryOwnerId === callerUid ||
        familySnap.exists;
      if (!canAccess) {
        throw new HttpsError("permission-denied", "You do not have access to this pet.");
      }
      participantPetId = petId;
      participantPetName =
        typeof petData.name === "string" && petData.name.trim().length > 0
          ? petData.name
          : "Pet";
      participantPetAvatar =
        typeof petData.avatarUrl === "string" && petData.avatarUrl.trim().length > 0
          ? petData.avatarUrl
          : getDefaultAvatar(petId);
      participantPetSpecies =
        typeof petData.species === "string" ? petData.species : undefined;
    } else if (!isOrganizer) {
      return { success: false, error: "Select a pet to join this meetup." };
    }

    if (!isOrganizer) {
      const reasons: string[] = [];
      const minFollowers =
        typeof requirements.minFollowers === "number" ? requirements.minFollowers : 0;

      // Requirement reads must run through the transaction so the snapshot
      // is locked against concurrent writes (new posts, unfollows, etc.).
      // Run them in parallel but all before any write.
      const [postsSnap, followingSnap] = await Promise.all([
        requirements.mustHavePosts
          ? t.get(db.collection("posts").where("authorId", "==", callerUid).limit(1))
          : Promise.resolve(null),
        minFollowers > 0
          ? t.get(db.collection(`users/${callerUid}/followingPets`))
          : Promise.resolve(null),
      ]);

      if (requirements.mustHavePosts && postsSnap && postsSnap.empty) {
        reasons.push("Must have posted at least once.");
      }

      if (requirements.mustHavePetProfile && !participantPetSpecies) {
        reasons.push("Must have a pet profile.");
      }

      if (minFollowers > 0 && followingSnap && followingSnap.size < minFollowers) {
        reasons.push(`Requires at least ${minFollowers} followed pets.`);
      }

      const petType = requirements.petType as string ?? "any";
      if ((petType === "dog" || petType === "any_dog") && participantPetSpecies && participantPetSpecies !== "dog") {
        reasons.push("Dogs only.");
      }
      if ((petType === "cat" || petType === "any_cat") && participantPetSpecies && participantPetSpecies !== "cat") {
        reasons.push("Cats only.");
      }
      if (petType === "other" && participantPetSpecies && (participantPetSpecies === "dog" || participantPetSpecies === "cat")) {
        reasons.push("Other pets only.");
      }

      if (reasons.length > 0) {
        return { success: false, error: reasons.join(" ") };
      }
    }

    const actor = await getNotificationActor(callerUid);

    t.set(participantRef, {
      meetupId,
      userId: callerUid,
      userName: actor.fromUserName,
      userAvatar: actor.fromUserAvatar || getDefaultAvatar(callerUid),
      petId: participantPetId,
      petName: participantPetName,
      petAvatar: participantPetAvatar,
      joinedAt: admin.firestore.FieldValue.serverTimestamp(),
      status: "confirmed",
    });
    t.update(meetupRef, {
      participantCount: admin.firestore.FieldValue.increment(1),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { success: true };
  });
});

// Flip expired meetups to "completed" even when no user visits the detail
// page. Previously the status only advanced when a client called
// checkMeetupStatusCallable, so quiet meetups stayed "upcoming" forever
// and review submission stayed blocked.
export const autoCompleteMeetups = onSchedule("every 15 minutes", async () => {
  const now = Date.now();
  const nowTimestamp = admin.firestore.Timestamp.fromMillis(now);
  const snapshot = await db
    .collection("meetups")
    .where("status", "in", ["upcoming", "ongoing"])
    .where("date", "<=", nowTimestamp)
    .orderBy("date", "asc")
    .limit(200)
    .get();

  const expired = snapshot.docs.filter((docSnap) => {
    const data = docSnap.data();
    if (!(data.date instanceof admin.firestore.Timestamp)) return false;
    const duration = typeof data.duration === "number" ? data.duration : 0;
    const endMillis = data.date.toMillis() + duration * 60 * 1000;
    return now >= endMillis;
  });

  if (expired.length === 0) return;

  await batchChunked(expired, (batch, docSnap) => {
    batch.update(docSnap.ref, {
      status: "completed",
      isRatingOpen: true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
});

export const checkMeetupStatusCallable = onCall(async (request) => {
  if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const { meetupId } = request.data as { meetupId: string };
  if (!meetupId) throw new HttpsError("invalid-argument", "Missing meetupId.");

  const meetupRef = db.doc(`meetups/${meetupId}`);
  const meetupSnap = await meetupRef.get();
  if (!meetupSnap.exists) return { updated: false };

  const meetup = meetupSnap.data() as Record<string, unknown>;
  if (meetup.status === "cancelled" || meetup.status === "completed") {
    return { updated: false };
  }

  const dateVal = meetup.date as admin.firestore.Timestamp;
  if (!dateVal?.toDate) return { updated: false };
  const duration = typeof meetup.duration === "number" ? meetup.duration : 0;
  const endTime = new Date(dateVal.toDate().getTime() + duration * 60 * 1000);

  if (new Date() >= endTime) {
    await meetupRef.update({
      status: "completed",
      isRatingOpen: true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { updated: true };
  }
  return { updated: false };
});
