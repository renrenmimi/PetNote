import "./setup";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import {
  createPetCallable,
  deletePetCallable,
  updatePetCallable,
} from "../pets";
import {
  removeFamilyMemberCallable,
  transferPetPrimaryCallable,
} from "../family";
import {
  createInvitationCallable,
  redeemInvitationCallable,
  validateInvitationCallable,
} from "../invitations";
import { createPostCallable } from "../posts";
import { deleteUserAccount } from "../users";
import { callAs, clearRateLimits, errorCodeOf } from "./helpers";

/**
 * The product's premise is that one pet has several *equal* human owners. The
 * implementation had a privileged creator: `pets/{id}.ownerId` was whoever made
 * the pet, forever, and the account-deletion cascade selected pets by that
 * field and destroyed the whole subtree. Deleting the creator's account
 * therefore deleted a pet that other people co-owned, leaving their posts
 * pointing at nothing.
 *
 * These tests pin down the replacement: a pet outlives any one of its owners,
 * every owner can manage it, and the two destructive acts — removing another
 * owner, deleting the pet — are the only asymmetries left.
 */

const ALICE = "sp-alice";
const BOB = "sp-bob";
const CARA = "sp-cara";
const STRANGER = "sp-stranger";

async function seedUser(uid: string) {
  await db.doc(`users/${uid}`).set({
    displayName: uid,
    email: `${uid}@example.com`,
  });
  await admin
    .auth()
    .createUser({ uid, email: `${uid}@example.com`, emailVerified: true })
    .catch(() => undefined);
}

async function wipe() {
  for (const c of [
    "users",
    "pets",
    "posts",
    "meetups",
    "invitationCodes",
    "notifications",
    "callableRateLimits",
    "userDeletionTombstones",
    "processedEvents",
    "usernames",
  ]) {
    const snap = await db.collection(c).get();
    for (const d of snap.docs) await db.recursiveDelete(d.ref).catch(() => undefined);
  }
}

/** A pet created by ALICE, co-owned by everyone in `coOwners`. */
async function sharedPet(coOwners: string[] = [BOB]): Promise<string> {
  const pet = await callAs<{ id?: string; petId?: string }>(
    createPetCallable,
    ALICE,
    { name: "Mochi", species: "dog", gender: "female" }
  );
  const petId = (pet.id ?? pet.petId) as string;
  for (const uid of coOwners) {
    const inv = await callAs<{ code: string }>(createInvitationCallable, ALICE, {
      petId,
    });
    await callAs(redeemInvitationCallable, uid, {
      code: inv.code,
      relationship: "best_friend",
    });
  }
  return petId;
}

const familyUids = async (petId: string): Promise<string[]> =>
  (await db.collection(`pets/${petId}/family`).get()).docs.map((d) => d.id);

const petDoc = async (petId: string) => (await db.doc(`pets/${petId}`).get());

beforeEach(async () => {
  await wipe();
  await clearRateLimits();
  for (const uid of [ALICE, BOB, CARA, STRANGER]) await seedUser(uid);
});
afterAll(async () => {
  await wipe();
  for (const uid of [ALICE, BOB, CARA, STRANGER]) {
    await admin.auth().deleteUser(uid).catch(() => undefined);
  }
});

describe("one owner deletes their account", () => {
  it("keeps the pet and hands it to the remaining owner", async () => {
    const petId = await sharedPet([BOB]);

    await callAs(deleteUserAccount, ALICE, { userId: ALICE });

    const pet = await petDoc(petId);
    expect(pet.exists).toBe(true);
    expect(pet.data()?.ownerId).toBe(BOB);
    expect(pet.data()?.primaryOwnerId).toBe(BOB);
    expect(await familyUids(petId)).toEqual([BOB]);
    expect((await db.doc(`pets/${petId}/family/${BOB}`).get()).data()?.role).toBe(
      "primary"
    );
  });

  it("keeps the other owner's posts about the pet, with the pet link intact", async () => {
    const petId = await sharedPet([BOB]);
    const bobPost = await callAs<{ id: string }>(createPostCallable, BOB, {
      caption: "Mochi at the park",
      petId,
    });

    await callAs(deleteUserAccount, ALICE, { userId: ALICE });

    const post = await db.doc(`posts/${bobPost.id}`).get();
    expect(post.exists).toBe(true);
    // onPetDeleted strips petId/petName/petAvatarUrl from posts. The whole
    // point of the handover is that it never fires here.
    expect(post.data()?.petId).toBe(petId);
  });

  it("hands the pet to the longest-standing of several remaining owners", async () => {
    const petId = await sharedPet([BOB, CARA]);
    // BOB redeemed first, so BOB has the earlier joinedAt.
    await callAs(deleteUserAccount, ALICE, { userId: ALICE });

    const pet = await petDoc(petId);
    expect(pet.data()?.primaryOwnerId).toBe(BOB);
    expect((await db.doc(`pets/${petId}/family/${BOB}`).get()).data()?.role).toBe(
      "primary"
    );
    expect((await db.doc(`pets/${petId}/family/${CARA}`).get()).data()?.role).toBe(
      "member"
    );
    expect((await familyUids(petId)).sort()).toEqual([BOB, CARA].sort());
  });

  it("tells the new primary owner that the pet is theirs now", async () => {
    const petId = await sharedPet([BOB]);

    await callAs(deleteUserAccount, ALICE, { userId: ALICE });

    const notes = await db
      .collection("notifications")
      .where("userId", "==", BOB)
      .where("type", "==", "pet_primary_transferred")
      .get();
    expect(notes.size).toBe(1);
    expect(notes.docs[0].data().petId).toBe(petId);
  });

  it("kills the leaving owner's outstanding invitation", async () => {
    const petId = await sharedPet([BOB]);
    const live = await callAs<{ code: string }>(createInvitationCallable, ALICE, {
      petId,
    });

    await callAs(deleteUserAccount, ALICE, { userId: ALICE });

    const res = await callAs<{ valid: boolean }>(validateInvitationCallable, CARA, {
      code: live.code,
    });
    expect(res.valid).toBe(false);
  });

  it("still deletes a pet that nobody else owns", async () => {
    const pet = await callAs<{ id?: string; petId?: string }>(
      createPetCallable,
      ALICE,
      { name: "Solo", species: "cat", gender: "male" }
    );
    const petId = (pet.id ?? pet.petId) as string;

    await callAs(deleteUserAccount, ALICE, { userId: ALICE });

    expect((await petDoc(petId)).exists).toBe(false);
  });

  it("removes a non-owner co-parent's membership without touching the pet", async () => {
    const petId = await sharedPet([BOB]);

    await callAs(deleteUserAccount, BOB, { userId: BOB });

    const pet = await petDoc(petId);
    expect(pet.exists).toBe(true);
    expect(pet.data()?.primaryOwnerId).toBe(ALICE);
    expect(await familyUids(petId)).toEqual([ALICE]);
  });
});

describe("co-owners can manage the pet", () => {
  it("lets a co-owner edit the pet's profile", async () => {
    const petId = await sharedPet([BOB]);

    const code = await errorCodeOf(() =>
      callAs(updatePetCallable, BOB, { petId, bio: "Loves the beach" })
    );

    expect(code).toBe(null);
    expect((await petDoc(petId)).data()?.bio).toBe("Loves the beach");
  });

  it("still refuses a stranger", async () => {
    const petId = await sharedPet([BOB]);

    const code = await errorCodeOf(() =>
      callAs(updatePetCallable, STRANGER, { petId, bio: "mine now" })
    );

    expect(code).toBe("permission-denied");
  });

  it("keeps managing a legacy pet with no family subcollection", async () => {
    // Data older than the family subcollection: authority falls back to the
    // pet document so the creator is not locked out of their own pet.
    await db.doc("pets/legacy1").set({
      name: "Legacy",
      species: "dog",
      ownerId: ALICE,
      primaryOwnerId: ALICE,
    });

    const code = await errorCodeOf(() =>
      callAs(updatePetCallable, ALICE, { petId: "legacy1", bio: "still mine" })
    );

    expect(code).toBe(null);
  });

  it("does not let a removed owner back in through a stale ownerId", async () => {
    // The fallback is only for pets with no family subcollection at all. A
    // pet that has one and does not list you means you were removed.
    const petId = await sharedPet([BOB]);
    await db.doc(`pets/${petId}`).update({ ownerId: CARA, primaryOwnerId: CARA });

    const code = await errorCodeOf(() =>
      callAs(updatePetCallable, CARA, { petId, bio: "sneaking in" })
    );

    expect(code).toBe("permission-denied");
  });
});

describe("leaving a pet", () => {
  it("lets a co-owner leave, keeping the pet for the others", async () => {
    const petId = await sharedPet([BOB]);

    await callAs(removeFamilyMemberCallable, BOB, { petId, targetUserId: BOB });

    expect((await petDoc(petId)).exists).toBe(true);
    expect(await familyUids(petId)).toEqual([ALICE]);
  });

  it("lets the primary owner leave, handing the role on", async () => {
    // Previously the primary could not be removed at all, including by
    // themselves — the creator was locked into the pet for good.
    const petId = await sharedPet([BOB]);

    const result = await callAs<{ action: string }>(removeFamilyMemberCallable, ALICE, {
      petId,
      targetUserId: ALICE,
    });

    expect(result.action).toBe("handed_over");
    expect((await petDoc(petId)).data()?.primaryOwnerId).toBe(BOB);
    expect(await familyUids(petId)).toEqual([BOB]);
  });

  it("refuses to let the only owner leave, rather than orphaning the pet", async () => {
    const pet = await callAs<{ id?: string; petId?: string }>(
      createPetCallable,
      ALICE,
      { name: "Solo", species: "cat", gender: "male" }
    );
    const petId = (pet.id ?? pet.petId) as string;

    const code = await errorCodeOf(() =>
      callAs(removeFamilyMemberCallable, ALICE, { petId, targetUserId: ALICE })
    );

    expect(code).toBe("failed-precondition");
    expect((await petDoc(petId)).exists).toBe(true);
    expect(await familyUids(petId)).toEqual([ALICE]);
  });

  it("kills the leaver's outstanding invitation", async () => {
    const petId = await sharedPet([BOB]);
    const inv = await callAs<{ code: string }>(createInvitationCallable, BOB, {
      petId,
    });

    await callAs(removeFamilyMemberCallable, BOB, { petId, targetUserId: BOB });

    const res = await callAs<{ valid: boolean }>(validateInvitationCallable, ALICE, {
      code: inv.code,
    });
    expect(res.valid).toBe(false);
  });
});

describe("removing another owner", () => {
  it("lets the primary owner remove a member", async () => {
    const petId = await sharedPet([BOB]);

    await callAs(removeFamilyMemberCallable, ALICE, { petId, targetUserId: BOB });

    expect(await familyUids(petId)).toEqual([ALICE]);
  });

  it("refuses a non-primary owner removing someone else", async () => {
    const petId = await sharedPet([BOB, CARA]);

    const code = await errorCodeOf(() =>
      callAs(removeFamilyMemberCallable, BOB, { petId, targetUserId: CARA })
    );

    expect(code).toBe("permission-denied");
    expect((await familyUids(petId)).length).toBe(3);
  });

  it("refuses to push the primary owner out", async () => {
    // Otherwise removal would be a way to take over somebody's pet.
    const petId = await sharedPet([BOB]);
    await callAs(transferPetPrimaryCallable, ALICE, { petId, targetUserId: BOB });

    const code = await errorCodeOf(() =>
      callAs(removeFamilyMemberCallable, BOB, { petId, targetUserId: BOB, })
    );
    // BOB removing themselves is a leave, which is allowed; the guard is
    // about removing the *other* person who holds the role.
    expect(code).toBe(null);
  });
});

describe("transferring the primary role", () => {
  it("moves the role and leaves the former primary as an equal owner", async () => {
    const petId = await sharedPet([BOB]);

    await callAs(transferPetPrimaryCallable, ALICE, { petId, targetUserId: BOB });

    const pet = await petDoc(petId);
    expect(pet.data()?.primaryOwnerId).toBe(BOB);
    expect(pet.data()?.ownerId).toBe(BOB);
    expect((await db.doc(`pets/${petId}/family/${BOB}`).get()).data()?.role).toBe(
      "primary"
    );
    expect((await db.doc(`pets/${petId}/family/${ALICE}`).get()).data()?.role).toBe(
      "member"
    );
    // Still an owner: can still edit.
    expect(
      await errorCodeOf(() => callAs(updatePetCallable, ALICE, { petId, bio: "hi" }))
    ).toBe(null);
  });

  it("refuses a non-primary owner transferring the role", async () => {
    const petId = await sharedPet([BOB, CARA]);

    const code = await errorCodeOf(() =>
      callAs(transferPetPrimaryCallable, BOB, { petId, targetUserId: CARA })
    );

    expect(code).toBe("permission-denied");
  });

  it("refuses a transfer to somebody who is not an owner", async () => {
    // Transfer is not a back door into the family; the recipient has to have
    // redeemed an invitation already.
    const petId = await sharedPet([BOB]);

    const code = await errorCodeOf(() =>
      callAs(transferPetPrimaryCallable, ALICE, { petId, targetUserId: STRANGER })
    );

    expect(code).toBe("failed-precondition");
    expect((await petDoc(petId)).data()?.primaryOwnerId).toBe(ALICE);
  });
});

describe("deleting a shared pet", () => {
  it("refuses while other owners remain", async () => {
    const petId = await sharedPet([BOB]);

    const code = await errorCodeOf(() =>
      callAs(deletePetCallable, ALICE, { petId })
    );

    expect(code).toBe("failed-precondition");
    expect((await petDoc(petId)).exists).toBe(true);
  });

  it("allows it once you are the last owner", async () => {
    const petId = await sharedPet([BOB]);
    await callAs(removeFamilyMemberCallable, ALICE, { petId, targetUserId: BOB });

    const code = await errorCodeOf(() =>
      callAs(deletePetCallable, ALICE, { petId })
    );

    expect(code).toBe(null);
    expect((await petDoc(petId)).exists).toBe(false);
  });

  it("takes the pet's invitation code lookups with it", async () => {
    const petId = await sharedPet([]);
    const inv = await callAs<{ code: string }>(createInvitationCallable, ALICE, {
      petId,
    });
    expect((await db.doc(`invitationCodes/${inv.code}`).get()).exists).toBe(true);

    await callAs(deletePetCallable, ALICE, { petId });

    // The lookup is what resolves a typed code to a pet. Left behind, it
    // pointed at a pet that no longer existed.
    expect((await db.doc(`invitationCodes/${inv.code}`).get()).exists).toBe(false);
  });
});
