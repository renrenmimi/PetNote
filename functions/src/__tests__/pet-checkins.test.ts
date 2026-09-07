import "./setup";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import { getPetCheckinsCallable } from "../places";
import { callAs, clearRateLimits, errorCodeOf } from "./helpers";

// The checkins collection group is now scoped to the requesting user, which
// closed the petId route along with the userId one — a petId-filtered
// collection-group query can return other people's documents, so Firestore
// refuses it. The pet profile reads its history through this callable instead.
//
// It stays PUBLIC: check-ins are content the user chose to publish and the pet
// page has always shown them. What changed is that harvesting now costs a
// capped, rate-limited call per pet rather than one unbounded query, and the
// response carries no user identity at all.

const OWNER = "checkin-owner";
const PET = "checkin-pet";
const OTHER_PET = "other-pet";
const PLACE = "checkin-place";

async function wipe() {
  for (const c of ["users", "pets", "locations", "callableRateLimits"]) {
    const snap = await db.collection(c).get();
    for (const d of snap.docs) await db.recursiveDelete(d.ref).catch(() => undefined);
  }
  const users = await admin.auth().listUsers(1000);
  await Promise.all(
    users.users.map((u) => admin.auth().deleteUser(u.uid).catch(() => undefined))
  );
}

/** Seeds `count` check-ins for a pet, oldest first so ordering is testable. */
async function seedCheckins(petId: string, count: number) {
  for (let i = 0; i < count; i += 1) {
    await db.doc(`locations/${PLACE}/checkins/${petId}_${i}`).set({
      counted: true,
      userId: OWNER,
      userName: "Owner Name",
      userAvatar: "https://api.dicebear.com/7.x/thumbs/svg?seed=owner",
      petId,
      petName: "Rex",
      photoUrl: `https://res.cloudinary.com/c/image/upload/petnote/${petId}-${i}.jpg`,
      caption: `visit ${i}`,
      locationId: PLACE,
      createdAt: admin.firestore.Timestamp.fromMillis(
        Date.UTC(2026, 0, 1) + i * 86_400_000
      ),
    });
  }
}

beforeEach(async () => {
  await wipe();
  await clearRateLimits();
  await db.doc(`users/${OWNER}`).set({ displayName: OWNER });
  await db.doc(`pets/${PET}`).set({ name: "Rex", ownerId: OWNER });
  await db.doc(`locations/${PLACE}`).set({ name: "Dog Park" });
});
afterAll(wipe);

type Res = {
  checkins: Array<Record<string, unknown>>;
};

describe("getPetCheckinsCallable", () => {
  it("returns a pet's check-ins without being logged in", async () => {
    // The whole point of the callable: the pet page is public and stays public.
    await seedCheckins(PET, 3);
    const res = await callAs<Res>(getPetCheckinsCallable, null, { petId: PET });
    expect(res.checkins).toHaveLength(3);
  });

  it("returns them newest first", async () => {
    await seedCheckins(PET, 3);
    const res = await callAs<Res>(getPetCheckinsCallable, null, { petId: PET });
    const times = res.checkins.map((c) => c.createdAtMillis as number);
    expect(times).toEqual([...times].sort((a, b) => b - a));
  });

  it("carries no user identity at all", async () => {
    // The pet page never rendered userId / userName / userAvatar, so a public
    // endpoint has no reason to hand them out. Omitting them means this route
    // cannot be turned back into a per-person lookup even in aggregate.
    await seedCheckins(PET, 1);
    const res = await callAs<Res>(getPetCheckinsCallable, null, { petId: PET });
    const [row] = res.checkins;
    expect(row).not.toHaveProperty("userId");
    expect(row).not.toHaveProperty("userName");
    expect(row).not.toHaveProperty("userAvatar");
    expect(JSON.stringify(res)).not.toContain(OWNER);
    expect(JSON.stringify(res)).not.toContain("Owner Name");
    // And it still carries what the page does render.
    expect(row.photoUrl).toContain("res.cloudinary.com");
    expect(row.locationId).toBe(PLACE);
    expect(row.caption).toBe("visit 0");
  });

  it("caps the row count however many are asked for", async () => {
    // Without a ceiling, one rate-limited call becomes an unbounded dump.
    await seedCheckins(PET, 12);
    const res = await callAs<Res>(getPetCheckinsCallable, null, {
      petId: PET,
      limitCount: 100000,
    });
    expect(res.checkins.length).toBeLessThanOrEqual(100);
    expect(res.checkins).toHaveLength(12);
  });

  it("honours a smaller limit, and refuses a nonsense one gracefully", async () => {
    await seedCheckins(PET, 5);
    const few = await callAs<Res>(getPetCheckinsCallable, null, {
      petId: PET,
      limitCount: 2,
    });
    expect(few.checkins).toHaveLength(2);

    const zero = await callAs<Res>(getPetCheckinsCallable, null, {
      petId: PET,
      limitCount: 0,
    });
    expect(zero.checkins).toHaveLength(1);

    const nan = await callAs<Res>(getPetCheckinsCallable, null, {
      petId: PET,
      limitCount: Number.NaN,
    });
    expect(nan.checkins.length).toBeGreaterThan(0);
  });

  it("does not leak another pet's check-ins", async () => {
    await seedCheckins(PET, 2);
    await seedCheckins(OTHER_PET, 2);
    const res = await callAs<Res>(getPetCheckinsCallable, null, { petId: PET });
    expect(res.checkins).toHaveLength(2);
    for (const row of res.checkins) expect(row.petId).toBe(PET);
  });

  it("rejects a petId that is not a document id", async () => {
    // requiredDocId: a value with slashes would otherwise be interpolated
    // into a path and reach a different collection.
    expect(
      await errorCodeOf(() =>
        callAs(getPetCheckinsCallable, null, { petId: "pets/x/family/y" })
      )
    ).toBe("invalid-argument");
    expect(
      await errorCodeOf(() => callAs(getPetCheckinsCallable, null, {}))
    ).toBe("invalid-argument");
  });

  it("returns an empty list for a pet with no check-ins", async () => {
    const res = await callAs<Res>(getPetCheckinsCallable, null, { petId: PET });
    expect(res.checkins).toEqual([]);
  });
});
