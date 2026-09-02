import { onDocumentDeleted } from "firebase-functions/v2/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { admin, db } from "./platform";
import { assertActorNotDeleting, getNotificationActor } from "./notifications";
import {
  assertRateLimit,
  batchChunked,
  getDefaultAvatar,
  optionalTrimmedString,
  optionalTrustedHttpsUrl,
  RATE_LIMITS,
  requestData,
  requiredDocId,
  requiredTrimmedString,
  runEventOnce,
  stripUndefined,
  TRUSTED_MEDIA_URL_HOSTS,
  validateCoordinateRange,
  VALIDATION_LIMITS,
  wasCountedAtCreate,
} from "./shared";
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

// Clamp to a sane range (5 min – 24 h): a negative or absurd duration keeps
// the meetup permanently "upcoming" with date <= now, occupying the
// autoCompleteMeetups scan window forever.
function normalizeMeetupDuration(value: unknown): number {
  const raw =
    typeof value === "number" && Number.isFinite(value) ? value : 60;
  return Math.min(1440, Math.max(5, Math.round(raw)));
}

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

  const name = requiredTrimmedString(
    location.name,
    VALIDATION_LIMITS.placeName,
    "Location name"
  );
  const address = requiredTrimmedString(
    location.address,
    VALIDATION_LIMITS.address,
    "Location address"
  );
  const lat = typeof location.lat === "number" ? location.lat : Number.NaN;
  const lng = typeof location.lng === "number" ? location.lng : Number.NaN;

  if (!validateCoordinateRange(lat, lng)) {
    throw new HttpsError("invalid-argument", "Meetup location is invalid.");
  }

  const city =
    optionalTrimmedString(location.city, VALIDATION_LIMITS.city, "City") ||
    undefined;
  const state =
    optionalTrimmedString(location.state, VALIDATION_LIMITS.state, "State") ||
    undefined;

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
      ? optionalTrimmedString(
          requirements.customPetType,
          VALIDATION_LIMITS.meetupCustomPetType,
          "Custom pet type"
        )
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
        ? optionalTrimmedString(
            requirements.additionalNotes,
            VALIDATION_LIMITS.meetupAdditionalNotes,
            "Additional notes"
          )
        : "",
  });
}

export const onParticipantDeleted = onDocumentDeleted(
  "meetups/{meetupId}/participants/{participantId}",
  async (event) => {
    const meetupRef = db.doc(`meetups/${event.params.meetupId}`);
    // participantCount is incremented by the callable that writes the
    // participant, inside the same transaction, so every participant that code
    // created is stamped counted:true and there is nothing to reconcile here.
    if (!wasCountedAtCreate(event.data?.data())) return;

    await runEventOnce(event.id, async (t) => {
      const meetupSnap = await t.get(meetupRef);
      if (!meetupSnap.exists) return false;
      t.update(meetupRef, {
        participantCount: admin.firestore.FieldValue.increment(-1),
      });
      return true;
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
  assertActorNotDeleting(caller);
  await assertRateLimit(callerUid, "createMeetup", RATE_LIMITS.strictWrite);

  const data = requestData(request.data) as {
    title?: string;
    description?: string;
    coverImage?: string;
    dateMillis?: number;
    duration?: number;
    location?: unknown;
    locationVisibility?: "everyone" | "participants_only";
    requirements?: unknown;
    // Optional: include the organizer's chosen pet so this callable can
    // create the organizer participant doc atomically with the meetup
    // itself. Without it, the client used to issue a follow-up join call
    // and a failure between the two left a meetup with no organizer in
    // its participants subcollection.
    organizerPetId?: string;
  };

  const title = requiredTrimmedString(
    data.title,
    VALIDATION_LIMITS.meetupTitle,
    "Meetup title"
  );
  const description = requiredTrimmedString(
    data.description,
    VALIDATION_LIMITS.meetupDescription,
    "Meetup description"
  );

  const dateMillis =
    typeof data.dateMillis === "number" ? data.dateMillis : Number.NaN;
  if (!Number.isFinite(dateMillis) || dateMillis <= Date.now()) {
    throw new HttpsError("invalid-argument", "Meetup date must be in the future.");
  }

  const duration = normalizeMeetupDuration(data.duration);
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

  // Resolve the organizer's pet info up front so the main doc, the
  // private/address doc, and the organizer participant doc all commit
  // in the same batch. The previous flow ran createMeetupCallable
  // followed by a separate joinMeetupCallable from the client — if the
  // second call failed (tab closed, network drop, callable cold start
  // hiccup), the meetup existed in Firestore with participantCount=0
  // and no organizer in /participants, breaking the detail page.
  let organizerPetId = "";
  let organizerPetName = "Organizer";
  let organizerPetAvatar = getDefaultAvatar(callerUid);
  if (
    typeof data.organizerPetId === "string" &&
    data.organizerPetId.trim().length > 0
  ) {
    // requiredDocId keeps the slash-injection invariant every other pet
    // path enforces (a "x/family/y" value would retarget petRef/familyRef).
    const petId = requiredDocId(data.organizerPetId, "organizerPetId");
    const petRef = db.doc(`pets/${petId}`);
    const familyRef = db.doc(`pets/${petId}/family/${callerUid}`);
    const [petSnap, familySnap] = await Promise.all([
      petRef.get(),
      familyRef.get(),
    ]);
    if (!petSnap.exists) {
      throw new HttpsError("not-found", "Selected pet not found.");
    }
    const petData = petSnap.data() ?? {};
    const canAccess =
      petData.ownerId === callerUid ||
      petData.primaryOwnerId === callerUid ||
      familySnap.exists;
    if (!canAccess) {
      throw new HttpsError(
        "permission-denied",
        "You do not have access to this pet."
      );
    }
    organizerPetId = petId;
    organizerPetName =
      typeof petData.name === "string" && petData.name.trim().length > 0
        ? petData.name
        : "Pet";
    organizerPetAvatar =
      typeof petData.avatarUrl === "string" && petData.avatarUrl.trim().length > 0
        ? petData.avatarUrl
        : getDefaultAvatar(petId);
  }

  // Pre-allocate the meetup id so the main doc, the private/address doc,
  // and the organizer participant doc commit atomically in one batch.
  const meetupRef = db.collection("meetups").doc();
  const batch = db.batch();
  batch.set(
    meetupRef,
    stripUndefined({
      organizerId: callerUid,
      organizerName: caller.fromUserName,
      organizerAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
      title,
      description,
      coverImage:
        typeof data.coverImage === "string" && data.coverImage.trim().length > 0
          ? optionalTrustedHttpsUrl(
              data.coverImage,
              VALIDATION_LIMITS.url,
              "Cover image URL",
              TRUSTED_MEDIA_URL_HOSTS
            )
          : undefined,
      date: admin.firestore.Timestamp.fromMillis(dateMillis),
      duration,
      location: publicLocation,
      locationId,
      locationVisibility,
      requirements,
      status: "upcoming",
      // Seed participantCount with 1 because the organizer participant
      // is being created in the same batch.
      participantCount: 1,
      isRatingOpen: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    })
  );

  if (isPrivate) {
    batch.set(db.doc(`meetups/${meetupRef.id}/private/address`), {
      address: location.address,
      lat: location.lat,
      lng: location.lng,
      name: location.name,
      city: location.city || "",
      state: location.state || "",
    });
  }

  batch.set(
    db.doc(`meetups/${meetupRef.id}/participants/${callerUid}`),
    {
      meetupId: meetupRef.id,
      userId: callerUid,
      userName: caller.fromUserName,
      userAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
      petId: organizerPetId,
      petName: organizerPetName,
      petAvatar: organizerPetAvatar,
      joinedAt: admin.firestore.FieldValue.serverTimestamp(),
      status: "confirmed",
      // participantCount is seeded to 1 for this organizer in the same batch,
      // so the count is already applied. Stamping it lets onParticipantDeleted
      // tell an accounted-for participant from one it must not subtract.
      counted: true,
    }
  );

  await batch.commit();

  return { id: meetupRef.id };
});

export const updateMeetupCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot edit meetups.");
  }
  assertActorNotDeleting(caller);
  await assertRateLimit(callerUid, "updateMeetup", RATE_LIMITS.write);

  const data = requestData(request.data) as {
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

  const meetupId = requiredDocId(data.meetupId, "meetupId");

  const meetupRef = db.doc(`meetups/${meetupId}`);
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

  const title = requiredTrimmedString(
    data.title,
    VALIDATION_LIMITS.meetupTitle,
    "Meetup title"
  );
  const description = requiredTrimmedString(
    data.description,
    VALIDATION_LIMITS.meetupDescription,
    "Meetup description"
  );

  const dateMillis =
    typeof data.dateMillis === "number" ? data.dateMillis : Number.NaN;
  // Same rule as create: a past date would flip the meetup straight to
  // "completed" on the next status check.
  if (!Number.isFinite(dateMillis) || dateMillis <= Date.now()) {
    throw new HttpsError("invalid-argument", "Meetup date must be in the future.");
  }

  const duration = normalizeMeetupDuration(data.duration);
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
        ? optionalTrustedHttpsUrl(
            data.coverImage,
            VALIDATION_LIMITS.url,
            "Cover image URL",
            TRUSTED_MEDIA_URL_HOSTS
          )
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

  // Atomic update: main doc and private/address subdoc commit together so a
  // visibility flip can't leave the data in a half-applied state.
  const privateRef = db.doc(`meetups/${meetupId}/private/address`);
  const batch = db.batch();
  batch.update(meetupRef, updates);
  if (isPrivate) {
    batch.set(privateRef, {
      address: location.address,
      lat: location.lat,
      lng: location.lng,
      name: location.name,
      city: location.city || "",
      state: location.state || "",
    });
  } else {
    // batch.delete is a no-op if the doc doesn't exist, so we don't need
    // the previous .catch(() => undefined) error swallowing.
    batch.delete(privateRef);
  }
  await batch.commit();

  return { success: true };
});

export const cancelMeetupCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot cancel meetups.");
  }
  assertActorNotDeleting(caller);
  await assertRateLimit(callerUid, "cancelMeetup", RATE_LIMITS.write);

  const { meetupId: rawCancelMeetupId } = requestData(request.data) as {
    meetupId?: string;
  };
  const meetupId = requiredDocId(rawCancelMeetupId, "meetupId");

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
  assertActorNotDeleting(caller);
  await assertRateLimit(callerUid, "joinMeetup", RATE_LIMITS.write);

  const { meetupId: rawMeetupId, petId: rawPetId } = requestData(request.data) as {
    meetupId?: string;
    petId?: string;
  };
  const meetupId = requiredDocId(rawMeetupId, "meetupId");
  // petId is optional (organizers can join without a pet) so only
  // validate when supplied.
  const petId =
    typeof rawPetId === "string" && rawPetId.trim().length > 0
      ? requiredDocId(rawPetId, "petId")
      : undefined;

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
      //
      // The followers count comes from users/{uid}.followingPetsCount
      // (kept in sync by the onPetFollowed/onPetUnfollowed triggers)
      // instead of pulling the entire followingPets subcollection. The
      // old version read every follow doc just to count them, which
      // both wasted reads and started failing for power users once
      // their follow count crossed the Firestore transaction read cap.
      const [postsSnap, callerProfileSnap] = await Promise.all([
        requirements.mustHavePosts
          ? t.get(db.collection("posts").where("authorId", "==", callerUid).limit(1))
          : Promise.resolve(null),
        minFollowers > 0
          ? t.get(db.doc(`users/${callerUid}`))
          : Promise.resolve(null),
      ]);

      if (requirements.mustHavePosts && postsSnap && postsSnap.empty) {
        reasons.push("Must have posted at least once.");
      }

      if (requirements.mustHavePetProfile && !participantPetSpecies) {
        reasons.push("Must have a pet profile.");
      }

      if (minFollowers > 0 && callerProfileSnap) {
        const profileData = callerProfileSnap.exists
          ? callerProfileSnap.data() ?? {}
          : {};
        const followingPetsCount =
          typeof profileData.followingPetsCount === "number"
            ? profileData.followingPetsCount
            : 0;
        if (followingPetsCount < minFollowers) {
          reasons.push(`Requires at least ${minFollowers} followed pets.`);
        }
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

    // Reuse the pre-transaction caller actor instead of re-reading inside
    // the transaction. participant display fields (userName, userAvatar)
    // are denormalized snapshots — onUserUpdated trigger keeps them in
    // sync with the user doc, so a tiny window of staleness is acceptable
    // and saves a redundant read on every join.
    t.set(participantRef, {
      meetupId,
      userId: callerUid,
      userName: caller.fromUserName,
      userAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
      petId: participantPetId,
      petName: participantPetName,
      petAvatar: participantPetAvatar,
      joinedAt: admin.firestore.FieldValue.serverTimestamp(),
      status: "confirmed",
      // Written in the same transaction as the increment below, so the stamp
      // and the count can never disagree.
      counted: true,
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
    .where("status", "==", "upcoming")
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
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");
  await assertRateLimit(callerUid, "checkMeetupStatus", RATE_LIMITS.read);

  const { meetupId: rawCheckMeetupId } = requestData(request.data) as {
    meetupId?: string;
  };
  const meetupId = requiredDocId(rawCheckMeetupId, "meetupId");

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
