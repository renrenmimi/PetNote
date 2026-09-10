import "./setup";
import { afterAll, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * A pet deletion that fails halfway.
 *
 * `deletePetCallable` deletes the pet document inside a transaction — which is
 * what closed the join/delete race — and then runs the subcollection cascade
 * outside it, because a recursive delete cannot be held in a transaction. That
 * split leaves a window with no durable record of what still has to happen: if
 * the cascade fails, the pet document is already gone, and a retry sees no pet,
 * concludes there is nothing to do, and reports success over family, followers
 * and invitation documents that are still there.
 *
 * The recovery has to keep the *authorisation* too. "The parent is missing, so
 * anyone may clean up its children" would be a way for an unrelated account to
 * finish somebody else's deletion, so the record says who asked.
 */

// Hoisted so the vi.mock factory below can see it.
const cascade = vi.hoisted(() => ({ failNext: false, calls: [] as string[] }));

vi.mock("../cleanup", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../cleanup")>();
  return {
    ...actual,
    cascadeDeletePet: async (petId: string) => {
      cascade.calls.push(petId);
      if (cascade.failNext) {
        cascade.failNext = false;
        throw new Error("injected transient cleanup failure");
      }
      return actual.cascadeDeletePet(petId);
    },
  };
});

const { admin, db } = await import("../platform");
const { deletePetCallable } = await import("../pets");
const { callAs, clearRateLimits, errorCodeOf } = await import("./helpers");

const OWNER = "del-owner";
const STRANGER = "del-stranger";
const ADMIN_UID = "del-admin";
const PET = "del-pet";

async function seedUser(uid: string, adminRole = false) {
  await db.doc(`users/${uid}`).set({ displayName: uid, email: `${uid}@example.com` });
  if (adminRole) await db.doc(`users/${uid}/admin/state`).set({ role: "admin" });
}

async function seedSolePet() {
  await db.doc(`pets/${PET}`).set({
    name: "Solo",
    species: "dog",
    ownerId: OWNER,
    primaryOwnerId: OWNER,
    postCount: 0,
  });
  await db.doc(`pets/${PET}/family/${OWNER}`).set({
    userId: OWNER,
    role: "primary",
    joinedAt: admin.firestore.Timestamp.fromMillis(1_000),
  });
  await db.doc(`pets/${PET}/followers/someone`).set({ userId: "someone" });
  await db.doc(`pets/${PET}/invitations/ABCD2345`).set({
    code: "ABCD2345",
    createdBy: OWNER,
    used: false,
    expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + 86_400_000),
  });
  await db.doc("invitationCodes/ABCD2345").set({ code: "ABCD2345", petId: PET });
}

async function leftovers() {
  const [family, followers, invitations, lookups] = await Promise.all([
    db.collection(`pets/${PET}/family`).get(),
    db.collection(`pets/${PET}/followers`).get(),
    db.collection(`pets/${PET}/invitations`).get(),
    db.collection("invitationCodes").where("petId", "==", PET).get(),
  ]);
  return {
    family: family.size,
    followers: followers.size,
    invitations: invitations.size,
    lookups: lookups.size,
  };
}

async function wipe() {
  for (const c of ["users", "pets", "invitationCodes", "callableRateLimits", "petDeletionTasks"]) {
    const snap = await db.collection(c).get();
    for (const d of snap.docs) await db.recursiveDelete(d.ref).catch(() => undefined);
  }
}

beforeEach(async () => {
  cascade.failNext = false;
  cascade.calls.length = 0;
  await wipe();
  await clearRateLimits();
  await seedUser(OWNER);
  await seedUser(STRANGER);
  await seedUser(ADMIN_UID, true);
});
afterAll(wipe);

describe("a cascade that fails after the pet document is gone", () => {
  it("reports the failure instead of claiming success", async () => {
    await seedSolePet();
    cascade.failNext = true;

    const code = await errorCodeOf(() => callAs(deletePetCallable, OWNER, { petId: PET }));

    expect(code).not.toBe(null);
    expect((await db.doc(`pets/${PET}`).get()).exists).toBe(false);
  });

  it("finishes the cleanup when the requester retries", async () => {
    await seedSolePet();
    cascade.failNext = true;
    await errorCodeOf(() => callAs(deletePetCallable, OWNER, { petId: PET }));

    // Everything under the pet is still there, and the pet itself is gone —
    // exactly the state a retry used to walk away from.
    expect(await leftovers()).toEqual({
      family: 1,
      followers: 1,
      invitations: 1,
      lookups: 1,
    });

    await callAs(deletePetCallable, OWNER, { petId: PET });

    expect(await leftovers()).toEqual({
      family: 0,
      followers: 0,
      invitations: 0,
      lookups: 0,
    });
  });

  it("lets an admin finish somebody else's interrupted deletion", async () => {
    await seedSolePet();
    cascade.failNext = true;
    await errorCodeOf(() => callAs(deletePetCallable, OWNER, { petId: PET }));

    await callAs(deletePetCallable, ADMIN_UID, { petId: PET });

    expect(await leftovers()).toEqual({
      family: 0,
      followers: 0,
      invitations: 0,
      lookups: 0,
    });
  });

  it("does not let an unrelated account finish it", async () => {
    // The parent document being absent must not become an authorisation.
    await seedSolePet();
    cascade.failNext = true;
    await errorCodeOf(() => callAs(deletePetCallable, OWNER, { petId: PET }));
    const before = await leftovers();

    await callAs(deletePetCallable, STRANGER, { petId: PET });

    expect(await leftovers()).toEqual(before);
  });

  it("clears the recovery record once the cleanup completes", async () => {
    await seedSolePet();
    cascade.failNext = true;
    await errorCodeOf(() => callAs(deletePetCallable, OWNER, { petId: PET }));
    expect((await db.doc(`petDeletionTasks/${PET}`).get()).exists).toBe(true);

    await callAs(deletePetCallable, OWNER, { petId: PET });

    expect((await db.doc(`petDeletionTasks/${PET}`).get()).exists).toBe(false);
  });
});

describe("a deletion that succeeds first time", () => {
  it("leaves nothing behind, including the recovery record", async () => {
    await seedSolePet();

    await callAs(deletePetCallable, OWNER, { petId: PET });

    expect((await db.doc(`pets/${PET}`).get()).exists).toBe(false);
    expect(await leftovers()).toEqual({
      family: 0,
      followers: 0,
      invitations: 0,
      lookups: 0,
    });
    expect((await db.doc(`petDeletionTasks/${PET}`).get()).exists).toBe(false);
  });

  it("is still a no-op for a pet that never existed", async () => {
    const code = await errorCodeOf(() =>
      callAs(deletePetCallable, OWNER, { petId: "never-existed" })
    );
    expect(code).toBe(null);
    expect(cascade.calls).not.toContain("never-existed");
  });
});
