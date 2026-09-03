import "./setup";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import { createMeetupCallable, updateMeetupCallable } from "../meetups";
import { callAs, clearRateLimits } from "./helpers";

// meetups/{id} is `allow read: if true` in firestore.rules, and so is its
// participants subcollection. Anything written to the public document is
// therefore readable by an unauthenticated stranger with a single getDoc.
//
// For a participants_only meetup the address, lat and lng were blanked but the
// name was not — and name is not a venue label in the general case. geo.ts
// resolves it as `props.name || props.street || formatted`, so a residential
// address with no POI name lands on the street or the whole formatted address.
// These tests pin that the public document cannot carry it.

const ORGANIZER = "privacy-organizer";

// What Geoapify returns for a house with no POI name: `name` has already
// fallen through to the street by the time it reaches the callable.
const STREET = "123 Beacon St";
const FULL_ADDRESS = "123 Beacon St, Boston, MA 02116";

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

const privateMeetupPayload = (title: string) => ({
  title,
  description: "Bring water and a spare lead.",
  dateMillis: Date.now() + 3 * 24 * 60 * 60 * 1000,
  duration: 60,
  locationVisibility: "participants_only",
  location: {
    name: STREET,
    address: FULL_ADDRESS,
    lat: 42.3601,
    lng: -71.0589,
    city: "Boston",
    state: "MA",
  },
});

beforeEach(async () => {
  await wipe();
  await clearRateLimits();
  await seedOrganizer();
});
afterAll(wipe);

async function createPrivateMeetup(title = "Morning walk"): Promise<string> {
  const res = await callAs<{ id?: string; meetupId?: string }>(
    createMeetupCallable,
    ORGANIZER,
    privateMeetupPayload(title)
  );
  return (res.id ?? res.meetupId) as string;
}

describe("participants_only meetup, public document", () => {
  it("does not carry the street or the formatted address in location.name", async () => {
    const id = await createPrivateMeetup();
    const publicLocation = (await db.doc(`meetups/${id}`).get()).data()?.location ?? {};

    expect(publicLocation.name).not.toContain(STREET);
    expect(publicLocation.name).not.toContain(FULL_ADDRESS);
    expect(publicLocation.name).not.toMatch(/\d+\s+\w+\s+(St|Ave|Rd|Blvd|Ln|Dr)\b/i);
  });

  it("keeps address, lat and lng blank, as it already did", async () => {
    const id = await createPrivateMeetup();
    const publicLocation = (await db.doc(`meetups/${id}`).get()).data()?.location ?? {};

    expect(publicLocation.address).toBe("");
    expect(publicLocation.lat).toBe(0);
    expect(publicLocation.lng).toBe(0);
  });

  it("still says roughly where it is, so the listing is not useless", async () => {
    const id = await createPrivateMeetup();
    const publicLocation = (await db.doc(`meetups/${id}`).get()).data()?.location ?? {};

    expect(publicLocation.city).toBe("Boston");
    expect(publicLocation.state).toBe("MA");
    expect(publicLocation.name).toContain("Boston");
  });

  it("holds nothing resembling a street number anywhere in the whole document", async () => {
    // Broader than the name check: catches the address reappearing under some
    // other key if this document ever grows a field.
    const id = await createPrivateMeetup();
    const doc = (await db.doc(`meetups/${id}`).get()).data() ?? {};

    expect(JSON.stringify(doc)).not.toContain(STREET);
    expect(JSON.stringify(doc)).not.toContain("Beacon");
  });
});

describe("participants_only meetup, private subcollection", () => {
  it("still holds the real name and coordinates for people who may see them", async () => {
    // The scrubbing must not cost participants the information they are
    // entitled to — MeetupDetail reads this copy when canSeeFullAddress.
    const id = await createPrivateMeetup();
    const priv = (await db.doc(`meetups/${id}/private/address`).get()).data() ?? {};

    expect(priv.name).toBe(STREET);
    expect(priv.address).toBe(FULL_ADDRESS);
    expect(priv.lat).toBeCloseTo(42.3601, 4);
    expect(priv.lng).toBeCloseTo(-71.0589, 4);
  });
});

describe("updateMeetup keeps the same boundary", () => {
  it("does not write the street back into the public document on edit", async () => {
    // The create and update paths had the same bug in the same shape, so a fix
    // applied to only one of them would leave the leak reachable by editing.
    const id = await createPrivateMeetup("Before edit");

    await callAs(updateMeetupCallable, ORGANIZER, {
      meetupId: id,
      ...privateMeetupPayload("After edit"),
    });

    const doc = (await db.doc(`meetups/${id}`).get()).data() ?? {};
    expect(doc.title).toBe("After edit");
    expect(JSON.stringify(doc)).not.toContain(STREET);
    expect(doc.location.name).toContain("Boston");

    const priv = (await db.doc(`meetups/${id}/private/address`).get()).data() ?? {};
    expect(priv.name).toBe(STREET);
    expect(priv.address).toBe(FULL_ADDRESS);
  });
});

describe("a public meetup is unaffected", () => {
  it("keeps the real venue name and address on the public document", async () => {
    // Scrubbing must be scoped to participants_only. A venue meetup is public
    // on purpose and losing its name would be a regression, not a fix.
    const res = await callAs<{ id?: string; meetupId?: string }>(
      createMeetupCallable,
      ORGANIZER,
      {
        ...privateMeetupPayload("Dog park meetup"),
        locationVisibility: "everyone",
        location: {
          name: "Danehy Park Dog Run",
          address: "99 Sherman St, Cambridge, MA 02140",
          lat: 42.3925,
          lng: -71.1345,
          city: "Cambridge",
          state: "MA",
        },
      }
    );
    const id = (res.id ?? res.meetupId) as string;
    const doc = (await db.doc(`meetups/${id}`).get()).data() ?? {};

    expect(doc.location.name).toBe("Danehy Park Dog Run");
    expect(doc.location.address).toBe("99 Sherman St, Cambridge, MA 02140");
    expect((await db.doc(`meetups/${id}/private/address`).get()).exists).toBe(false);
  });
});
