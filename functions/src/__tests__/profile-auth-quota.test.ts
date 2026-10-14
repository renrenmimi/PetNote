import "./setup";
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { admin, db } from "../platform";
import { ensureUserProfileCallable, updateUserProfileCallable } from "../users";
import { callAs, clearRateLimits, errorCodeOf, purge } from "./helpers";

// Both profile callables save the profile, then copy its name and photo onto
// the sign-in account. Two hundred people at once exceeded Auth's quota for
// account updates on the test project, and the callables answered "internal"
// for profiles that were saved. The copy is now skipped when the quota is the
// reason; any other failure still fails the call.

const NEWCOMER = "quota-newcomer";
const RENAMER = "quota-renamer";

const quotaExceeded = () =>
  Object.assign(new Error("Exceeded quota for updating account information."), { code: "auth/quota-exceeded" });

async function seedAuthUser(uid: string) {
  await admin.auth().deleteUser(uid).catch(() => undefined);
  await admin.auth().createUser({ uid, email: `${uid}@example.com`, emailVerified: true, displayName: uid });
}

async function clearNames() {
  const snap = await db.collection("usernames").where("userId", "in", [NEWCOMER, RENAMER]).get();
  await Promise.all(snap.docs.map((d) => d.ref.delete()));
}

beforeEach(async () => {
  await purge(`users/${NEWCOMER}`, `users/${RENAMER}`);
  await clearNames();
  await clearRateLimits();
  await seedAuthUser(NEWCOMER);
  await seedAuthUser(RENAMER);
  await callAs(ensureUserProfileCallable, RENAMER, { displayName: "Quota Renamer" });
});
afterEach(() => vi.restoreAllMocks());
afterAll(async () => {
  await purge(`users/${NEWCOMER}`, `users/${RENAMER}`);
  await clearNames();
  await clearRateLimits();
  await Promise.all([NEWCOMER, RENAMER].map((uid) => admin.auth().deleteUser(uid).catch(() => undefined)));
});

describe("a profile saved while Auth's quota for account updates is exceeded", () => {
  it("is made, and the sign-up does not fail", async () => {
    vi.spyOn(admin.auth(), "updateUser").mockRejectedValue(quotaExceeded());

    const code = await errorCodeOf(() => callAs(ensureUserProfileCallable, NEWCOMER, { displayName: "Quota Newcomer" }));

    expect(code).toBeNull();
    expect((await db.doc(`users/${NEWCOMER}`).get()).get("displayName")).toBe("Quota Newcomer");
  });

  it("is renamed, and the rename does not fail", async () => {
    vi.spyOn(admin.auth(), "updateUser").mockRejectedValue(quotaExceeded());

    const code = await errorCodeOf(() => callAs(updateUserProfileCallable, RENAMER, { displayName: "Quota Renamed" }));

    expect(code).toBeNull();
    expect((await db.doc(`users/${RENAMER}`).get()).get("displayName")).toBe("Quota Renamed");
  });

  it("still fails the rename when the account copy fails for another reason", async () => {
    vi.spyOn(admin.auth(), "updateUser").mockRejectedValue(Object.assign(new Error("boom"), { code: "auth/internal-error" }));

    const code = await errorCodeOf(() => callAs(updateUserProfileCallable, RENAMER, { displayName: "Quota Renamed Again" }));

    expect(code).toBe("auth/internal-error");
  });
});
