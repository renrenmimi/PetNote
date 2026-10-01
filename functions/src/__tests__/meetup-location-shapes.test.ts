import "./setup";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import { createMeetupCallable, updateMeetupCallable } from "../meetups";
import { callAs, clearRateLimits, errorCodeOf } from "./helpers";

// A meetup's location comes in three shapes: the web's (name, address and
// coordinates from Geoapify), a place found on Apple Maps (its identifier
// only), and an address the organiser typed. These pin what each becomes on
// the public document, in private/address, and in the places it links to.
// The web's shape is covered by meetup-privacy.test.ts.

const ORGANIZER = "shapes-organizer";
const APPLE_ID = "I0F1E2D3C4B5A6978";
const TYPED = "12 Elm St, Somerville, MA";

async function seedOrganizer() {
  await admin.auth().createUser({
    uid: ORGANIZER,
    email: `${ORGANIZER}@example.com`,
    emailVerified: true,
    displayName: ORGANIZER,
  });
  await db.doc(`users/${ORGANIZER}`).set({
    displayName: ORGANIZER,
    email: `${ORGANIZER}@example.com`,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
}

async function wipe() {
  for (const c of ["users", "meetups", "locations", "callableRateLimits", "notifications"]) {
    const snap = await db.collection(c).get();
    for (const d of snap.docs) await db.recursiveDelete(d.ref).catch(() => undefined);
  }
  const users = await admin.auth().listUsers(1000);
  await Promise.all(
    users.users.map((u) => admin.auth().deleteUser(u.uid).catch(() => undefined))
  );
}

const payload = (
  location: Record<string, unknown>,
  locationVisibility: "everyone" | "participants_only"
) => ({
  title: "Morning walk",
  description: "Bring water.",
  dateMillis: Date.now() + 3 * 24 * 60 * 60 * 1000,
  duration: 60,
  locationVisibility,
  location,
});

const applePlace = { kind: "applePlace", applePlaceId: APPLE_ID, area: "Somerville" };
const typedAddress = { kind: "address", address: TYPED, label: "Alex's backyard", area: "Somerville" };

async function create(location: Record<string, unknown>, visibility: "everyone" | "participants_only") {
  const res = await callAs<{ id?: string; meetupId?: string }>(
    createMeetupCallable,
    ORGANIZER,
    payload(location, visibility)
  );
  const id = (res.id ?? res.meetupId) as string;
  const meetup = (await db.doc(`meetups/${id}`).get()).data() ?? {};
  const privateSnap = await db.doc(`meetups/${id}/private/address`).get();
  return { id, meetup, privateAddress: privateSnap.exists ? privateSnap.data() : undefined };
}

const placeCount = async () => (await db.collection("locations").get()).size;

beforeEach(async () => {
  await wipe();
  await clearRateLimits();
  await seedOrganizer();
});
afterAll(wipe);

describe("a meetup at a place found on Apple Maps", () => {
  it("in public keeps the identifier and links a place made of the identifier alone", async () => {
    const { meetup, privateAddress } = await create(applePlace, "everyone");

    expect(meetup.location).toEqual({ applePlaceId: APPLE_ID });
    expect(meetup.locationId).toBe(`apple_${APPLE_ID}`);
    expect(privateAddress).toBeUndefined();
    const place = (await db.doc(`locations/apple_${APPLE_ID}`).get()).data() ?? {};
    expect(place.applePlaceId).toBe(APPLE_ID);
    expect(place.source).toBe("meetup");
    for (const field of ["name", "address", "lat", "lng", "city", "state"]) {
      expect(place[field], field).toBeUndefined();
    }
  });

  it("in private shows the organiser's area and keeps the identifier where only the people going can read it", async () => {
    const { meetup, privateAddress } = await create(applePlace, "participants_only");

    expect(meetup.location).toEqual({ name: "Meetup near Somerville", area: "Somerville" });
    expect(JSON.stringify(meetup)).not.toContain(APPLE_ID);
    expect(meetup.locationId).toBeUndefined();
    expect(privateAddress).toEqual({ applePlaceId: APPLE_ID });
    expect(await placeCount()).toBe(0);
  });
});

describe("a meetup at an address the organiser typed", () => {
  it("in public keeps their words and makes no place", async () => {
    const { meetup, privateAddress } = await create(typedAddress, "everyone");

    expect(meetup.location).toEqual({ address: TYPED, label: "Alex's backyard" });
    expect(meetup.locationId).toBeUndefined();
    expect(privateAddress).toBeUndefined();
    expect(await placeCount()).toBe(0);
  });

  it("in private shows only the area, and the address is in private/address", async () => {
    const { meetup, privateAddress } = await create(typedAddress, "participants_only");

    expect(meetup.location).toEqual({ name: "Meetup near Somerville", area: "Somerville" });
    expect(JSON.stringify(meetup)).not.toContain("Elm");
    expect(privateAddress).toEqual({ address: TYPED, label: "Alex's backyard" });
    expect(await placeCount()).toBe(0);
  });

  it("in private with no area named says only that it is private", async () => {
    const { meetup } = await create({ kind: "address", address: TYPED }, "participants_only");
    expect(meetup.location).toEqual({ name: "Private meetup", area: "" });
  });
});

describe("a location in the wrong shape", () => {
  it("is refused, and nothing is written", async () => {
    const wrong: Array<[string, Record<string, unknown>]> = [
      ["Apple with coordinates", { ...applePlace, lat: 42.36, lng: -71.09 }],
      ["Apple with a name", { ...applePlace, name: "Riverside Dog Park" }],
      ["Apple with an address", { ...applePlace, address: TYPED }],
      ["Apple with a city", { ...applePlace, city: "Somerville" }],
      ["Apple with a bad identifier", { kind: "applePlace", applePlaceId: "a/b" }],
      ["an address with coordinates", { ...typedAddress, lat: 42.36, lng: -71.09 }],
      ["an address with an identifier", { ...typedAddress, applePlaceId: APPLE_ID }],
      ["an address with no address", { kind: "address", label: "Somewhere" }],
      ["a kind nobody knows", { kind: "teleport", address: TYPED }],
    ];
    for (const [label, location] of wrong) {
      const code = await errorCodeOf(() =>
        callAs(createMeetupCallable, ORGANIZER, payload(location, "everyone"))
      );
      expect(code, label).toBe("invalid-argument");
    }
    expect((await db.collection("meetups").get()).size).toBe(0);
    expect(await placeCount()).toBe(0);
  });
});

describe("editing a meetup's location", () => {
  it("from a public Apple place to a private typed address lets the place go and hides the address", async () => {
    const { id } = await create(applePlace, "everyone");
    expect(await placeCount()).toBe(1);

    await callAs(updateMeetupCallable, ORGANIZER, {
      meetupId: id,
      ...payload(typedAddress, "participants_only"),
    });

    const meetup = (await db.doc(`meetups/${id}`).get()).data() ?? {};
    expect(meetup.location).toEqual({ name: "Meetup near Somerville", area: "Somerville" });
    expect(meetup.locationId).toBeUndefined();
    expect((await db.doc(`meetups/${id}/private/address`).get()).data()).toEqual({
      address: TYPED,
      label: "Alex's backyard",
    });
    expect(await placeCount()).toBe(0);
  });

  it("from a public Apple place to a public typed address drops the link, which a private edit always did", async () => {
    const { id } = await create(applePlace, "everyone");
    // Someone reviewed the place, so it stays: the link has to go because the
    // edit says so, not because the place went with it.
    await db.doc(`locations/apple_${APPLE_ID}/reviews/someone`).set({ userId: "someone", rating: 5 });

    await callAs(updateMeetupCallable, ORGANIZER, {
      meetupId: id,
      ...payload(typedAddress, "everyone"),
    });

    const meetup = (await db.doc(`meetups/${id}`).get()).data() ?? {};
    expect(meetup.location).toEqual({ address: TYPED, label: "Alex's backyard" });
    expect(meetup.locationId).toBeUndefined();
    expect(await placeCount()).toBe(1);
  });
});
