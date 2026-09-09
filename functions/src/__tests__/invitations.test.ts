import "./setup";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import {
  createInvitationCallable,
  redeemInvitationCallable,
  revokeInvitationCallable,
  validateInvitationCallable,
} from "../invitations";
// removeFamilyMemberCallable moved to ../family with the shared-pet lifecycle
// work: losing family membership is an ownership event, not an invitation one.
import { removeFamilyMemberCallable } from "../family";
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

/**
 * An invitation is a standing grant of write access to somebody else's pet. It
 * used to be worth its full 48 hours no matter what happened to the person who
 * minted it, and there was no way to take one back: a member could mint a
 * code, be removed by the owner, and walk straight back in with the code they
 * had already saved.
 *
 * Two halves are tested here. Revocation is the eager half — removal kills the
 * codes, so the code also stops validating and stops being handed back. The
 * creator-authority check inside the redeem transaction is the half that holds
 * when removal and redemption race, and for any code that predates revocation.
 */
describe("an invitation outliving its author's authority", () => {
  it("stops working once the member who minted it is removed", async () => {
    const ownerInvite = await mint();
    await callAs(redeemInvitationCallable, FRIEND, {
      code: ownerInvite.code,
      relationship: "brother",
    });

    // FRIEND, now a member, mints their own code and keeps it.
    const friendInvite = await callAs<Invitation>(createInvitationCallable, FRIEND, {
      petId,
    });

    await callAs(removeFamilyMemberCallable, OWNER, { petId, targetUserId: FRIEND });

    const code = await errorCodeOf(() =>
      callAs(redeemInvitationCallable, FRIEND, {
        code: friendInvite.code,
        relationship: "brother",
      })
    );
    expect(code).toBe("failed-precondition");
    expect((await db.doc(`pets/${petId}/family/${FRIEND}`).get()).exists).toBe(false);
  });

  it("stops a third party redeeming the removed member's code too", async () => {
    const ownerInvite = await mint();
    await callAs(redeemInvitationCallable, FRIEND, {
      code: ownerInvite.code,
      relationship: "brother",
    });
    const friendInvite = await callAs<Invitation>(createInvitationCallable, FRIEND, {
      petId,
    });
    await callAs(removeFamilyMemberCallable, OWNER, { petId, targetUserId: FRIEND });

    // The point is the grant, not the person: the code is dead for anyone.
    const code = await errorCodeOf(() =>
      callAs(redeemInvitationCallable, STRANGER, {
        code: friendInvite.code,
        relationship: "best_friend",
      })
    );
    expect(code).toBe("failed-precondition");
    expect((await db.doc(`pets/${petId}/family/${STRANGER}`).get()).exists).toBe(
      false
    );
  });

  it("reports a revoked code as invalid before anyone types it in", async () => {
    const ownerInvite = await mint();
    await callAs(redeemInvitationCallable, FRIEND, {
      code: ownerInvite.code,
      relationship: "brother",
    });
    const friendInvite = await callAs<Invitation>(createInvitationCallable, FRIEND, {
      petId,
    });
    await callAs(removeFamilyMemberCallable, OWNER, { petId, targetUserId: FRIEND });

    const res = await callAs<{ valid: boolean }>(validateInvitationCallable, STRANGER, {
      code: friendInvite.code,
    });
    expect(res.valid).toBe(false);
  });

  it("refuses redemption when the author's membership vanished without revocation", async () => {
    // The transactional half, and the one that covers codes minted before
    // revocation existed: delete the family doc directly, leaving the
    // invitation itself untouched and still marked unused.
    const ownerInvite = await mint();
    await callAs(redeemInvitationCallable, FRIEND, {
      code: ownerInvite.code,
      relationship: "brother",
    });
    const friendInvite = await callAs<Invitation>(createInvitationCallable, FRIEND, {
      petId,
    });
    await db.doc(`pets/${petId}/family/${FRIEND}`).delete();

    const invitation = await db
      .doc(`pets/${petId}/invitations/${friendInvite.code}`)
      .get();
    expect(invitation.data()?.used).toBe(false);

    const code = await errorCodeOf(() =>
      callAs(redeemInvitationCallable, STRANGER, {
        code: friendInvite.code,
        relationship: "best_friend",
      })
    );
    expect(code).toBe("failed-precondition");
  });

  it("leaves the primary owner's own code alone when someone else is removed", async () => {
    const ownerInvite = await mint();
    await callAs(redeemInvitationCallable, FRIEND, {
      code: ownerInvite.code,
      relationship: "brother",
    });
    // A fresh owner-minted code, then FRIEND is removed.
    await db.doc(`pets/${petId}/invitations/${ownerInvite.code}`).set(
      { used: false, usedBy: admin.firestore.FieldValue.delete() },
      { merge: true }
    );
    await callAs(removeFamilyMemberCallable, OWNER, { petId, targetUserId: FRIEND });

    const res = await callAs<{ valid: boolean }>(validateInvitationCallable, STRANGER, {
      code: ownerInvite.code,
    });
    expect(res.valid).toBe(true);
  });
});

describe("revoking a code on purpose", () => {
  it("lets a family member kill the pet's outstanding code", async () => {
    const inv = await mint();

    await callAs(revokeInvitationCallable, OWNER, { petId, code: inv.code });

    expect(
      await errorCodeOf(() =>
        callAs(redeemInvitationCallable, STRANGER, {
          code: inv.code,
          relationship: "best_friend",
        })
      )
    ).toBe("failed-precondition");
  });

  it("frees the pet to mint a new code afterwards", async () => {
    const first = await mint();
    await callAs(revokeInvitationCallable, OWNER, { petId, code: first.code });

    const second = await mint();
    expect(second.code).not.toBe(first.code);
    const res = await callAs<{ valid: boolean }>(validateInvitationCallable, FRIEND, {
      code: second.code,
    });
    expect(res.valid).toBe(true);
  });

  it("refuses a stranger revoking someone else's pet's code", async () => {
    const inv = await mint();
    expect(
      await errorCodeOf(() =>
        callAs(revokeInvitationCallable, STRANGER, { petId, code: inv.code })
      )
    ).toBe("permission-denied");
    const res = await callAs<{ valid: boolean }>(validateInvitationCallable, FRIEND, {
      code: inv.code,
    });
    expect(res.valid).toBe(true);
  });

  it("is idempotent", async () => {
    const inv = await mint();
    await callAs(revokeInvitationCallable, OWNER, { petId, code: inv.code });
    const again = await callAs<{ success: boolean; alreadyInactive: boolean }>(
      revokeInvitationCallable,
      OWNER,
      { petId, code: inv.code }
    );
    expect(again.success).toBe(true);
    expect(again.alreadyInactive).toBe(true);
  });
});
