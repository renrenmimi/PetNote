import { onCall, HttpsError } from "firebase-functions/v2/https";
import { admin, db } from "./platform";
import { cascadeDeletePet } from "./cleanup";
import {
  assertCallerAccountActive,
  createNotificationIfAllowed,
  getNotificationActor,
  SYSTEM_NOTIFICATION_ACTOR,
} from "./notifications";
import { revokeInvitationsCreatedBy } from "./invitations";
import { readAuthorityInTransaction } from "./pets";
import {
  assertRateLimit,
  RATE_LIMITS,
  requestData,
  requiredDocId,
} from "./shared";

/**
 * The shared-pet lifecycle: what happens to a pet, and to the other humans
 * attached to it, when one of them goes.
 *
 * The old answer was "the pet goes too". `deleteUserAccount` selected pets by
 * `ownerId` and cascade-deleted the whole subtree, so deleting the account of
 * whoever happened to create the pet destroyed it for everybody else — their
 * posts survived but lost the pet they were about. For an app whose premise is
 * that one pet has several equal owners, that made the first human's account
 * the pet's single point of failure.
 *
 * The rule now: **a pet outlives any one of its owners.** Losing an owner is a
 * membership change, not a deletion. Only the departure of the *last* owner is
 * allowed to end the pet, and even then only when the departure is itself
 * irreversible (an account deletion) — a plain "leave" by the sole owner is
 * refused, because leaving must never be a way to destroy shared history by
 * accident. See ./pets.ts `getPetFamilyAuthority` for the rights split.
 */

/** What `releasePetMembership` did, so callers can report it honestly. */
export type PetReleaseOutcome =
  | { action: "handed_over"; newPrimaryUid: string }
  | { action: "member_removed" }
  | { action: "pet_deleted" }
  | { action: "last_member_refused" }
  | { action: "not_a_member" }
  /** The caller was not allowed to do this, judged inside the transaction. */
  | { action: "not_authorized"; because: "not_primary" | "not_member" }
  /** Refused: the primary can leave, but cannot be pushed out by somebody else. */
  | { action: "target_is_primary" };

/**
 * Who is asking, so the transaction can decide rather than trust.
 *
 * Absent for the account-deletion cascade, which is not acting on anybody's
 * behalf — the account is going regardless of who holds which role.
 */
export type ReleaseAuthorization = {
  callerUid: string;
  isAdmin: boolean;
};

type FamilyCandidate = {
  uid: string;
  joinedAtMillis: number;
};

/**
 * The next primary owner: whoever has been in this pet's family longest.
 *
 * Longest-standing is the least surprising choice available without asking a
 * human — it is the person most likely to have been there before the leaver,
 * and it does not depend on relationship labels, which are self-declared and
 * carry no authority. A member whose `joinedAt` is missing (only possible on
 * data older than the field) sorts last rather than first, so a missing
 * timestamp cannot beat a real one. The uid tie-break exists purely so the
 * result is deterministic and therefore testable.
 */
function pickSuccessor(candidates: FamilyCandidate[]): string | null {
  if (candidates.length === 0) return null;
  return [...candidates].sort((a, b) =>
    a.joinedAtMillis !== b.joinedAtMillis
      ? a.joinedAtMillis - b.joinedAtMillis
      : a.uid < b.uid
      ? -1
      : 1
  )[0].uid;
}

async function readPetName(
  petRef: admin.firestore.DocumentReference
): Promise<string> {
  const name = (await petRef.get()).data()?.name;
  return typeof name === "string" && name.trim().length > 0 ? name : "your pet";
}

function joinedAtMillisOf(data: admin.firestore.DocumentData): number {
  return data.joinedAt instanceof admin.firestore.Timestamp
    ? data.joinedAt.toMillis()
    : Number.POSITIVE_INFINITY;
}

/**
 * Removes `leavingUid` from `petId`'s family, handing the pet on rather than
 * taking it with them.
 *
 * `onLastMember` is the whole reason this is one function and not two:
 *
 * - `"refuse"` — an ordinary leave. If they are the only owner, nothing
 *   happens and the caller is told to delete the pet deliberately instead.
 * - `"delete"` — an account deletion. The person is leaving whether or not the
 *   pet has anyone else, so a pet with nobody left has to end.
 *
 * The membership decision is one transaction. That matters for the case of two
 * owners leaving at the same time: each transaction reads the whole family
 * subcollection, so the second one is forced to retry against the first one's
 * write and sees itself as the last member — instead of both concluding
 * "someone else remains" and leaving the pet with no owners at all.
 */
export async function releasePetMembership(options: {
  petId: string;
  leavingUid: string;
  onLastMember: "refuse" | "delete";
  reason: string;
  /**
   * Present when a person is asking on their own or somebody else's behalf, so
   * the permission is decided from the same snapshot as the membership change.
   * Absent for the account-deletion cascade.
   */
  authorize?: ReleaseAuthorization;
}): Promise<PetReleaseOutcome> {
  const { petId, leavingUid, onLastMember, reason, authorize } = options;
  const petRef = db.doc(`pets/${petId}`);

  const outcome = await db.runTransaction<PetReleaseOutcome>(async (t) => {
    const authority = await readAuthorityInTransaction(
      t,
      petId,
      authorize?.callerUid ?? leavingUid
    );
    if (!authority) return { action: "not_a_member" };
    const pet = authority.pet;
    const familySnap = { docs: authority.docs, empty: authority.docs.length === 0 };

    if (authorize) {
      const isSelf = authorize.callerUid === leavingUid;
      // Leaving is every owner's own decision; removing somebody *else* is the
      // primary's. Both are judged here rather than before the transaction,
      // where a concurrent transfer could invalidate the answer between the
      // check and the write.
      if (!isSelf && !authority.isPrimary && !authorize.isAdmin) {
        return { action: "not_authorized", because: "not_primary" };
      }
      if (!isSelf && !authority.isMember && !authorize.isAdmin) {
        return { action: "not_authorized", because: "not_member" };
      }
      if (!isSelf) {
        const target = authority.docs.find((docSnap) => docSnap.id === leavingUid);
        if (!target) return { action: "not_a_member" };
        // The primary can leave, but must not be pushed out — that would be a
        // way to take over somebody's pet. Transfer the role first.
        if (target.data()?.role === "primary") {
          return { action: "target_is_primary" };
        }
      }
    }

    const own = familySnap.docs.find((docSnap) => docSnap.id === leavingUid);
    if (!own) {
      // No family document. The only way this person still counts as an owner
      // is the legacy fallback — a pet whose family subcollection was never
      // written. Then they are by definition the only one.
      const legacyOwner =
        familySnap.empty &&
        (pet.ownerId === leavingUid || pet.primaryOwnerId === leavingUid);
      if (!legacyOwner) return { action: "not_a_member" };
      if (onLastMember === "refuse") return { action: "last_member_refused" };
      t.delete(petRef);
      return { action: "pet_deleted" };
    }

    const remaining: FamilyCandidate[] = familySnap.docs
      .filter((docSnap) => docSnap.id !== leavingUid)
      .map((docSnap) => ({
        uid: docSnap.id,
        joinedAtMillis: joinedAtMillisOf(docSnap.data()),
      }));

    if (remaining.length === 0) {
      if (onLastMember === "refuse") return { action: "last_member_refused" };
      // Delete the pet document inside the same transaction that observed
      // "nobody left", so the observation cannot go stale. The subcollections
      // are cleaned up afterwards, outside the transaction.
      t.delete(own.ref);
      t.delete(petRef);
      return { action: "pet_deleted" };
    }

    const wasPrimary =
      own.data()?.role === "primary" ||
      pet.primaryOwnerId === leavingUid ||
      pet.ownerId === leavingUid;

    if (!wasPrimary) {
      t.delete(own.ref);
      return { action: "member_removed" };
    }

    const successorUid = pickSuccessor(remaining);
    if (!successorUid) return { action: "not_a_member" };
    // ownerId and primaryOwnerId move with the role. They are the pet's record
    // of who its primary owner is *now*, and the pets-per-creator cap plus the
    // legacy fallback both read them, so leaving them pointing at a deleted
    // account would be worse than not having them at all.
    t.update(petRef, {
      ownerId: successorUid,
      primaryOwnerId: successorUid,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    t.update(db.doc(`pets/${petId}/family/${successorUid}`), {
      role: "primary",
      promotedAt: admin.firestore.FieldValue.serverTimestamp(),
      promotedReason: reason,
    });
    // Demote anybody else still claiming the role. Normally there is nobody —
    // the leaver is the only primary — but a state with two primaries is
    // exactly what the bug this transaction closes used to produce, and
    // handing over is a good moment to stop carrying it.
    for (const docSnap of authority.currentPrimaries) {
      if (docSnap.id !== successorUid && docSnap.id !== leavingUid) {
        t.update(docSnap.ref, { role: "member" });
      }
    }
    t.delete(own.ref);
    return { action: "handed_over", newPrimaryUid: successorUid };
  });

  if (outcome.action === "pet_deleted") {
    await cascadeDeletePet(petId);
    return outcome;
  }
  if (outcome.action === "not_a_member" || outcome.action === "last_member_refused") {
    return outcome;
  }

  // Their standing invitations die with their membership. Same rule as
  // removeFamilyMemberCallable, applied to every way of losing membership.
  await revokeInvitationsCreatedBy(petId, leavingUid, leavingUid, reason).catch(
    (error) => {
      // Not fatal: the redeem transaction rechecks the inviter's membership, so
      // a failure here degrades to "the code looks live until someone tries
      // it", not to a usable grant.
      console.error(
        `releasePetMembership: revoking invitations failed for pet ${petId}`,
        error
      );
      return 0;
    }
  );

  if (outcome.action === "handed_over") {
    const petName = await readPetName(petRef);
    await createNotificationIfAllowed(
      {
        userId: outcome.newPrimaryUid,
        // From PetNote, not from the person who left. When the cause is an
        // account deletion, the same cascade deletes every notification whose
        // fromUserId is the departing uid — this notice has to outlive that,
        // and naming somebody whose account is being erased in a message that
        // survives them would work against the point of the cascade.
        ...SYSTEM_NOTIFICATION_ACTOR,
        type: "pet_primary_transferred",
        message: `You are now the primary owner of ${petName}.`,
        petId,
      },
      // One notification per handover, not one per retry of the cascade.
      { dedupeId: `pet_primary_${petId}_${outcome.newPrimaryUid}` }
    ).catch((error) => {
      console.error("releasePetMembership: handover notice failed", error);
      return "";
    });
  }

  return outcome;
}

/**
 * Every pet this person is attached to, for the account-deletion cascade.
 *
 * Two sources, deliberately. The family collection group is the real one. The
 * ownerId query catches a pet whose family subcollection is missing entirely —
 * without it, such a pet would survive its only owner's deletion with nobody
 * able to manage it.
 */
export async function getPetIdsForMember(userId: string): Promise<string[]> {
  const [familySnap, ownedSnap] = await Promise.all([
    db.collectionGroup("family").where("userId", "==", userId).get(),
    db.collection("pets").where("ownerId", "==", userId).get(),
  ]);
  const petIds = new Set<string>();
  for (const docSnap of familySnap.docs) {
    const petId = docSnap.ref.parent.parent?.id;
    if (petId) petIds.add(petId);
  }
  for (const docSnap of ownedSnap.docs) petIds.add(docSnap.id);
  return Array.from(petIds);
}

export const removeFamilyMemberCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot remove family members.");
  }
  await assertCallerAccountActive(callerUid, caller);
  await assertRateLimit(callerUid, "removeFamilyMember", RATE_LIMITS.write);

  const { petId: rawRemovePetId, targetUserId: rawTargetUserId } = requestData(
    request.data
  ) as {
    petId?: string;
    targetUserId?: string;
  };
  const petId = requiredDocId(rawRemovePetId, "petId");
  const targetUserId = requiredDocId(rawTargetUserId, "targetUserId");

  const isSelf = callerUid === targetUserId;

  // Permission, "is the target the primary", and the membership change are all
  // decided inside releasePetMembership's transaction now. They used to be
  // three separate reads in front of it, which meant a concurrent transfer
  // could move the role between the check and the write — and the check would
  // never know.
  const outcome = await releasePetMembership({
    petId,
    leavingUid: targetUserId,
    // A plain leave must never destroy the pet. If they are the only owner
    // left, they are told to delete the pet on purpose instead.
    onLastMember: "refuse",
    reason: isSelf ? "member_left" : "member_removed",
    authorize: { callerUid, isAdmin: caller.role === "admin" },
  });

  if (outcome.action === "not_authorized") {
    throw new HttpsError(
      "permission-denied",
      outcome.because === "not_primary"
        ? "Only the pet's primary owner can remove another family member."
        : "Cannot remove this family member."
    );
  }
  if (outcome.action === "target_is_primary") {
    throw new HttpsError(
      "failed-precondition",
      "Transfer the primary owner role before removing this person."
    );
  }
  if (outcome.action === "last_member_refused") {
    throw new HttpsError(
      "failed-precondition",
      "You are this pet's only owner. Invite someone else first, or delete the pet."
    );
  }

  return { success: true, action: outcome.action };
});

/**
 * Hands the primary owner role to another existing family member.
 *
 * The counterpart to "the primary cannot be pushed out": if the role is the
 * only asymmetry left, it has to be movable, or a family is stuck with
 * whoever happened to create the pet — the same problem in a smaller shape.
 */
export const transferPetPrimaryCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot transfer pets.");
  }
  await assertCallerAccountActive(callerUid, caller);
  await assertRateLimit(callerUid, "transferPetPrimary", RATE_LIMITS.strictWrite);

  const data = requestData(request.data) as {
    petId?: string;
    targetUserId?: string;
  };
  const petId = requiredDocId(data.petId, "petId");
  const targetUserId = requiredDocId(data.targetUserId, "targetUserId");
  const isAdmin = caller.role === "admin";
  if (targetUserId === callerUid && !isAdmin) {
    return { success: true, alreadyPrimary: true };
  }

  const petRef = db.doc(`pets/${petId}`);

  // Authorization, the identity of the *actual* current primary, and the write
  // all happen in one transaction.
  //
  // Two things were wrong before. The permission was read outside, so a
  // concurrent transfer or leave could invalidate it between the check and the
  // write. And the demotion targeted `callerFamilyRef` — the caller — which is
  // only the old primary when the caller happens to be it. An admin
  // transferring on somebody else's behalf demoted a document that does not
  // exist, and left the real old primary holding the role next to the new one.
  const outcome = await db.runTransaction<
    { kind: "done" } | { kind: "already"; uid: string }
  >(async (t) => {
    const authority = await readAuthorityInTransaction(t, petId, callerUid);
    if (!authority) {
      throw new HttpsError("not-found", "Pet not found.");
    }
    if (!authority.isPrimary && !isAdmin) {
      throw new HttpsError(
        "permission-denied",
        "Only the pet's primary owner can transfer the role."
      );
    }
    const target = authority.docs.find((docSnap) => docSnap.id === targetUserId);
    if (!target) {
      // Transfer is not an invitation. The recipient has to already be an
      // owner, which means they already went through redemption.
      throw new HttpsError(
        "failed-precondition",
        "That person is not part of this pet's family."
      );
    }
    if (
      target.data()?.role === "primary" &&
      authority.currentPrimaries.length === 1
    ) {
      return { kind: "already", uid: targetUserId };
    }

    t.update(petRef, {
      ownerId: targetUserId,
      primaryOwnerId: targetUserId,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    t.update(target.ref, {
      role: "primary",
      promotedAt: admin.firestore.FieldValue.serverTimestamp(),
      promotedReason: "transferred",
    });
    // Demote every current holder of the role, whoever they are. Not "the
    // caller": that is the assumption that produced two primaries. Iterating
    // also repairs a pet that already had more than one.
    //
    // The former primary stays an *owner* — equal to everybody else, which is
    // the point. Only the role moves.
    for (const docSnap of authority.currentPrimaries) {
      if (docSnap.id !== targetUserId) {
        t.update(docSnap.ref, { role: "member" });
      }
    }
    return { kind: "done" };
  });

  if (outcome.kind === "already") {
    return { success: true, alreadyPrimary: true };
  }

  const petName = await readPetName(petRef);
  await createNotificationIfAllowed(
    {
      userId: targetUserId,
      ...SYSTEM_NOTIFICATION_ACTOR,
      type: "pet_primary_transferred",
      // The granter is named in the body rather than in fromUserId: this is a
      // role change, and they are still around to be named.
      message: `${caller.fromUserName} made you the primary owner of ${petName}.`,
      petId,
    },
    { dedupeId: `pet_primary_${petId}_${targetUserId}` }
  ).catch(() => "");

  return { success: true, alreadyPrimary: false };
});
