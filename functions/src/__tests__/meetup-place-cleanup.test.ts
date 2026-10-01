import "./setup";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import { cancelMeetupCallable, createMeetupCallable, updateMeetupCallable } from "../meetups";
import { deleteUserAccount } from "../users";
import { callAs, clearRateLimits } from "./helpers";

// A public meetup creates a place for where it is held (source "meetup").
// The owner chose on 2026-09-30 that such a place goes once its meetup lets
// go of it (goes participants_only, moves, is cancelled, or loses its
// organiser) and nothing else uses it: no review, no check-in, no other
// meetup that is not cancelled. A place someone added on purpose stays.

const ORGANIZER = "cleanup-organizer";
const OTHER = "cleanup-other";

const PARK = {
  name: "Riverside Dog Park",
  address: "1 River St, Cambridge, MA",
  lat: 42.3601,
  lng: -71.0942,
  city: "Cambridge",
  state: "MA",
};
const TRAIL = {
  name: "Hilltop Trail",
  address: "3 Hill Rd, Newton, MA",
  lat: 42.337,
  lng: -71.2092,
  city: "Newton",
  state: "MA",
};

async function seedUser(uid: string) {
  await admin.auth().createUser({
    uid,
    email: `${uid}@example.com`,
    emailVerified: true,
    displayName: uid,
  });
  await db.doc(`users/${uid}`).set({
    displayName: uid,
    email: `${uid}@example.com`,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
}

async function wipe() {
  for (const c of [
    "users", "meetups", "locations", "callableRateLimits", "notifications", "userDeletionTombstones",
  ]) {
    const snap = await db.collection(c).get();
    for (const d of snap.docs) await db.recursiveDelete(d.ref).catch(() => undefined);
  }
  const users = await admin.auth().listUsers(1000);
  await Promise.all(
    users.users.map((u) => admin.auth().deleteUser(u.uid).catch(() => undefined))
  );
}

const payload = (
  title: string,
  location: typeof PARK,
  locationVisibility: "everyone" | "participants_only" = "everyone"
) => ({
  title,
  description: "Bring water.",
  dateMillis: Date.now() + 3 * 24 * 60 * 60 * 1000,
  duration: 60,
  locationVisibility,
  location,
});

async function createPublicMeetup(organizer: string, title: string, location = PARK) {
  const res = await callAs<{ id?: string; meetupId?: string }>(
    createMeetupCallable,
    organizer,
    payload(title, location)
  );
  const id = (res.id ?? res.meetupId) as string;
  const locationId = (await db.doc(`meetups/${id}`).get()).get("locationId") as string;
  expect(locationId, "a public meetup links a place").toBeTruthy();
  return { id, locationId };
}

const placeExists = async (locationId: string) =>
  (await db.doc(`locations/${locationId}`).get()).exists;

beforeEach(async () => {
  await wipe();
  await clearRateLimits();
  await seedUser(ORGANIZER);
  await seedUser(OTHER);
});
afterAll(wipe);

describe("a place a public meetup created", () => {
  it("goes when its meetup goes participants_only and nothing else uses it", async () => {
    const { id, locationId } = await createPublicMeetup(ORGANIZER, "Morning walk");
    expect(await placeExists(locationId)).toBe(true);

    await callAs(updateMeetupCallable, ORGANIZER, {
      meetupId: id,
      ...payload("Morning walk", PARK, "participants_only"),
    });

    expect(await placeExists(locationId)).toBe(false);
  });

  it("stays when someone has reviewed it", async () => {
    const { id, locationId } = await createPublicMeetup(ORGANIZER, "Morning walk");
    await db.doc(`locations/${locationId}/reviews/${OTHER}`).set({ userId: OTHER, rating: 5 });

    await callAs(updateMeetupCallable, ORGANIZER, {
      meetupId: id,
      ...payload("Morning walk", PARK, "participants_only"),
    });

    expect(await placeExists(locationId)).toBe(true);
  });

  it("stays when someone has checked in there", async () => {
    const { id, locationId } = await createPublicMeetup(ORGANIZER, "Morning walk");
    await db.doc(`locations/${locationId}/checkins/${OTHER}_2026-09-30`).set({ userId: OTHER });

    await callAs(cancelMeetupCallable, ORGANIZER, { meetupId: id });

    expect(await placeExists(locationId)).toBe(true);
  });

  it("goes when its only meetup is cancelled, and the meetup loses the link", async () => {
    const { id, locationId } = await createPublicMeetup(ORGANIZER, "Morning walk");

    await callAs(cancelMeetupCallable, ORGANIZER, { meetupId: id });

    expect(await placeExists(locationId)).toBe(false);
    const meetup = (await db.doc(`meetups/${id}`).get()).data() ?? {};
    expect(meetup.status).toBe("cancelled");
    expect(meetup.locationId).toBeUndefined();
  });

  it("stays while another meetup there is still on", async () => {
    const first = await createPublicMeetup(ORGANIZER, "Morning walk");
    const second = await createPublicMeetup(OTHER, "Evening walk");
    expect(second.locationId).toBe(first.locationId);

    await callAs(cancelMeetupCallable, ORGANIZER, { meetupId: first.id });
    expect(await placeExists(first.locationId)).toBe(true);

    // Once the second is cancelled too, nothing uses it, and neither
    // cancelled meetup is left pointing at it.
    await callAs(cancelMeetupCallable, OTHER, { meetupId: second.id });
    expect(await placeExists(first.locationId)).toBe(false);
    expect((await db.doc(`meetups/${first.id}`).get()).get("locationId")).toBeUndefined();
    expect((await db.doc(`meetups/${second.id}`).get()).get("locationId")).toBeUndefined();
  });

  it("goes when the meetup moves to another place, and the new place is linked", async () => {
    const { id, locationId } = await createPublicMeetup(ORGANIZER, "Morning walk");

    await callAs(updateMeetupCallable, ORGANIZER, {
      meetupId: id,
      ...payload("Morning walk", TRAIL),
    });

    expect(await placeExists(locationId)).toBe(false);
    const newLocationId = (await db.doc(`meetups/${id}`).get()).get("locationId") as string;
    expect(newLocationId).toBeTruthy();
    expect(newLocationId).not.toBe(locationId);
    expect(await placeExists(newLocationId)).toBe(true);
  });

  it("goes when the organiser's account is deleted", async () => {
    const { locationId } = await createPublicMeetup(ORGANIZER, "Morning walk");

    await callAs(deleteUserAccount, ORGANIZER, { userId: ORGANIZER });

    expect(await placeExists(locationId)).toBe(false);
  });
});

describe("a place someone added on purpose", () => {
  it("stays when the meetup held there is cancelled", async () => {
    const { id, locationId } = await createPublicMeetup(ORGANIZER, "Morning walk");
    // The meetup reused a place that was there already: the same document,
    // added by a person rather than made for the meetup.
    await db.doc(`locations/${locationId}`).update({ source: "user" });

    await callAs(cancelMeetupCallable, ORGANIZER, { meetupId: id });

    expect(await placeExists(locationId)).toBe(true);
  });
});
