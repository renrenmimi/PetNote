import { randomInt } from "node:crypto";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { admin, db } from "./platform";
import { getNotificationActor } from "./notifications";
import { assertRateLimit, getDefaultAvatar, RATE_LIMITS, stripUndefined } from "./shared";

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
  return invitation?.expiresAt instanceof admin.firestore.Timestamp
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
    getInvitationExpiresAtMillis(invitation) > Date.now()
  );
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
  const invitationsSnap = await db.collection(`pets/${petId}/invitations`).get();
  const latest = pickLatestActiveInvitation(invitationsSnap.docs);
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
      expiresAt: admin.firestore.Timestamp.fromMillis(invitation.expiresAtMillis),
      used: invitation.used,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
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
  const familySnap = await db.doc(`pets/${petId}/family/${userId}`).get();
  if (!familySnap.exists) {
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
  await assertRateLimit(callerUid, "createInvitation", RATE_LIMITS.write);

  const { petId } = request.data as { petId?: string };
  if (!petId || typeof petId !== "string") {
    throw new HttpsError("invalid-argument", "Missing petId.");
  }

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
      const expiresAt = admin.firestore.Timestamp.fromMillis(
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
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      batch.create(invitationLookupRef(code), {
        code,
        petId,
        invitationPath: invitationRef.path,
        createdBy: callerUid,
        createdByName: caller.fromUserName,
        expiresAt,
        used: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
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

  const { petId } = request.data as { petId?: string };
  if (!petId || typeof petId !== "string") {
    throw new HttpsError("invalid-argument", "Missing petId.");
  }

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
    (request.data as { code?: unknown } | undefined)?.code
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
  await assertRateLimit(callerUid, "redeemInvitation", RATE_LIMITS.strictWrite);

  const data = request.data as {
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
      invitation.expiresAt instanceof admin.firestore.Timestamp
        ? invitation.expiresAt.toMillis()
        : 0;
    if (invitation.used === true || expiresAt <= Date.now()) {
      throw new HttpsError("failed-precondition", "Invitation is no longer valid.");
    }

    transaction.set(
      familyRef,
      stripUndefined({
        userId: callerUid,
        userName: caller.fromUserName,
        userAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
        relationship,
        customRelationship:
          relationship === "other" &&
          typeof data.customRelationship === "string" &&
          data.customRelationship.trim().length > 0
            ? data.customRelationship.trim()
            : undefined,
        role: "member",
        invitationCode: normalizedCode,
        joinedAt: admin.firestore.FieldValue.serverTimestamp(),
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
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
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

export const removeFamilyMemberCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot remove family members.");
  }
  await assertRateLimit(callerUid, "removeFamilyMember", RATE_LIMITS.write);

  const { petId, targetUserId } = request.data as {
    petId?: string;
    targetUserId?: string;
  };
  if (!petId || !targetUserId) {
    throw new HttpsError("invalid-argument", "Missing petId or targetUserId.");
  }

  const petSnap = await db.doc(`pets/${petId}`).get();
  if (!petSnap.exists) {
    throw new HttpsError("not-found", "Pet not found.");
  }
  const petData = petSnap.data() ?? {};
  const canRemove =
    callerUid === targetUserId ||
    petData.primaryOwnerId === callerUid ||
    petData.ownerId === callerUid;
  if (!canRemove) {
    throw new HttpsError("permission-denied", "Cannot remove this family member.");
  }

  const targetFamilyRef = db.doc(`pets/${petId}/family/${targetUserId}`);
  const targetFamilySnap = await targetFamilyRef.get();
  if (!targetFamilySnap.exists) {
    return { success: true };
  }

  const targetFamilyData = targetFamilySnap.data() ?? {};
  if (targetFamilyData.role === "primary") {
    throw new HttpsError(
      "failed-precondition",
      "Primary family members cannot be removed from the family."
    );
  }

  await targetFamilyRef.delete();
  return { success: true };
});
