import { afterAll, beforeAll, beforeEach, describe, it } from "vitest";
import {
  assertFails,
  assertSucceeds,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, getDoc, setDoc, updateDoc, deleteDoc } from "firebase/firestore";
import { adminUser, bannedUser, makeTestEnv, plainUser } from "./env";

// The rules are the last line of defence on user documents: everything that
// makes self-promotion to admin impossible lives in isAllowedUserUpdate and the
// admin/state match block. These tests exist to keep that true, not to discover
// that it currently is.

let env: RulesTestEnvironment;
const ALICE = "alice";
const BOB = "bob";
const ADMIN = "root-admin";

beforeAll(async () => {
  env = await makeTestEnv();
});
afterAll(async () => {
  await env.cleanup();
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const uid of [ALICE, BOB, ADMIN]) {
      await setDoc(doc(db, "users", uid), {
        displayName: uid,
        email: `${uid}@example.com`,
        onboardingComplete: true,
      });
    }
    await setDoc(doc(db, `users/${ADMIN}/admin/state`), { role: "admin" });
  });
});

describe("users/{uid} field allowlist", () => {
  it("lets the owner update only location and onboardingComplete", async () => {
    const db = plainUser(env, ALICE).firestore();
    await assertSucceeds(
      updateDoc(doc(db, "users", ALICE), { onboardingComplete: false })
    );
    await assertSucceeds(
      updateDoc(doc(db, "users", ALICE), {
        location: { city: "Boston", state: "MA" },
      })
    );
  });

  it("refuses to let a user grant themselves a role", async () => {
    const db = plainUser(env, ALICE).firestore();
    await assertFails(updateDoc(doc(db, "users", ALICE), { role: "admin" }));
  });

  it("refuses to let a user clear their own banned flag", async () => {
    const db = plainUser(env, ALICE).firestore();
    await assertFails(updateDoc(doc(db, "users", ALICE), { banned: false }));
  });

  it("refuses a role smuggled in alongside an allowed field", async () => {
    // hasOnly() is what makes this fail. A whitelist checked with a loop over
    // known-bad keys would pass this and be wrong.
    const db = plainUser(env, ALICE).firestore();
    await assertFails(
      updateDoc(doc(db, "users", ALICE), {
        onboardingComplete: true,
        role: "admin",
      })
    );
  });

  it("refuses identity fields that only callables may write", async () => {
    const db = plainUser(env, ALICE).firestore();
    await assertFails(updateDoc(doc(db, "users", ALICE), { displayName: "Root" }));
    await assertFails(updateDoc(doc(db, "users", ALICE), { email: "root@example.com" }));
    await assertFails(
      updateDoc(doc(db, "users", ALICE), { deletionPending: false })
    );
  });

  it("refuses a location shaped to smuggle precise coordinates", async () => {
    // hasSafePublicLocation restricts the map to city/state/updatedAt. Storing
    // lat/lng on the public user doc would expose a home address.
    const db = plainUser(env, ALICE).firestore();
    await assertFails(
      updateDoc(doc(db, "users", ALICE), {
        location: { city: "Boston", state: "MA", lat: 42.36, lng: -71.06 },
      })
    );
  });

  it("refuses to let one user write another user's document", async () => {
    const db = plainUser(env, BOB).firestore();
    await assertFails(
      updateDoc(doc(db, "users", ALICE), { onboardingComplete: false })
    );
  });

  it("refuses to let anyone delete a user document", async () => {
    // Deletion goes through the callable cascade so the subtree and Auth record
    // go with it; a direct delete would strand both.
    await assertFails(deleteDoc(doc(plainUser(env, ALICE).firestore(), "users", ALICE)));
    await assertFails(deleteDoc(doc(adminUser(env, ADMIN).firestore(), "users", ALICE)));
  });
});

describe("users/{uid}/admin/state", () => {
  it("refuses to let a non-admin create their own admin state", async () => {
    const db = plainUser(env, ALICE).firestore();
    await assertFails(
      setDoc(doc(db, `users/${ALICE}/admin/state`), { role: "admin" })
    );
  });

  it("refuses to let a non-admin unban themselves", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `users/${ALICE}/admin/state`), {
        banned: true,
      });
    });
    const db = plainUser(env, ALICE).firestore();
    await assertFails(
      updateDoc(doc(db, `users/${ALICE}/admin/state`), { banned: false })
    );
  });

  it("lets an admin ban someone, and only with allowlisted fields", async () => {
    const db = adminUser(env, ADMIN).firestore();
    await assertSucceeds(
      setDoc(doc(db, `users/${BOB}/admin/state`), {
        role: "user",
        banned: true,
        bannedReason: "spam",
        bannedAt: new Date(),
      })
    );
    await assertFails(
      setDoc(doc(db, `users/${BOB}/admin/state`), {
        banned: true,
        somethingElse: true,
      })
    );
  });

  it("lets a user read their own admin state but not someone else's", async () => {
    await assertSucceeds(
      getDoc(doc(plainUser(env, ALICE).firestore(), `users/${ALICE}/admin/state`))
    );
    await assertFails(
      getDoc(doc(plainUser(env, BOB).firestore(), `users/${ALICE}/admin/state`))
    );
  });

  it("refuses to let even an admin delete an admin state doc", async () => {
    await assertFails(
      deleteDoc(doc(adminUser(env, ADMIN).firestore(), `users/${ADMIN}/admin/state`))
    );
  });

  it("does not break a rule shaped isAdmin() || (own) for an ordinary user", async () => {
    // reports and feedback are read and deleted under exactly this shape. If
    // isAdmin() raised an evaluation error rather than returning false for a
    // user carrying no admin claim and holding no admin/state doc, the whole
    // OR would fail and an ordinary user would lose access to their own
    // record. That is #150 verbatim, and this pins it.
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), "feedback", "fb1"), {
        userId: ALICE,
        subject: "s",
        message: "m",
      });
    });
    const db = plainUser(env, ALICE).firestore();
    await assertSucceeds(getDoc(doc(db, "feedback", "fb1")));
    await assertSucceeds(deleteDoc(doc(db, "feedback", "fb1")));
  });

  it("treats a banned custom claim as banned without any Firestore state", async () => {
    // The token claim is the cheap path; the Firestore doc is the fallback for
    // a ban that has not propagated into the token yet. Both must deny.
    const db = bannedUser(env, ALICE).firestore();
    await assertFails(
      setDoc(doc(db, `users/${ALICE}/admin/state`), { role: "admin" })
    );
  });
});
