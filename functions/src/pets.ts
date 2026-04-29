import { onCall, HttpsError } from "firebase-functions/v2/https";
import { admin, db } from "./platform";
import { cascadeDeletePet } from "./cleanup";
import { getNotificationActor } from "./notifications";
import { getDefaultAvatar, stripUndefined } from "./shared";

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
      ? customValue.trim().slice(0, 30)
      : undefined;
  return { relationship, customRelationship };
}

function sanitizePetDraft(value: unknown): {
  name: string;
  nameLower: string;
  species: string;
  breed: string;
  birthday?: admin.firestore.Timestamp;
  gender: string;
  bio: string;
  avatarUrl: string;
} {
  const data =
    value && typeof value === "object" ? (value as Record<string, unknown>) : {};

  const name = typeof data.name === "string" ? data.name.trim() : "";
  if (name.length < 2 || name.length > 20) {
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
  const breed = typeof data.breed === "string" ? data.breed.trim() : "";
  const bio = typeof data.bio === "string" ? data.bio.trim().slice(0, 150) : "";
  const avatarUrl = typeof data.avatarUrl === "string" ? data.avatarUrl.trim() : "";
  const birthday = timestampFromMillis(data.birthdayMillis);

  return stripUndefined({
    name,
    nameLower: name.toLowerCase(),
    species,
    breed,
    birthday: birthday ?? undefined,
    gender,
    bio,
    avatarUrl,
  });
}

export async function getAccessiblePet(
  petId: string,
  userId: string
): Promise<admin.firestore.DocumentData | null> {
  const petRef = db.doc(`pets/${petId}`);
  const familyRef = db.doc(`pets/${petId}/family/${userId}`);
  const [petSnap, familySnap] = await Promise.all([petRef.get(), familyRef.get()]);
  if (!petSnap.exists) return null;
  const petData = petSnap.data() ?? {};
  const canAccess =
    petData.ownerId === userId ||
    petData.primaryOwnerId === userId ||
    familySnap.exists;
  return canAccess ? petData : null;
}

export const createPetCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot create pets.");
  }

  const payload = sanitizePetDraft(request.data);
  const relationshipData = sanitizePetRelationship(
    (request.data as { relationship?: unknown }).relationship,
    (request.data as { customRelationship?: unknown }).customRelationship
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

export const updatePetCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot update pets.");
  }

  const { petId, ...rawUpdates } = request.data as { petId?: string } & Record<string, unknown>;
  if (!petId || typeof petId !== "string") {
    throw new HttpsError("invalid-argument", "Missing petId.");
  }

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
    if (name.length < 2 || name.length > 20) {
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
    updates.breed = typeof rawUpdates.breed === "string" ? rawUpdates.breed.trim() : "";
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
    updates.bio = typeof rawUpdates.bio === "string" ? rawUpdates.bio.trim().slice(0, 150) : "";
  }
  if ("avatarUrl" in rawUpdates) {
    updates.avatarUrl =
      typeof rawUpdates.avatarUrl === "string" ? rawUpdates.avatarUrl.trim() : "";
  }
  if ("birthdayMillis" in rawUpdates) {
    const birthday = timestampFromMillis(rawUpdates.birthdayMillis);
    updates.birthday =
      birthday ?? admin.firestore.FieldValue.delete();
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
  const { petId } = request.data as { petId?: string };
  if (!petId || typeof petId !== "string") {
    throw new HttpsError("invalid-argument", "Missing petId.");
  }

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

  const { petId } = request.data as { petId?: string };
  if (!petId || typeof petId !== "string") {
    throw new HttpsError("invalid-argument", "Missing petId.");
  }

  const petRef = db.doc(`pets/${petId}`);
  const followingRef = db.doc(`users/${callerUid}/followingPets/${petId}`);

  await db.runTransaction(async (t) => {
    const [petSnap, followingSnap] = await Promise.all([t.get(petRef), t.get(followingRef)]);
    if (!petSnap.exists) {
      throw new HttpsError("not-found", "Pet not found.");
    }
    if (followingSnap.exists) return;

    const petData = petSnap.data() ?? {};
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
    });
  });

  return { success: true };
});

export const unfollowPetCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const { petId } = request.data as { petId?: string };
  if (!petId || typeof petId !== "string") {
    throw new HttpsError("invalid-argument", "Missing petId.");
  }

  const followingRef = db.doc(`users/${callerUid}/followingPets/${petId}`);
  const followingSnap = await followingRef.get();
  if (followingSnap.exists) {
    await followingRef.delete();
  }
  return { success: true };
});
