import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { admin, db } from "./platform";
import { cascadeDeletePet } from "./cleanup";
import { assertCallerAccountActive, getNotificationActor } from "./notifications";
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

/**
 * Outstanding pet deletions, written by deletePetCallable and cleared when the
 * cascade finishes.
 *
 * Server-only. There is no rule for this collection in firestore.rules, and
 * Firestore denies anything a rule does not allow, so clients cannot read or
 * write it. An explicit `allow read, write: if false` block would be tidier
 * and is worth adding next time the rules are deployed; it is not added here
 * because this round does not touch or deploy rules.
 *
 * No TTL policy should be configured for it: see the write in
 * deletePetCallable for why an expiry would destroy the recovery evidence.
 */
const PET_DELETION_TASKS = "petDeletionTasks";

function petDeletionTaskRef(petId: string): admin.firestore.DocumentReference {
  return db.doc(`${PET_DELETION_TASKS}/${petId}`);
}

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

/**
 * Who may do what to a pet that several humans share.
 *
 * PetNote's premise is one pet with several *equal* human owners, but the data
 * model was built around a privileged creator: `pets/{id}.ownerId` and
 * `.primaryOwnerId` were the creator's uid forever, and every management check
 * compared against them. A co-owner could contribute and could not manage.
 *
 * The authority now comes from `pets/{id}/family/{uid}`. The two fields on the
 * pet document are retained and *redefined*: they name the **current** primary
 * owner, kept in sync with the family member whose `role` is `"primary"`, and
 * they move when that person leaves. Keeping them costs nothing and buys two
 * things — the pets-per-creator cap can stay a single indexed query, and a
 * legacy pet that somehow has no family subcollection does not become
 * unmanageable by the person who made it (the `legacyOwnerFallback` below).
 *
 * The rights split, per the product decision recorded in the review handoff:
 * everything additive is equal (edit the profile, invite, revoke, post, check
 * in, bring the pet to a meetup); the two destructive acts converge. Removing
 * *another* owner is the primary's alone, and the primary role is
 * transferable. Deleting the pet outright requires being the last owner left —
 * so it can never be used against the other owners' shared history.
 */
export type PetFamilyAuthority = {
  pet: admin.firestore.DocumentData;
  /** May contribute and manage: edit the profile, invite, revoke. */
  isMember: boolean;
  /** May remove other members and transfer the role. */
  isPrimary: boolean;
  /** Total humans in this pet's family, counting the caller. */
  memberCount: number;
  /** True when membership was inferred from ownerId/primaryOwnerId. */
  legacyOwnerFallback: boolean;
};

// A pet's family is a handful of humans, not a social graph. The cap exists so
// a corrupted subcollection cannot turn an authorization read into an
// unbounded one.
export const PET_FAMILY_READ_LIMIT = 50;

export async function getPetFamilyAuthority(
  petId: string,
  userId: string
): Promise<PetFamilyAuthority | null> {
  const safePetId = requiredDocId(petId, "petId");
  const safeUserId = requiredDocId(userId, "userId");
  const [petSnap, familySnap] = await Promise.all([
    db.doc(`pets/${safePetId}`).get(),
    db.collection(`pets/${safePetId}/family`).limit(PET_FAMILY_READ_LIMIT).get(),
  ]);
  if (!petSnap.exists) return null;

  const pet = petSnap.data() ?? {};
  const own = familySnap.docs.find((docSnap) => docSnap.id === safeUserId);
  // Only trust the pet fields when there is no family subcollection at all.
  // If the subcollection exists and does not list the caller, they were
  // removed — a stale ownerId must not let them back in.
  const legacyOwnerFallback =
    familySnap.empty &&
    (pet.ownerId === safeUserId || pet.primaryOwnerId === safeUserId);

  return {
    pet,
    isMember: own !== undefined || legacyOwnerFallback,
    isPrimary: own?.data()?.role === "primary" || legacyOwnerFallback,
    memberCount: familySnap.empty && legacyOwnerFallback ? 1 : familySnap.size,
    legacyOwnerFallback,
  };
}

/**
 * The pet's ownership state, read *through the transaction*.
 *
 * `getPetFamilyAuthority` in ./pets.ts answers the same question with plain
 * reads, which is fine for a check whose worst outcome is one stale edit. It is
 * not fine for the three operations that change who holds authority: a decision
 * taken before a transaction is a decision the transaction never verified, and
 * "I read the document" is not "I checked what I read".
 *
 * Two failures came out of that. An admin transfer demoted *the caller* rather
 * than the actual old primary, so the pet ended up with two people holding a
 * role that only one may hold — and the former primary still passed every
 * guard. And a transfer racing a leave had each writer certain about a
 * different new primary, with the same result.
 *
 * Reading the whole family subcollection inside the transaction puts every
 * document that matters in the read set, so a concurrent write to any of them
 * forces a retry and the decision is made again against what is now true.
 */
export type TransactionAuthority = {
  pet: admin.firestore.DocumentData;
  docs: admin.firestore.QueryDocumentSnapshot[];
  own?: admin.firestore.QueryDocumentSnapshot;
  isMember: boolean;
  isPrimary: boolean;
  /** Every document currently claiming the role. More than one means repair. */
  currentPrimaries: admin.firestore.QueryDocumentSnapshot[];
  memberCount: number;
};

export async function readAuthorityInTransaction(
  t: admin.firestore.Transaction,
  petId: string,
  callerUid: string
): Promise<TransactionAuthority | null> {
  const [petSnap, familySnap] = await Promise.all([
    t.get(db.doc(`pets/${petId}`)),
    t.get(db.collection(`pets/${petId}/family`).limit(PET_FAMILY_READ_LIMIT)),
  ]);
  if (!petSnap.exists) return null;
  const pet = petSnap.data() ?? {};
  const docs = familySnap.docs;
  const own = docs.find((docSnap) => docSnap.id === callerUid);
  // Same narrow legacy fallback as getPetFamilyAuthority: only trust the pet
  // document's fields when there is no family subcollection at all. A
  // subcollection that exists and does not list you means you were removed.
  const legacyOwnerFallback =
    docs.length === 0 &&
    (pet.ownerId === callerUid || pet.primaryOwnerId === callerUid);
  return {
    pet,
    docs,
    own,
    isMember: own !== undefined || legacyOwnerFallback,
    isPrimary: own?.data()?.role === "primary" || legacyOwnerFallback,
    currentPrimaries: docs.filter((docSnap) => docSnap.data()?.role === "primary"),
    memberCount: docs.length === 0 && legacyOwnerFallback ? 1 : docs.length,
  };
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

export const createPetCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot create pets.");
  }
  await assertCallerAccountActive(callerUid, caller);
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

export const updatePetCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot update pets.");
  }
  await assertCallerAccountActive(callerUid, caller);
  await assertRateLimit(callerUid, "updatePet", RATE_LIMITS.write);

  const { petId: rawUpdatePetId, ...rawUpdates } = requestData(
    request.data
  ) as {
    petId?: string;
  } & Record<string, unknown>;
  const petId = requiredDocId(rawUpdatePetId, "petId");

  const petRef = db.doc(`pets/${petId}`);
  // Every owner, not just the creator. Editing the pet's profile is the most
  // basic thing "co-owner" has to mean; restricting it to primaryOwnerId was
  // the clearest place the implementation contradicted the product.
  const authority = await getPetFamilyAuthority(petId, callerUid);
  if (!authority) {
    throw new HttpsError("not-found", "Pet not found.");
  }
  if (!authority.isMember && caller.role !== "admin") {
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
  await assertCallerAccountActive(callerUid, caller);
  await assertRateLimit(callerUid, "deletePet", RATE_LIMITS.write);

  const { petId: rawDeletePetId } = requestData(request.data) as {
    petId?: string;
  };
  const petId = requiredDocId(rawDeletePetId, "petId");

  const isAdmin = caller.role === "admin";
  const petRef = db.doc(`pets/${petId}`);
  const taskRef = petDeletionTaskRef(petId);

  // Authorization, the "am I the last owner?" test and the removal of the pet
  // document all happen in one transaction.
  //
  // They used to be a plain read followed by a non-transactional cascade, and
  // the gap between them is long enough to matter: somebody redeeming an
  // invitation in that window became an owner of a pet that was already on its
  // way out, and was told they had joined. The family subcollection is in the
  // transaction's read set, so a redemption forces a retry and the count is
  // taken again.
  //
  // Only the pet document is deleted here. Its subcollections are cleaned up
  // afterwards, outside the transaction, because a recursive delete is not
  // something a transaction can hold — same split as releasePetMembership.
  const decision = await db.runTransaction<"missing" | "delete">(async (t) => {
    const authority = await readAuthorityInTransaction(t, petId, callerUid);
    if (!authority) return "missing";
    if (!authority.isMember && !isAdmin) {
      throw new HttpsError("permission-denied", "Cannot delete this pet.");
    }
    // Deleting the pet destroys a history that belongs to everyone in its
    // family, so it takes being the only one left. An owner who wants out
    // while others remain leaves instead (removeFamilyMemberCallable on
    // themselves), which hands the pet on rather than taking it away.
    //
    // Admins keep the override: moderation has to be able to remove content
    // regardless of how many people are attached to it.
    if (authority.memberCount > 1 && !isAdmin) {
      throw new HttpsError(
        "failed-precondition",
        "This pet has other owners. Leave the pet instead, or ask the other owners to leave first."
      );
    }
    t.delete(petRef);
    // A durable record of work that is still owed, written in the same
    // transaction that removes the parent. Without it the cascade below has no
    // way to be resumed: it runs outside the transaction (a recursive delete
    // cannot be held in one), and if it fails the pet document is already gone
    // — so a retry saw no pet, concluded there was nothing to do, and reported
    // success over family, followers and invitation documents still sitting
    // there.
    //
    // It carries who asked, because "the parent is missing" must not become an
    // authorisation on its own. Only the requester or an admin can resume.
    t.set(taskRef, {
      petId,
      requestedBy: callerUid,
      requestedByAdmin: isAdmin,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      // Deliberately no `expiresAt`, and no TTL policy should be configured
      // for this collection.
      //
      // An earlier version carried one "so the collection cannot grow
      // forever". That is the wrong trade here: this record is the only
      // remaining evidence of who asked for a deletion and that its cleanup is
      // unfinished. A TTL would silently delete exactly the records that keep
      // failing — the ones that most need attention — and take the
      // authorisation to resume with them.
      //
      // Records are removed when the cleanup completes (runPetCascade), which
      // is the only condition under which they are safe to drop. One that
      // survives repeated sweeper attempts is a signal, not litter.
    });
    return "delete";
  });

  if (decision === "missing") {
    // No pet. Either it never existed, or a previous attempt removed it and
    // its cleanup did not finish. Only the second case has work to do, and
    // only for somebody entitled to it.
    const resumed = await resumePetDeletion(petId, callerUid, isAdmin);
    return { success: true, resumed };
  }

  await runPetCascade(petId);
  return { success: true, resumed: false };
});

/**
 * Runs the cascade and clears the recovery record only if it completes.
 *
 * Deliberately rethrows. Reporting success while subcollections remain is what
 * made the failure invisible; the caller retrying is the primary recovery path,
 * and the scheduled sweeper below is the backstop for the caller who never
 * comes back.
 */
async function runPetCascade(petId: string): Promise<void> {
  await cascadeDeletePet(petId);
  await petDeletionTaskRef(petId).delete().catch(() => undefined);
}

/**
 * Finishes an interrupted deletion, if this caller is entitled to.
 *
 * Returns false — not an error — when there is no outstanding task, because
 * deleting an already-deleted pet is a no-op, and when the caller is not the
 * requester, because telling an unrelated account whether somebody else has a
 * half-finished deletion is not information it needs.
 */
async function resumePetDeletion(
  petId: string,
  callerUid: string,
  isAdmin: boolean
): Promise<boolean> {
  const taskSnap = await petDeletionTaskRef(petId).get();
  if (!taskSnap.exists) return false;
  const task = taskSnap.data() ?? {};
  if (task.requestedBy !== callerUid && !isAdmin) return false;
  await runPetCascade(petId);
  return true;
}

/**
 * Finishes pet deletions whose cleanup never completed.
 *
 * The backstop for the requester who never retries. Without it an interrupted
 * cascade leaves family, followers and invitation documents indefinitely —
 * `onPetDeleted` covers followingPets and posts' pet references, not those.
 */
export const resumeAbandonedPetDeletions = onSchedule(
  { schedule: "every 6 hours", timeoutSeconds: 540 },
  async () => {
    const tasks = await db.collection(PET_DELETION_TASKS).limit(200).get();
    for (const taskSnap of tasks.docs) {
      try {
        await runPetCascade(taskSnap.id);
      } catch (error) {
        // Leave the record in place for the next run rather than losing track
        // of the work.
        console.error(
          `resumeAbandonedPetDeletions: ${taskSnap.id} still failing`,
          error
        );
      }
    }
  }
);

export const followPetCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot follow pets.");
  }
  await assertCallerAccountActive(callerUid, caller);
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
  await assertCallerAccountActive(callerUid, caller);
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
