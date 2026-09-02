import "./setup";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import {
  createInvitationCallable,
  redeemInvitationCallable,
  validateInvitationCallable,
  removeFamilyMemberCallable,
} from "../invitations";
import { createPetCallable } from "../pets";
import { callAs, clearRateLimits, errorCodeOf } from "./helpers";

// Pet co-ownership is the one place in the product where an invitation code
// grants a stranger write access to someone else's pet. The interesting cases
// are all about who may mint a code, what a code is worth once used, and
// whether a family member can be added twice.

const OWNER = "inv-owner";
const FRIEND = "inv-friend";
const STRANGER = "inv-stranger";

type Invitation = { code: string; petId: string; used: boolean };

async function seedUser(uid: string, extra: Record<string, unknown> = {}) {
  await db.doc(`users/${uid}`).set({
    displayName: uid,
    email: `${uid}@example.com`,
    ...extra,
  });
}

async function wipe() {
  for (const c of ["users", "pets", "invitationCodes", "callableRateLimits", "notifications"]) {
    const snap = await db.collection(c).get();
    for (const d of snap.docs) await db.recursiveDelete(d.ref).catch(() => undefined);
  }
}

let petId: string;

beforeEach(async () => {
  await wipe();
  await clearRateLimits();
  for (const uid of [OWNER, FRIEND, STRANGER]) await seedUser(uid);
  const pet = await callAs<{ id?: string; petId?: string }>(createPetCallable, OWNER, {
    name: "Shared",
    species: "dog",
    gender: "female",
  });
  petId = (pet.id ?? pet.petId) as string;
});
afterAll(wipe);

const mint = () => callAs<Invitation>(createInvitationCallable, OWNER, { petId });

describe("minting an invitation", () => {
  it("lets a family member mint a code", async () => {
    const inv = await mint();
    expect(inv.code).toHaveLength(8);
    expect(inv.petId).toBe(petId);
    expect(inv.used).toBe(false);
  });

  it("refuses a stranger minting a code for someone else's pet", async () => {
    // Otherwise anyone could hand out write access to a pet they do not own.
    expect(
      await errorCodeOf(() => callAs(createInvitationCallable, STRANGER, { petId }))
    ).toBeTruthy();
  });

  it("refuses an unauthenticated caller", async () => {
    expect(
      await errorCodeOf(() => callAs(createInvitationCallable, null, { petId }))
    ).toContain("unauthenticated");
  });

  it("reuses the active code rather than minting a second one", async () => {
    const first = await mint();
    const second = await mint();
    expect(second.code).toBe(first.code);
  });

  it("uses an unambiguous alphabet", async () => {
    // No 0/O/1/I, because the code is read aloud and typed by hand.
    const inv = await mint();
    expect(inv.code).toMatch(/^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$/);
  });
});

describe("redeeming an invitation", () => {
  it("adds the redeemer to the pet family", async () => {
    const inv = await mint();
    await callAs(redeemInvitationCallable, FRIEND, {
      code: inv.code,
      relationship: "auntie",
    });
    const family = await db.doc(`pets/${petId}/family/${FRIEND}`).get();
    expect(family.exists).toBe(true);
    expect(family.data()?.relationship).toBe("auntie");
  });

  it("refuses a second redemption of the same code", async () => {
    const inv = await mint();
    await callAs(redeemInvitationCallable, FRIEND, { code: inv.code, relationship: "auntie" });
    expect(
      await errorCodeOf(() =>
        callAs(redeemInvitationCallable, STRANGER, { code: inv.code, relationship: "uncle" })
      )
    ).toBeTruthy();
    expect((await db.doc(`pets/${petId}/family/${STRANGER}`).get()).exists).toBe(false);
  });

  it("refuses a redeemer who is already family", async () => {
    const inv = await mint();
    expect(
      await errorCodeOf(() =>
        callAs(redeemInvitationCallable, OWNER, { code: inv.code, relationship: "dad" })
      )
    ).toContain("already-exists");
  });

  it("refuses an expired code", async () => {
    const inv = await mint();
    await db.doc(`pets/${petId}/invitations/${inv.code}`).update({
      expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() - 1000),
    });
    await db.doc(`invitationCodes/${inv.code}`).update({
      expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() - 1000),
    });
    expect(
      await errorCodeOf(() =>
        callAs(redeemInvitationCallable, FRIEND, { code: inv.code, relationship: "auntie" })
      )
    ).toBeTruthy();
  });

  it("refuses a code that was never issued", async () => {
    expect(
      await errorCodeOf(() =>
        callAs(redeemInvitationCallable, FRIEND, { code: "ZZZZZZZZ", relationship: "auntie" })
      )
    ).toContain("not-found");
  });

  it("refuses a malformed code without touching the family", async () => {
    for (const code of ["", "SHORT", "TOOLONGCODE123", undefined]) {
      expect(
        await errorCodeOf(() =>
          callAs(redeemInvitationCallable, FRIEND, { code, relationship: "auntie" })
        )
      ).toContain("invalid-argument");
    }
    expect((await db.doc(`pets/${petId}/family/${FRIEND}`).get()).exists).toBe(false);
  });

  it("refuses a relationship outside the allowed set", async () => {
    const inv = await mint();
    expect(
      await errorCodeOf(() =>
        callAs(redeemInvitationCallable, FRIEND, { code: inv.code, relationship: "owner" })
      )
    ).toContain("invalid-argument");
  });

  it("rejects an oversized custom relationship instead of storing it", async () => {
    // This is the one path where a direct call could stuff an unbounded string
    // into a pet document. It rejects rather than truncating, so nothing is
    // written at all.
    const inv = await mint();
    expect(
      await errorCodeOf(() =>
        callAs(redeemInvitationCallable, FRIEND, {
          code: inv.code,
          relationship: "other",
          customRelationship: "x".repeat(5000),
        })
      )
    ).toContain("invalid-argument");
    expect((await db.doc(`pets/${petId}/family/${FRIEND}`).get()).exists).toBe(false);
  });

  it("accepts a custom relationship within the cap", async () => {
    const inv = await mint();
    await callAs(redeemInvitationCallable, FRIEND, {
      code: inv.code,
      relationship: "other",
      customRelationship: "Dog walker",
    });
    const stored = (await db.doc(`pets/${petId}/family/${FRIEND}`).get()).data();
    expect(stored?.customRelationship).toBe("Dog walker");
  });
});

describe("validating a code before redeeming", () => {
  it("reports a live code with the pet name", async () => {
    const inv = await mint();
    const ok = await callAs<{ valid: boolean; petId?: string; petName?: string }>(
      validateInvitationCallable, FRIEND, { code: inv.code }
    );
    expect(ok.valid).toBe(true);
    expect(ok.petId).toBe(petId);
    expect(ok.petName).toBe("Shared");
  });

  it("returns valid:false for an unknown code rather than throwing", async () => {
    // Deliberate: an unknown code is a normal user typo, not an error, and the
    // response deliberately carries no pet information.
    const res = await callAs<{ valid: boolean; petId?: string; petName?: string }>(
      validateInvitationCallable, FRIEND, { code: "ZZZZZZZZ" }
    );
    expect(res.valid).toBe(false);
    expect(res.petId).toBeUndefined();
    expect(res.petName).toBeUndefined();
  });

  it("still rejects a malformed code outright", async () => {
    expect(
      await errorCodeOf(() => callAs(validateInvitationCallable, FRIEND, { code: "SHORT" }))
    ).toContain("invalid-argument");
  });
});

describe("removing a family member", () => {
  it("lets the primary owner remove someone they added", async () => {
    const inv = await mint();
    await callAs(redeemInvitationCallable, FRIEND, { code: inv.code, relationship: "auntie" });
    await callAs(removeFamilyMemberCallable, OWNER, { petId, targetUserId: FRIEND });
    expect((await db.doc(`pets/${petId}/family/${FRIEND}`).get()).exists).toBe(false);
  });

  it("lets a family member remove themselves", async () => {
    const inv = await mint();
    await callAs(redeemInvitationCallable, FRIEND, { code: inv.code, relationship: "auntie" });
    await callAs(removeFamilyMemberCallable, FRIEND, { petId, targetUserId: FRIEND });
    expect((await db.doc(`pets/${petId}/family/${FRIEND}`).get()).exists).toBe(false);
  });

  it("refuses a stranger removing a family member", async () => {
    const inv = await mint();
    await callAs(redeemInvitationCallable, FRIEND, { code: inv.code, relationship: "auntie" });
    expect(
      await errorCodeOf(() =>
        callAs(removeFamilyMemberCallable, STRANGER, { petId, targetUserId: FRIEND })
      )
    ).toBeTruthy();
    expect((await db.doc(`pets/${petId}/family/${FRIEND}`).get()).exists).toBe(true);
  });
});
