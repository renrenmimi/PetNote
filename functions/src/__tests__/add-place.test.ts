import "./setup";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import { addPlaceCallable } from "../places";
import { callAs, clearRateLimits, errorCodeOf } from "./helpers";

// addPlaceCallable takes two shapes. The web's carries a name, address and
// coordinates (from Geoapify). A place found on Apple Maps carries only its
// identifier and our own fields, because Apple's terms let us keep the
// identifier but not what comes with it (Attachment 6, 2.2 and 2.5).

const ADDER = "place-adder";
const APPLE_ID = "I1A2B3C4D5E6F7A8B";

async function seedAdder() {
  await admin.auth().createUser({
    uid: ADDER,
    email: `${ADDER}@example.com`,
    emailVerified: true,
    displayName: ADDER,
  });
  await db.doc(`users/${ADDER}`).set({
    displayName: "Place Adder",
    email: `${ADDER}@example.com`,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
}

async function wipe() {
  for (const c of ["users", "locations", "callableRateLimits"]) {
    const snap = await db.collection(c).get();
    for (const d of snap.docs) await db.recursiveDelete(d.ref).catch(() => undefined);
  }
  const users = await admin.auth().listUsers(1000);
  await Promise.all(
    users.users.map((u) => admin.auth().deleteUser(u.uid).catch(() => undefined))
  );
}

const applePlace = (extra: Record<string, unknown> = {}) => ({
  applePlaceId: APPLE_ID,
  category: "dog_park",
  description: "Fenced, with a water fountain.",
  features: ["fenced", "water_access", "not_a_feature"],
  ...extra,
});

beforeEach(async () => {
  await wipe();
  await clearRateLimits();
  await seedAdder();
});
afterAll(wipe);

describe("a place found on Apple Maps", () => {
  it("is saved by its identifier and our own fields, and nothing of Apple's", async () => {
    const res = await callAs<{ locationId: string; alreadyExisted: boolean }>(
      addPlaceCallable,
      ADDER,
      applePlace()
    );

    expect(res).toEqual({ locationId: `apple_${APPLE_ID}`, alreadyExisted: false });
    const place = (await db.doc(`locations/apple_${APPLE_ID}`).get()).data() ?? {};
    expect(place.applePlaceId).toBe(APPLE_ID);
    expect(place.category).toBe("dog_park");
    expect(place.description).toBe("Fenced, with a water fountain.");
    expect(place.features).toEqual(["fenced", "water_access"]);
    expect(place.source).toBe("user");
    expect(place.addedBy).toBe(ADDER);
    for (const field of ["name", "address", "lat", "lng", "city", "state"]) {
      expect(place[field], field).toBeUndefined();
    }
  });

  it("is one place however many times it is added", async () => {
    await callAs(addPlaceCallable, ADDER, applePlace());
    const again = await callAs<{ locationId: string; alreadyExisted: boolean }>(
      addPlaceCallable,
      ADDER,
      applePlace({ description: "Someone else's words." })
    );

    expect(again).toEqual({ locationId: `apple_${APPLE_ID}`, alreadyExisted: true });
    expect((await db.collection("locations").get()).size).toBe(1);
    // The first one stands; a second add does not overwrite it.
    expect((await db.doc(`locations/apple_${APPLE_ID}`).get()).get("description")).toBe(
      "Fenced, with a water fountain."
    );
  });

  it("refuses a name, address or coordinates sent with the identifier", async () => {
    for (const [field, value] of Object.entries({
      name: "Riverside Dog Park",
      address: "1 River St",
      lat: 42.36,
      lng: -71.09,
      city: "Cambridge",
      state: "MA",
    })) {
      const code = await errorCodeOf(() =>
        callAs(addPlaceCallable, ADDER, applePlace({ [field]: value }))
      );
      expect(code, field).toBe("invalid-argument");
    }
    expect((await db.collection("locations").get()).size).toBe(0);
  });

  it("refuses an identifier that is not one", async () => {
    for (const bad of ["", "short", "has space in it", "a/b/c/d/e/f/g", "x".repeat(65), 12345678]) {
      const code = await errorCodeOf(() =>
        callAs(addPlaceCallable, ADDER, applePlace({ applePlaceId: bad }))
      );
      expect(code, String(bad)).toBe("invalid-argument");
    }
    expect((await db.collection("locations").get()).size).toBe(0);
  });

  it("asks for a verified email, as every other place does", async () => {
    const code = await errorCodeOf(() =>
      callAs(addPlaceCallable, ADDER, applePlace(), { emailVerified: false })
    );
    expect(code).toBe("permission-denied");
  });
});

describe("the web's shape", () => {
  it("still saves the name, address and coordinates it carries", async () => {
    const res = await callAs<{ locationId: string; alreadyExisted: boolean }>(
      addPlaceCallable,
      ADDER,
      {
        name: "Harbor Cafe",
        address: "2 Harbor Way, Boston, MA",
        lat: 42.3551,
        lng: -71.0489,
        city: "Boston",
        state: "MA",
        category: "cafe",
      }
    );

    expect(res.alreadyExisted).toBe(false);
    expect(res.locationId.startsWith("apple_")).toBe(false);
    const place = (await db.doc(`locations/${res.locationId}`).get()).data() ?? {};
    expect(place.name).toBe("Harbor Cafe");
    expect(place.address).toBe("2 Harbor Way, Boston, MA");
    expect(place.lat).toBe(42.3551);
    expect(place.lng).toBe(-71.0489);
    expect(place.category).toBe("cafe");
    expect(place.applePlaceId).toBeUndefined();
  });
});
