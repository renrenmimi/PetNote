import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  assertFails,
  assertSucceeds,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  doc,
  getDoc,
  setDoc,
  updateDoc,
  deleteDoc,
  serverTimestamp,
} from "firebase/firestore";
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

  it("refuses to let even a real admin write role from the client", async () => {
    // Promotion is an owner operation via the console or the Admin SDK, both
    // of which bypass rules. No client path has ever needed it, so keeping it
    // unreachable costs nothing and means one compromised admin session cannot
    // mint more admins.
    const db = adminUser(env, ADMIN).firestore();
    await assertFails(
      setDoc(doc(db, `users/${BOB}/admin/state`), { role: "admin" })
    );
    await assertFails(
      setDoc(doc(db, `users/${BOB}/admin/state`), {
        role: "user",
        banned: true,
      })
    );
  });

  it("still lets an admin ban a user whose doc already carries a role", async () => {
    // The reason `role` stays in isAllowedAdminStateWrite's key allowlist.
    // request.resource.data on an update is the whole post-write document, so
    // removing role from hasOnly would not have blocked writing role — it
    // would have blocked banning anyone the Admin SDK had given one.
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `users/${BOB}/admin/state`), {
        role: "user",
      });
    });
    const db = adminUser(env, ADMIN).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `users/${BOB}/admin/state`), {
        banned: true,
        bannedReason: "spam",
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

describe("an admin custom claim is not sufficient on its own", () => {
  // isAdmin() used to return true on a positive `admin` claim alone. Nothing
  // revokes an already-issued ID token on demotion, and rules only check a
  // JWT's signature and expiry — not whether the claim inside it is still
  // true. These tests pin that the admin/state document is now the authority.

  it("grants nothing to a token claiming admin with no admin/state doc", async () => {
    // ALICE is seeded with a user doc but no admin/state — the shape of a
    // demoted admin whose doc was deleted, or a forged/stale token.
    const db = adminUser(env, ALICE).firestore();
    await assertFails(
      setDoc(doc(db, `users/${BOB}/admin/state`), { banned: true })
    );
    await assertFails(getDoc(doc(db, `users/${BOB}/admin/state`)));
  });

  it("does not let a demoted admin re-promote themselves on the stale claim", async () => {
    // The exploit, end to end. The owner demotes ALICE in the console; her ID
    // token keeps saying admin:true for up to an hour. Previously she could
    // write role:'admin' back to her own admin/state, and
    // onAdminStateWritten would re-issue the claim for real — making the
    // demotion permanently reversible by the person demoted.
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `users/${ALICE}/admin/state`), {
        role: "user",
      });
    });
    const db = adminUser(env, ALICE).firestore();
    await assertFails(
      updateDoc(doc(db, `users/${ALICE}/admin/state`), { role: "admin" })
    );
    await assertFails(
      setDoc(
        doc(db, `users/${ALICE}/admin/state`),
        { role: "admin" },
        { merge: true }
      )
    );
    // And the rest of what the stale claim used to buy is gone too.
    await assertFails(
      setDoc(doc(db, `users/${BOB}/admin/state`), { banned: true })
    );
  });

  it("recognises a real admin whose token carries no claim at all", async () => {
    // The other direction, which is why the document is read rather than
    // ANDed with the claim: a freshly promoted admin must not have to wait
    // out their old token. ADMIN holds role:'admin' in Firestore (seeded in
    // beforeEach) and plainUser gives a token with no custom claims.
    const db = plainUser(env, ADMIN).firestore();
    await assertSucceeds(
      setDoc(doc(db, `users/${BOB}/admin/state`), { banned: true })
    );
    await assertSucceeds(getDoc(doc(db, `users/${BOB}/admin/state`)));
  });
});

describe("a user document carrying legacy precise coordinates", () => {
  // Documents written before the private-location split still hold
  // location.lat/lng in the world-readable user doc. saveUserLocation writes
  // with setDoc(..., {merge:true}), which DEEP-merges nested maps, so those
  // coordinates survive the write. The old check ran hasOnly(city/state/
  // updatedAt) against the whole post-write document, so it failed — and
  // because it was applied to every update, it blocked writes that had
  // nothing to do with location at all.
  const LEGACY = "legacy-coords-user";
  const COORDS = { city: "Boston", state: "MA", lat: 42.3601, lng: -71.0589 };

  beforeEach(async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), "users", LEGACY), {
        displayName: LEGACY,
        location: { ...COORDS, updatedAt: new Date() },
      });
    });
  });

  it("can still be written to at all", async () => {
    // The live breakage. onboardingComplete has nothing to do with location,
    // and was rejected purely because the stale map failed the allowlist.
    const db = plainUser(env, LEGACY).firestore();
    await assertSucceeds(
      setDoc(doc(db, "users", LEGACY), { onboardingComplete: true }, { merge: true })
    );
  });

  it("accepts the city/state write Settings actually sends", async () => {
    // Exactly src/services/location.ts saveUserLocation: a merge that carries
    // only the safe keys. The inherited lat/lng survive the merge; that is the
    // privacy problem the migration fixes, not a reason to deny the write.
    const db = plainUser(env, LEGACY).firestore();
    await assertSucceeds(
      setDoc(
        doc(db, "users", LEGACY),
        { location: { city: "Cambridge", state: "MA", updatedAt: serverTimestamp() } },
        { merge: true }
      )
    );
  });

  it("still refuses a write that CHANGES the inherited coordinates", async () => {
    const db = plainUser(env, LEGACY).firestore();
    await assertFails(
      updateDoc(doc(db, "users", LEGACY), {
        location: { ...COORDS, lat: 1.234 },
      })
    );
  });

  it("lets a whole-map write drop the coordinates", async () => {
    // The shape the migration script uses, and the only way a client can
    // clean itself up. Removing lat/lng must not be mistaken for changing it.
    const db = plainUser(env, LEGACY).firestore();
    await assertSucceeds(
      updateDoc(doc(db, "users", LEGACY), {
        location: { city: "Boston", state: "MA" },
      })
    );
  });

  it("is still world-readable, which is what the migration has to fix", async () => {
    // Pinning the exposure rather than implying this change closed it. The
    // rules half stops the breakage; the coordinates are still there.
    const db = env.unauthenticatedContext().firestore();
    const snap = await assertSucceeds(getDoc(doc(db, "users", LEGACY)));
    expect(snap.data()?.location.lat).toBe(COORDS.lat);
  });
});

describe("a user document with no legacy coordinates", () => {
  it("still cannot have coordinates introduced", async () => {
    // The guard that must not be lost while unblocking the legacy documents.
    const db = plainUser(env, ALICE).firestore();
    await assertFails(
      updateDoc(doc(db, "users", ALICE), {
        location: { city: "Boston", state: "MA", lat: 42.36, lng: -71.06 },
      })
    );
  });
});
