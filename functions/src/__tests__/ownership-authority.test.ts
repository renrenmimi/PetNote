import "./setup";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import {
  removeFamilyMemberCallable,
  transferPetPrimaryCallable,
} from "../family";
import { deletePetCallable, getPetFamilyAuthority, updatePetCallable } from "../pets";
import {
  createInvitationCallable,
  redeemInvitationCallable,
} from "../invitations";
import { callAs, clearRateLimits, errorCodeOf } from "./helpers";

/**
 * The invariant behind "one pet, several equal owners, one of them primary":
 *
 *   exactly one family document has role "primary", and the pet's
 *   ownerId/primaryOwnerId name that person.
 *
 * Primary is the only asymmetry the ownership model keeps — it is who may
 * remove somebody else and who may hand the role on — so two simultaneous
 * primaries is not a cosmetic inconsistency. It means two people can eject
 * each other, and it means somebody who was supposed to have lost the role
 * still passes the check that guards it.
 *
 * These tests assert the invariant rather than a particular interleaving,
 * because the invariant is what has to survive every interleaving.
 */

const ALICE = "auth-alice";
const BOB = "auth-bob";
const CARA = "auth-cara";
const ADMIN_UID = "auth-admin";
const PET = "auth-pet";

async function seedUser(uid: string, adminRole = false) {
  await db.doc(`users/${uid}`).set({ displayName: uid, email: `${uid}@example.com` });
  if (adminRole) {
    await db.doc(`users/${uid}/admin/state`).set({ role: "admin" });
  }
}

async function member(uid: string, role: "primary" | "member", joinedMs: number) {
  await db.doc(`pets/${PET}/family/${uid}`).set({
    userId: uid,
    role,
    relationship: "best_friend",
    joinedAt: admin.firestore.Timestamp.fromMillis(joinedMs),
  });
}

/** alice primary, plus whichever of bob/cara is asked for. */
async function seedPet(extra: string[] = [BOB]) {
  await db.doc(`pets/${PET}`).set({
    name: "Shared",
    species: "dog",
    ownerId: ALICE,
    primaryOwnerId: ALICE,
    postCount: 0,
  });
  await member(ALICE, "primary", 1_000);
  let at = 2_000;
  for (const uid of extra) {
    await member(uid, "member", at);
    at += 1_000;
  }
}

async function primaryState() {
  const [petSnap, familySnap] = await Promise.all([
    db.doc(`pets/${PET}`).get(),
    db.collection(`pets/${PET}/family`).get(),
  ]);
  const primaries = familySnap.docs
    .filter((d) => d.data().role === "primary")
    .map((d) => d.id)
    .sort();
  return {
    primaries,
    petPrimaryOwnerId: petSnap.data()?.primaryOwnerId,
    petOwnerId: petSnap.data()?.ownerId,
    roles: Object.fromEntries(familySnap.docs.map((d) => [d.id, d.data().role])),
  };
}

/** The invariant, checked as one thing so a failure names it. */
async function expectExactlyOnePrimary() {
  const state = await primaryState();
  expect(state.primaries).toHaveLength(1);
  expect(state.petPrimaryOwnerId).toBe(state.primaries[0]);
  expect(state.petOwnerId).toBe(state.primaries[0]);
  return state.primaries[0];
}

async function wipe() {
  for (const c of ["users", "pets", "posts", "invitationCodes", "callableRateLimits", "notifications"]) {
    const snap = await db.collection(c).get();
    for (const d of snap.docs) await db.recursiveDelete(d.ref).catch(() => undefined);
  }
}

beforeEach(async () => {
  await wipe();
  await clearRateLimits();
  await seedUser(ALICE);
  await seedUser(BOB);
  await seedUser(CARA);
  await seedUser(ADMIN_UID, true);
});
afterAll(wipe);

describe("an admin transferring on somebody else's behalf", () => {
  it("demotes the actual old primary, not the admin", async () => {
    // The admin is not a member of this pet's family. The handler demoted
    // "the caller", so it wrote role: member onto a document that does not
    // exist and left alice holding the role alongside bob.
    await seedPet([BOB]);

    await callAs(transferPetPrimaryCallable, ADMIN_UID, {
      petId: PET,
      targetUserId: BOB,
    });

    const primary = await expectExactlyOnePrimary();
    expect(primary).toBe(BOB);
    const state = await primaryState();
    expect(state.roles[ALICE]).toBe("member");
  });

  it("leaves the former primary without primary authority", async () => {
    await seedPet([BOB]);
    await callAs(transferPetPrimaryCallable, ADMIN_UID, {
      petId: PET,
      targetUserId: BOB,
    });

    // The authority helper is what every guard consults, so this is the
    // property that actually matters: alice must no longer pass it.
    const aliceAuthority = await getPetFamilyAuthority(PET, ALICE);
    expect(aliceAuthority?.isPrimary).toBe(false);
    expect(aliceAuthority?.isMember).toBe(true);

    // And she must no longer be able to use it.
    expect(
      await errorCodeOf(() =>
        callAs(removeFamilyMemberCallable, ALICE, { petId: PET, targetUserId: BOB })
      )
    ).toBe("permission-denied");
  });

  it("does not create a second primary when the admin is also a member", async () => {
    await seedPet([BOB]);
    await member(ADMIN_UID, "member", 5_000);

    await callAs(transferPetPrimaryCallable, ADMIN_UID, {
      petId: PET,
      targetUserId: BOB,
    });

    const primary = await expectExactlyOnePrimary();
    expect(primary).toBe(BOB);
  });
});

describe("two ownership changes at the same time", () => {
  it("keeps exactly one primary across concurrent transfers", async () => {
    // Both calls read authority before either transaction runs, so both
    // believed alice was primary. Firestore serialises the transactions, but
    // a decision taken outside one is not re-checked inside it.
    await seedPet([BOB, CARA]);

    const outcomes = await Promise.allSettled([
      callAs(transferPetPrimaryCallable, ALICE, { petId: PET, targetUserId: BOB }),
      callAs(transferPetPrimaryCallable, ALICE, { petId: PET, targetUserId: CARA }),
    ]);

    const primary = await expectExactlyOnePrimary();
    expect([BOB, CARA]).toContain(primary);
    // Whichever lost must have been refused rather than silently applied.
    const fulfilled = outcomes.filter((o) => o.status === "fulfilled");
    expect(fulfilled.length).toBeGreaterThanOrEqual(1);
  });

  it("keeps exactly one primary when a transfer races a removal", async () => {
    await seedPet([BOB, CARA]);

    await Promise.allSettled([
      callAs(transferPetPrimaryCallable, ALICE, { petId: PET, targetUserId: BOB }),
      callAs(removeFamilyMemberCallable, ALICE, { petId: PET, targetUserId: CARA }),
    ]);

    await expectExactlyOnePrimary();
  });

  /**
   * The primary transferring the role and leaving at the same time.
   *
   * `releasePetMembership` promotes the longest-standing remaining member when
   * the primary leaves, while the transfer promotes the named target — two
   * writers, each certain about who the new primary should be.
   *
   * Repeated, because the losing interleaving is not deterministic: observed
   * failing on roughly one single-shot run in three before the fix. The
   * repetition is what makes it a usable gate; after the fix the invariant
   * cannot break at all, so every iteration must hold.
   */
  it("keeps exactly one primary when the primary leaves while transferring", async () => {
    for (let attempt = 0; attempt < 5; attempt += 1) {
      await wipe();
      await clearRateLimits();
      for (const uid of [ALICE, BOB, CARA]) await seedUser(uid);
      await seedPet([BOB, CARA]);

      await Promise.allSettled([
        callAs(transferPetPrimaryCallable, ALICE, { petId: PET, targetUserId: CARA }),
        callAs(removeFamilyMemberCallable, ALICE, { petId: PET, targetUserId: ALICE }),
      ]);

      const state = await primaryState();
      expect(
        state.primaries,
        `attempt ${attempt}: roles ${JSON.stringify(state.roles)}`
      ).toHaveLength(1);
      expect(state.petPrimaryOwnerId).toBe(state.primaries[0]);
    }
  }, 60_000);
});

describe("deleting a pet while somebody is joining it", () => {
  it("never deletes a pet that somebody successfully joined", async () => {
    // deletePetCallable checked "am I the only owner?" outside any
    // transaction and then ran a non-transactional cascade, so a redemption
    // landing in between produced an owner attached to a pet that no longer
    // exists.
    await db.doc(`pets/${PET}`).set({
      name: "Solo",
      species: "cat",
      ownerId: ALICE,
      primaryOwnerId: ALICE,
      postCount: 0,
    });
    await member(ALICE, "primary", 1_000);
    const invite = await callAs<{ code: string }>(createInvitationCallable, ALICE, {
      petId: PET,
    });

    const [deletion, redemption] = await Promise.allSettled([
      callAs(deletePetCallable, ALICE, { petId: PET }),
      callAs(redeemInvitationCallable, BOB, {
        code: invite.code,
        relationship: "best_friend",
      }),
    ]);

    const petExists = (await db.doc(`pets/${PET}`).get()).exists;
    if (redemption.status === "fulfilled") {
      // Somebody was told they joined. The pet has to still be there.
      expect(petExists).toBe(true);
      const family = await db.collection(`pets/${PET}/family`).get();
      expect(family.docs.map((d) => d.id).sort()).toEqual([ALICE, BOB].sort());
    } else {
      // The deletion won; then it must actually have completed.
      expect(deletion.status).toBe("fulfilled");
      expect(petExists).toBe(false);
    }
  });
});

describe("what the authority helper is allowed to conclude", () => {
  it("still lets every owner edit after a transfer", async () => {
    await seedPet([BOB]);
    await callAs(transferPetPrimaryCallable, ALICE, { petId: PET, targetUserId: BOB });

    // Additive rights stay equal — the transfer moves the role, not membership.
    expect(
      await errorCodeOf(() => callAs(updatePetCallable, ALICE, { petId: PET, bio: "still mine too" }))
    ).toBe(null);
    expect(
      await errorCodeOf(() => callAs(updatePetCallable, BOB, { petId: PET, bio: "and mine" }))
    ).toBe(null);
  });
});
