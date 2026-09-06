import { onCall, HttpsError } from "firebase-functions/v2/https";
import { admin, db, CLOUDINARY_CLOUD_NAME } from "./platform";
import { cascadeDeletePet } from "./cleanup";
import { assertActorNotDeleting, getNotificationActor } from "./notifications";
import {
  assertRateLimit,
  getDefaultAvatar,
  optionalTrimmedString,
  optionalTrustedHttpsUrl,
  RATE_LIMITS,
  requestData,
  requiredDocId,
  stripUndefined,
  TRUSTED_AVATAR_URL_HOSTS,
  VALIDATION_LIMITS,
} from "./shared";

const allowedPetSpecies = new Set([
  "dog",
  "cat",
  "bird",
  "rabbit",
  "hamster",
  "fish",
  "reptile",
  "other",
]);

const allowedPetGenders = new Set(["male", "female", "unknown"]);

const allowedPetRelationships = new Set([
  "mom",
  "dad",
  "brother",
  "sister",
  "grandma",
  "grandpa",
  "auntie",
  "uncle",
  "best_friend",
  "caretaker",
  "other",
]);

function timestampFromMillis(value: unknown): admin.firestore.Timestamp | null {
  return typeof value === "number" && Number.isFinite(value)
    ? admin.firestore.Timestamp.fromMillis(value)
    : null;
}

// Pets store both a legacy birthday Timestamp (for "Born: <date>" display)
// and a canonical month/day pair so isBirthdayToday is timezone-safe. Client
// passes either explicit { birthdayMonth, birthdayDay } or birthdayMillis;
// from millis we derive month/day in UTC, which still beats comparing two
// timestamps in mixed timezones.
function deriveBirthdayMonthDay(
  data: Record<string, unknown>,
  birthday: admin.firestore.Timestamp | null
): { birthdayMonth?: number; birthdayDay?: number } {
  const explicitMonth =
    typeof data.birthdayMonth === "number" && Number.isFinite(data.birthdayMonth)
      ? Math.floor(data.birthdayMonth)
      : null;
  const explicitDay =
    typeof data.birthdayDay === "number" && Number.isFinite(data.birthdayDay)
      ? Math.floor(data.birthdayDay)
      : null;
  if (
    explicitMonth !== null &&
    explicitDay !== null &&
    explicitMonth >= 1 &&
    explicitMonth <= 12 &&
    explicitDay >= 1 &&
    explicitDay <= 31
  ) {
    return { birthdayMonth: explicitMonth, birthdayDay: explicitDay };
  }
  if (birthday) {
    const date = birthday.toDate();
    return {
      birthdayMonth: date.getUTCMonth() + 1,
      birthdayDay: date.getUTCDate(),
    };
  }
  return {};
}

function sanitizePetRelationship(value: unknown, customValue: unknown): {
  relationship: string;
  customRelationship?: string;
} {
  const relationship =
    typeof value === "string" && allowedPetRelationships.has(value) ? value : "other";
  const customRelationship =
    relationship === "other" &&
    typeof customValue === "string" &&
    customValue.trim().length > 0
      ? optionalTrimmedString(
          customValue,
          VALIDATION_LIMITS.petCustomRelationship,
          "Custom relationship"
        )
      : undefined;
  return { relationship, customRelationship };
}

function sanitizePetDraft(value: unknown): {
  name: string;
  nameLower: string;
  species: string;
  breed: string;
  birthday?: admin.firestore.Timestamp;
  birthdayMonth?: number;
  birthdayDay?: number;
  gender: string;
  bio: string;
  avatarUrl: string;
} {
  const data =
    value && typeof value === "object" ? (value as Record<string, unknown>) : {};

  const name = typeof data.name === "string" ? data.name.trim() : "";
  if (name.length < 2 || name.length > VALIDATION_LIMITS.petName) {
    throw new HttpsError("invalid-argument", "Pet name must be between 2 and 20 characters.");
  }

  const species =
    typeof data.species === "string" && allowedPetSpecies.has(data.species)
      ? data.species
      : null;
  if (!species) {
    throw new HttpsError("invalid-argument", "Pet species is invalid.");
  }

  const gender =
    typeof data.gender === "string" && allowedPetGenders.has(data.gender)
      ? data.gender
      : "unknown";
  const breed = optionalTrimmedString(
    data.breed,
    VALIDATION_LIMITS.petBreed,
    "Pet breed"
  );
  const bio = optionalTrimmedString(data.bio, VALIDATION_LIMITS.bio, "Pet bio");
  const avatarUrl = optionalTrustedHttpsUrl(
    data.avatarUrl,
    VALIDATION_LIMITS.url,
    "Pet avatar URL",
    TRUSTED_AVATAR_URL_HOSTS
  );
  const birthday = timestampFromMillis(data.birthdayMillis);
  const { birthdayMonth, birthdayDay } = deriveBirthdayMonthDay(data, birthday);

  return stripUndefined({
    name,
    nameLower: name.toLowerCase(),
    species,
    breed,
    birthday: birthday ?? undefined,
    birthdayMonth,
    birthdayDay,
    gender,
    bio,
    avatarUrl,
  });
}

export async function getAccessiblePet(
  petId: string,
  userId: string
): Promise<admin.firestore.DocumentData | null> {
  // Validate the path segments here as defense in depth — every callable
  // already passes through requiredDocId, but a future entry point that
  // forgets shouldn't be able to silently retarget the doc through "/"
  // tricks because Firestore's path parser treats "abc/family/xyz" as a
  // valid 4-segment path.
  const safePetId = requiredDocId(petId, "petId");
  const safeUserId = requiredDocId(userId, "userId");
  const petRef = db.doc(`pets/${safePetId}`);
  const familyRef = db.doc(`pets/${safePetId}/family/${safeUserId}`);
  const [petSnap, familySnap] = await Promise.all([petRef.get(), familyRef.get()]);
  if (!petSnap.exists) return null;
  const petData = petSnap.data() ?? {};
  const canAccess =
    petData.ownerId === safeUserId ||
    petData.primaryOwnerId === safeUserId ||
    familySnap.exists;
  return canAccess ? petData : null;
}

export const createPetCallable = onCall(
  // Binds the cloud name so validateTrustedHttpsUrl can confirm a
  // res.cloudinary.com url is OUR asset and not a free account someone
  // else controls. Without it the validator throws rather than degrade.
  { secrets: [CLOUDINARY_CLOUD_NAME] },
  async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot create pets.");
  }
  assertActorNotDeleting(caller);
  await assertRateLimit(callerUid, "createPet", RATE_LIMITS.strictWrite);

  const data = requestData(request.data);
  const payload = sanitizePetDraft(data);
  const relationshipData = sanitizePetRelationship(
    data.relationship,
    data.customRelationship
  );

  const petRef = db.collection("pets").doc();
  const familyRef = db.doc(`pets/${petRef.id}/family/${callerUid}`);

  // Count + create inside one transaction so two concurrent creations can't
  // both read "4 pets" and then each write a 5th, silently exceeding the cap.
  await db.runTransaction(async (t) => {
    const existingPetsSnap = await t.get(
      db.collection("pets").where("ownerId", "==", callerUid).limit(6)
    );
    if (existingPetsSnap.size >= 5) {
      throw new HttpsError("failed-precondition", "Maximum 5 pets allowed.");
    }

    t.set(
      petRef,
      stripUndefined({
        ...payload,
        ownerId: callerUid,
        primaryOwnerId: callerUid,
        followerCount: 0,
        postCount: 0,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      })
    );
    t.set(
      familyRef,
      stripUndefined({
        userId: callerUid,
        userName: caller.fromUserName,
        userAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
        relationship: relationshipData.relationship,
        customRelationship: relationshipData.customRelationship,
        role: "primary",
        joinedAt: admin.firestore.FieldValue.serverTimestamp(),
      })
    );
  });

  return { id: petRef.id };
});

export const updatePetCallable = onCall(
  // Binds the cloud name so validateTrustedHttpsUrl can confirm a
  // res.cloudinary.com url is OUR asset and not a free account someone
  // else controls. Without it the validator throws rather than degrade.
  { secrets: [CLOUDINARY_CLOUD_NAME] },
  async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot update pets.");
  }
  assertActorNotDeleting(caller);
  await assertRateLimit(callerUid, "updatePet", RATE_LIMITS.write);

  const { petId: rawUpdatePetId, ...rawUpdates } = requestData(
    request.data
  ) as {
    petId?: string;
  } & Record<string, unknown>;
  const petId = requiredDocId(rawUpdatePetId, "petId");

  const petRef = db.doc(`pets/${petId}`);
  const petSnap = await petRef.get();
  if (!petSnap.exists) {
    throw new HttpsError("not-found", "Pet not found.");
  }
  const petData = petSnap.data() ?? {};
  const canUpdate =
    petData.ownerId === callerUid || petData.primaryOwnerId === callerUid || caller.role === "admin";
  if (!canUpdate) {
    throw new HttpsError("permission-denied", "Cannot update this pet.");
  }

  const updates: Record<string, unknown> = {};
  if ("name" in rawUpdates) {
    const name = typeof rawUpdates.name === "string" ? rawUpdates.name.trim() : "";
    if (name.length < 2 || name.length > VALIDATION_LIMITS.petName) {
      throw new HttpsError("invalid-argument", "Pet name must be between 2 and 20 characters.");
    }
    updates.name = name;
    updates.nameLower = name.toLowerCase();
  }
  if ("species" in rawUpdates) {
    if (
      typeof rawUpdates.species !== "string" ||
      !allowedPetSpecies.has(rawUpdates.species)
    ) {
      throw new HttpsError("invalid-argument", "Pet species is invalid.");
    }
    updates.species = rawUpdates.species;
  }
  if ("breed" in rawUpdates) {
    updates.breed = optionalTrimmedString(
      rawUpdates.breed,
      VALIDATION_LIMITS.petBreed,
      "Pet breed"
    );
  }
  if ("gender" in rawUpdates) {
    if (
      typeof rawUpdates.gender !== "string" ||
      !allowedPetGenders.has(rawUpdates.gender)
    ) {
      throw new HttpsError("invalid-argument", "Pet gender is invalid.");
    }
    updates.gender = rawUpdates.gender;
  }
  if ("bio" in rawUpdates) {
    updates.bio = optionalTrimmedString(
      rawUpdates.bio,
      VALIDATION_LIMITS.bio,
      "Pet bio"
    );
  }
  if ("avatarUrl" in rawUpdates) {
    updates.avatarUrl = optionalTrustedHttpsUrl(
      rawUpdates.avatarUrl,
      VALIDATION_LIMITS.url,
      "Pet avatar URL",
      TRUSTED_AVATAR_URL_HOSTS
    );
  }
  if (
    "birthdayMillis" in rawUpdates ||
    "birthdayMonth" in rawUpdates ||
    "birthdayDay" in rawUpdates
  ) {
    const birthday = timestampFromMillis(rawUpdates.birthdayMillis);
    updates.birthday = birthday ?? admin.firestore.FieldValue.delete();
    const { birthdayMonth, birthdayDay } = deriveBirthdayMonthDay(
      rawUpdates,
      birthday
    );
    updates.birthdayMonth =
      birthdayMonth ?? admin.firestore.FieldValue.delete();
    updates.birthdayDay = birthdayDay ?? admin.firestore.FieldValue.delete();
  }

  if (Object.keys(updates).length === 0) {
    throw new HttpsError("invalid-argument", "No supported pet fields provided.");
  }

  await petRef.set(stripUndefined(updates), { merge: true });
  return { success: true };
});

export const deletePetCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot delete pets.");
  }
  assertActorNotDeleting(caller);
  await assertRateLimit(callerUid, "deletePet", RATE_LIMITS.write);

  const { petId: rawDeletePetId } = requestData(request.data) as {
    petId?: string;
  };
  const petId = requiredDocId(rawDeletePetId, "petId");

  const petRef = db.doc(`pets/${petId}`);
  const petSnap = await petRef.get();
  if (!petSnap.exists) {
    return { success: true };
  }
  const petData = petSnap.data() ?? {};
  const canDelete =
    petData.ownerId === callerUid ||
    petData.primaryOwnerId === callerUid ||
    caller.role === "admin";
  if (!canDelete) {
    throw new HttpsError("permission-denied", "Cannot delete this pet.");
  }

  await cascadeDeletePet(petId);
  return { success: true };
});

export const followPetCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot follow pets.");
  }
  assertActorNotDeleting(caller);
  await assertRateLimit(callerUid, "followPet", RATE_LIMITS.write);

  const { petId: rawFollowPetId } = requestData(request.data) as {
    petId?: string;
  };
  const petId = requiredDocId(rawFollowPetId, "petId");

  const petRef = db.doc(`pets/${petId}`);
  const followingRef = db.doc(`users/${callerUid}/followingPets/${petId}`);
  const familyRef = db.doc(`pets/${petId}/family/${callerUid}`);

  await db.runTransaction(async (t) => {
    const [petSnap, followingSnap, familySnap] = await Promise.all([
      t.get(petRef),
      t.get(followingRef),
      t.get(familyRef),
    ]);
    if (!petSnap.exists) {
      throw new HttpsError("not-found", "Pet not found.");
    }
    const petData = petSnap.data() ?? {};
    // Can't follow a pet you own or co-parent — it would inflate
    // followerCount / followingPetsCount. The UI hides the button; the
    // callable enforces it.
    if (
      petData.ownerId === callerUid ||
      petData.primaryOwnerId === callerUid ||
      familySnap.exists
    ) {
      throw new HttpsError("failed-precondition", "You can't follow your own pet.");
    }
    if (followingSnap.exists) return;

    t.set(followingRef, {
      petId,
      petName:
        typeof petData.name === "string" && petData.name.trim().length > 0
          ? petData.name
          : "Pet",
      petAvatar:
        typeof petData.avatarUrl === "string" && petData.avatarUrl.trim().length > 0
          ? petData.avatarUrl
          : getDefaultAvatar(petId),
      followedAt: admin.firestore.FieldValue.serverTimestamp(),
      // onFollowingPetCreated flips this to true in the same transaction as
      // the followerCount / followingPetsCount increments, so an unfollow that
      // overtakes the follow knows there is nothing to subtract.
      counted: false,
    });
  });

  return { success: true };
});

export const unfollowPetCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot unfollow pets.");
  }
  assertActorNotDeleting(caller);
  await assertRateLimit(callerUid, "unfollowPet", RATE_LIMITS.write);

  const { petId: rawUnfollowPetId } = requestData(request.data) as {
    petId?: string;
  };
  const petId = requiredDocId(rawUnfollowPetId, "petId");

  const followingRef = db.doc(`users/${callerUid}/followingPets/${petId}`);
  const followingSnap = await followingRef.get();
  if (followingSnap.exists) {
    await followingRef.delete();
  }
  return { success: true };
});
