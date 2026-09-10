import { randomInt } from "node:crypto";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { admin, db, FieldValue, Timestamp } from "./platform";
import { assertCallerAccountActive, getNotificationActor } from "./notifications";
import { getPetFamilyAuthority } from "./pets";
import {
  assertRateLimit,
  getDefaultAvatar,
  optionalTrimmedString,
  RATE_LIMITS,
  requestData,
  requiredDocId,
  stripUndefined,
  VALIDATION_LIMITS,
} from "./shared";

type ActiveInvitation = {
  code: string;
  createdBy: string;
  createdByName: string;
  expiresAtMillis: number;
  used: boolean;
  petId: string;
};

function invitationLookupRef(code: string): admin.firestore.DocumentReference {
  return db.doc(`invitationCodes/${code}`);
}

function normalizeInvitationCode(code: unknown): string {
  return typeof code === "string"
    ? code.replace(/[^a-zA-Z0-9]/g, "").toUpperCase()
    : "";
}

function getInvitationExpiresAtMillis(
  invitation: admin.firestore.DocumentData | undefined
): number {
  return invitation?.expiresAt instanceof Timestamp
    ? invitation.expiresAt.toMillis()
    : 0;
}

function mapActiveInvitation(
  docSnap: admin.firestore.DocumentSnapshot,
  petId: string
): ActiveInvitation {
  const invitation = docSnap.data() ?? {};
  return {
    code: docSnap.id,
    createdBy:
      typeof invitation.createdBy === "string" ? invitation.createdBy : "",
    createdByName:
      typeof invitation.createdByName === "string"
        ? invitation.createdByName
        : "PetNote User",
    expiresAtMillis: getInvitationExpiresAtMillis(invitation),
    used: invitation.used === true,
    petId,
  };
}

function isActiveInvitationData(
  invitation: admin.firestore.DocumentData | undefined
): boolean {
  return (
    invitation?.used !== true &&
    invitation?.revoked !== true &&
    getInvitationExpiresAtMillis(invitation) > Date.now()
  );
}

/**
 * Revoking sets `used: true` as well as the `revoked` audit fields.
 *
 * That is on purpose. `used == false` is the first clause of the composite
 * index behind getLatestActiveInvitationForPet, so flipping it is what removes
 * the code from every lookup path without adding a third field to the index
 * (and without a migration for the invitations already in Firestore). The
 * `revoked` fields carry the reason so the redeem path can say "revoked"
 * rather than the misleading "already used", and so a support question about a
 * dead code is answerable.
 */
function revokedInvitationFields(
  revokedBy: string,
  reason: string
): Record<string, unknown> {
  return {
    used: true,
    revoked: true,
    revokedBy,
    revokedReason: reason,
    revokedAt: FieldValue.serverTimestamp(),
  };
}

/**
 * Marks every still-live invitation on `petId` that `createdBy` minted as
 * revoked, in both the pet subcollection and the top-level code lookup.
 *
 * Called when that person stops being a family member. An invitation is a
 * standing grant of write access to someone else's pet: it has to stop being
 * worth anything the moment the authority behind it goes away, not 48 hours
 * later when it happens to expire.
 */
export async function revokeInvitationsCreatedBy(
  petId: string,
  createdBy: string,
  revokedBy: string,
  reason: string
): Promise<number> {
  // One equality filter only, and the used/expiry test happens in memory. A
  // second clause would need a composite index deployed before this code, and
  // the collection it scans is tiny: createInvitationCallable hands back the
  // existing active code instead of minting a new one, so a single person
  // accumulates at most one invitation per 48 hours on a given pet.
  const invitationsSnap = await db
    .collection(`pets/${petId}/invitations`)
    .where("createdBy", "==", createdBy)
    .get();
  const live = invitationsSnap.docs.filter((docSnap) =>
    isActiveInvitationData(docSnap.data())
  );
  if (live.length === 0) {
    return 0;
  }
  const fields = revokedInvitationFields(revokedBy, reason);
  const batch = db.batch();
  for (const docSnap of live) {
    batch.update(docSnap.ref, fields);
    // The lookup doc is what redeemInvitationCallable resolves a typed code
    // through, so it has to be revoked too — otherwise validateInvitation
    // would keep reporting the code as valid until the subcollection read.
    batch.set(invitationLookupRef(docSnap.id), fields, { merge: true });
  }
  await batch.commit();
  return live.length;
}

function pickLatestActiveInvitation(
  docs: admin.firestore.QueryDocumentSnapshot[]
): admin.firestore.QueryDocumentSnapshot | null {
  let latest: admin.firestore.QueryDocumentSnapshot | null = null;
  let latestExpiresAtMillis = 0;
  for (const docSnap of docs) {
    const invitation = docSnap.data();
    const expiresAtMillis = getInvitationExpiresAtMillis(invitation);
    if (invitation.used === true || expiresAtMillis <= Date.now()) {
      continue;
    }
    if (!latest || expiresAtMillis > latestExpiresAtMillis) {
      latest = docSnap;
      latestExpiresAtMillis = expiresAtMillis;
    }
  }
  return latest;
}

async function getLatestActiveInvitationForPet(
  petId: string
): Promise<ActiveInvitation | null> {
  // Filter on the server with a composite index (used ASC, expiresAt DESC)
  // instead of reading the entire invitations subcollection. Old expired
  // invitations accumulate over time and were previously all loaded just to
  // find the single active one.
  const now = Timestamp.now();
  const invitationsSnap = await db
    .collection(`pets/${petId}/invitations`)
    .where("used", "==", false)
    .where("expiresAt", ">", now)
    .orderBy("expiresAt", "desc")
    .limit(1)
    .get();
  const latest = invitationsSnap.docs[0] ?? null;
  return latest ? mapActiveInvitation(latest, petId) : null;
}

async function ensureInvitationLookup(
  invitation: ActiveInvitation
): Promise<void> {
  if (!invitation.code || !invitation.petId) {
    return;
  }
  await invitationLookupRef(invitation.code).set(
    {
      code: invitation.code,
      petId: invitation.petId,
      invitationPath: `pets/${invitation.petId}/invitations/${invitation.code}`,
      createdBy: invitation.createdBy,
      createdByName: invitation.createdByName,
      expiresAt: Timestamp.fromMillis(invitation.expiresAtMillis),
      used: invitation.used,
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
}

async function getLatestActiveInvitationByCode(
  code: string
): Promise<{ invitation: ActiveInvitation; ref: admin.firestore.DocumentReference } | null> {
  const lookupSnap = await invitationLookupRef(code).get();
  if (lookupSnap.exists) {
    const lookup = lookupSnap.data() ?? {};
    const petId = typeof lookup.petId === "string" ? lookup.petId : "";
    if (petId) {
      const invitationRef = db.doc(`pets/${petId}/invitations/${code}`);
      const invitationSnap = await invitationRef.get();
      if (invitationSnap.exists && isActiveInvitationData(invitationSnap.data())) {
        return {
          invitation: mapActiveInvitation(invitationSnap, petId),
          ref: invitationRef,
        };
      }
    }
    return null;
  }

  const invitationsSnap = await db
    .collectionGroup("invitations")
    .where("code", "==", code)
    .limit(5)
    .get();
  const latest = pickLatestActiveInvitation(invitationsSnap.docs);
  if (!latest) {
    return null;
  }
  const petId = latest.ref.parent.parent?.id;
  if (!petId) {
    return null;
  }
  const invitation = mapActiveInvitation(latest, petId);
  await ensureInvitationLookup(invitation);
  return {
    invitation,
    ref: latest.ref,
  };
}

async function assertPetFamilyMember(petId: string, userId: string): Promise<void> {
  // Through getPetFamilyAuthority rather than a bare family-document read, so
  // a legacy pet with no family subcollection does not lock its own creator
  // out of inviting anybody. Inviting is an additive act, so every owner has
  // it — see ./pets.ts for the rights split.
  const authority = await getPetFamilyAuthority(petId, userId);
  if (!authority?.isMember) {
    throw new HttpsError("permission-denied", "Only family members can access invitations.");
  }
}

export const createInvitationCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot create invitations.");
  }
  await assertCallerAccountActive(callerUid, caller);
  await assertRateLimit(callerUid, "createInvitation", RATE_LIMITS.write);

  const { petId: rawInvitePetId } = requestData(request.data) as {
    petId?: string;
  };
  const petId = requiredDocId(rawInvitePetId, "petId");

  await assertPetFamilyMember(petId, callerUid);

  const activeInvitation = await getLatestActiveInvitationForPet(petId);
  if (activeInvitation) {
    await ensureInvitationLookup(activeInvitation);
    return activeInvitation;
  }

  const inviteChars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const generateCode = () =>
    Array.from({ length: 8 }, () => inviteChars[randomInt(inviteChars.length)]).join("");

  let code = generateCode();
  let attempts = 0;
  while (attempts < 10) {
    const [duplicateLookupSnap, duplicateSnap] = await Promise.all([
      invitationLookupRef(code).get(),
      db.collectionGroup("invitations").where("code", "==", code).limit(1).get(),
    ]);
    if (!duplicateLookupSnap.exists && duplicateSnap.empty) {
      const expiresAt = Timestamp.fromMillis(
        Date.now() + 48 * 60 * 60 * 1000
      );
      const invitationRef = db.doc(`pets/${petId}/invitations/${code}`);
      const batch = db.batch();
      batch.set(invitationRef, {
        code,
        createdBy: callerUid,
        createdByName: caller.fromUserName,
        expiresAt,
        used: false,
        createdAt: FieldValue.serverTimestamp(),
      });
      batch.create(invitationLookupRef(code), {
        code,
        petId,
        invitationPath: invitationRef.path,
        createdBy: callerUid,
        createdByName: caller.fromUserName,
        expiresAt,
        used: false,
        createdAt: FieldValue.serverTimestamp(),
      });
      await batch.commit();
      return {
        code,
        createdBy: callerUid,
        createdByName: caller.fromUserName,
        expiresAtMillis: expiresAt.toMillis(),
        used: false,
        petId,
      };
    }
    code = generateCode();
    attempts += 1;
  }

  throw new HttpsError("resource-exhausted", "Could not generate an invitation code.");
});

export const getActiveInvitationCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }
  await assertRateLimit(callerUid, "getActiveInvitation", RATE_LIMITS.read);

  const { petId: rawInvitePetId } = requestData(request.data) as {
    petId?: string;
  };
  const petId = requiredDocId(rawInvitePetId, "petId");

  await assertPetFamilyMember(petId, callerUid);
  const invitation = await getLatestActiveInvitationForPet(petId);
  if (invitation) {
    await ensureInvitationLookup(invitation);
  }
  return { invitation };
});

export const validateInvitationCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }
  await assertRateLimit(callerUid, "validateInvitation", RATE_LIMITS.read);

  const normalizedCode = normalizeInvitationCode(
    (requestData(request.data) as { code?: unknown }).code
  );
  if (normalizedCode.length !== 8) {
    throw new HttpsError("invalid-argument", "Invitation code must be 8 characters.");
  }

  const invitationMatch = await getLatestActiveInvitationByCode(normalizedCode);
  if (!invitationMatch) {
    return { valid: false, error: "Invalid or expired invitation code." };
  }

  const petSnap = await db.doc(`pets/${invitationMatch.invitation.petId}`).get();
  if (!petSnap.exists) {
    return { valid: false, error: "Pet not found." };
  }

  const petData = petSnap.data() ?? {};
  return {
    valid: true,
    petId: invitationMatch.invitation.petId,
    petName:
      typeof petData.name === "string" && petData.name.trim().length > 0
        ? petData.name
        : "Pet",
  };
});

export const redeemInvitationCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot redeem invitations.");
  }
  await assertCallerAccountActive(callerUid, caller);
  await assertRateLimit(callerUid, "redeemInvitation", RATE_LIMITS.strictWrite);

  const data = requestData(request.data) as {
    code?: string;
    relationship?: string;
    customRelationship?: string;
  };
  const normalizedCode = normalizeInvitationCode(data.code);
  if (normalizedCode.length !== 8) {
    throw new HttpsError("invalid-argument", "Invitation code must be 8 characters.");
  }

  const allowedRelationships = new Set([
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
  const relationship =
    typeof data.relationship === "string" && allowedRelationships.has(data.relationship)
      ? data.relationship
      : null;
  if (!relationship) {
    throw new HttpsError("invalid-argument", "Invalid relationship.");
  }

  const invitationMatch = await getLatestActiveInvitationByCode(normalizedCode);
  if (!invitationMatch) {
    // A revoked code is a different situation from a mistyped one, and the
    // person holding it deserves to be told which. Reading the lookup doc for
    // the reason costs one get on a path that is already failing.
    const lookupSnap = await invitationLookupRef(normalizedCode).get();
    if (lookupSnap.exists && lookupSnap.data()?.revoked === true) {
      throw new HttpsError("failed-precondition", "This invitation was revoked.");
    }
    throw new HttpsError("not-found", "Invalid or expired invitation code.");
  }
  const petId = invitationMatch.invitation.petId;

  const petRef = db.doc(`pets/${petId}`);
  const familyRef = db.doc(`pets/${petId}/family/${callerUid}`);
  const invitationRef = invitationMatch.ref;
  const lookupRef = invitationLookupRef(normalizedCode);

  await db.runTransaction(async (transaction) => {
    const [petSnap, familySnap, freshInvitationSnap] = await Promise.all([
      transaction.get(petRef),
      transaction.get(familyRef),
      transaction.get(invitationRef),
    ]);

    if (!petSnap.exists) {
      throw new HttpsError("not-found", "Associated pet not found.");
    }
    if (familySnap.exists) {
      throw new HttpsError("already-exists", "You are already a family member of this pet.");
    }
    if (!freshInvitationSnap.exists) {
      throw new HttpsError("not-found", "Invitation no longer exists.");
    }

    const invitation = freshInvitationSnap.data() ?? {};
    const expiresAt =
      invitation.expiresAt instanceof Timestamp
        ? invitation.expiresAt.toMillis()
        : 0;
    if (invitation.revoked === true) {
      throw new HttpsError("failed-precondition", "This invitation was revoked.");
    }
    if (invitation.used === true || expiresAt <= Date.now()) {
      throw new HttpsError("failed-precondition", "Invitation is no longer valid.");
    }

    // An invitation is only ever as good as the authority of the person who
    // minted it. Usage and expiry were rechecked here, but not that — so a
    // family member could mint a code, be removed by the owner, and walk back
    // in with the code they had already saved, for the rest of its 48 hours.
    //
    // removeFamilyMemberCallable revokes outstanding codes eagerly; this read
    // is the transactional half of the same rule, and it is the half that
    // holds when removal and redemption race, or when a code was minted
    // before revocation existed.
    const inviterUid =
      typeof invitation.createdBy === "string" ? invitation.createdBy : "";
    if (!inviterUid) {
      throw new HttpsError("failed-precondition", "Invitation is no longer valid.");
    }
    const inviterFamilySnap = await transaction.get(
      db.doc(`pets/${petId}/family/${inviterUid}`)
    );
    if (!inviterFamilySnap.exists) {
      throw new HttpsError(
        "failed-precondition",
        "The person who sent this invitation is no longer part of this pet's family."
      );
    }

    transaction.set(
      familyRef,
      stripUndefined({
        userId: callerUid,
        userName: caller.fromUserName,
        userAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
        relationship,
        // Length-capped like every other customRelationship write path —
        // this was the one place a direct call could stuff an unbounded
        // string into the family doc.
        customRelationship:
          relationship === "other"
            ? optionalTrimmedString(
                data.customRelationship,
                VALIDATION_LIMITS.petCustomRelationship,
                "Custom relationship"
              )
            : undefined,
        role: "member",
        invitationCode: normalizedCode,
        joinedAt: FieldValue.serverTimestamp(),
      })
    );

    transaction.update(invitationRef, {
      used: true,
      usedBy: callerUid,
      usedByName: caller.fromUserName,
    });
    transaction.set(
      lookupRef,
      {
        code: normalizedCode,
        petId,
        invitationPath: invitationRef.path,
        used: true,
        usedBy: callerUid,
        usedByName: caller.fromUserName,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  });

  const petSnap = await petRef.get();
  const petData = petSnap.data() ?? {};
  return {
    success: true,
    petId,
    petName:
      typeof petData.name === "string" && petData.name.trim().length > 0
        ? petData.name
        : "Pet",
  };
});

/**
 * Lets a family member kill the pet's outstanding invitation code without
 * removing anybody — the control the family screen was missing. A code was
 * previously live for its full 48 hours with no way to take it back, which is
 * the wrong default for something that grants write access to a shared pet.
 */
export const revokeInvitationCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot revoke invitations.");
  }
  await assertCallerAccountActive(callerUid, caller);
  await assertRateLimit(callerUid, "revokeInvitation", RATE_LIMITS.write);

  const data = requestData(request.data) as { petId?: string; code?: unknown };
  const petId = requiredDocId(data.petId, "petId");
  await assertPetFamilyMember(petId, callerUid);

  const normalizedCode = normalizeInvitationCode(data.code);
  if (normalizedCode.length !== 8) {
    throw new HttpsError("invalid-argument", "Invitation code must be 8 characters.");
  }

  const invitationRef = db.doc(`pets/${petId}/invitations/${normalizedCode}`);
  const invitationSnap = await invitationRef.get();
  if (!invitationSnap.exists) {
    throw new HttpsError("not-found", "Invitation not found for this pet.");
  }
  if (!isActiveInvitationData(invitationSnap.data())) {
    // Already used, revoked or expired. Nothing to do, and saying "not found"
    // would be a lie — the caller's intent is already satisfied.
    return { success: true, alreadyInactive: true };
  }

  const fields = revokedInvitationFields(callerUid, "revoked_by_family");
  const batch = db.batch();
  batch.update(invitationRef, fields);
  batch.set(invitationLookupRef(normalizedCode), fields, { merge: true });
  await batch.commit();

  return { success: true, alreadyInactive: false };
});
