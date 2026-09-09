import "./setup";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import {
  checkInCallable,
  onReviewCreated,
  recomputeLocationReviewAggregatesCallable,
  submitReviewCallable,
} from "../places";
import { createPetCallable } from "../pets";
import {
  callAs,
  clearEventLedger,
  clearRateLimits,
  deliverCreate,
  errorCodeOf,
  fieldOf,
  newEventId,
} from "./helpers";

/**
 * The two ordinary ways a person contributes to a place: rate it, or check in
 * at it. Both had a shape of failure that no amount of retrying could get
 * past — the handler put a JavaScript `undefined` into the Firestore write for
 * the optional field the user had not filled in, and the Admin SDK rejects the
 * whole document rather than dropping the key. The user had already waited for
 * their photo to upload by then.
 *
 * The other case here is rating integrity: a completed meetup was accepted as
 * justification for reviewing *any* location, not the one it happened at.
 */

const OWNER = "place-owner";
const OTHER = "place-other";
const PHOTO =
  "https://res.cloudinary.com/dgeunvmmn/image/upload/v1700000000/petnote/x.jpg";

async function seedUser(uid: string) {
  await db.doc(`users/${uid}`).set({
    displayName: uid,
    email: `${uid}@example.com`,
  });
}

async function seedLocation(id: string) {
  await db.doc(`locations/${id}`).set({
    name: id,
    addedBy: OWNER,
    totalRatings: 0,
    averageRating: 0,
  });
}

async function wipe() {
  for (const c of [
    "users",
    "pets",
    "locations",
    "meetups",
    "callableRateLimits",
    "notifications",
    "processedEvents",
  ]) {
    const snap = await db.collection(c).get();
    for (const d of snap.docs) await db.recursiveDelete(d.ref).catch(() => undefined);
  }
}

beforeEach(async () => {
  await wipe();
  await clearRateLimits();
  await seedUser(OWNER);
  await seedUser(OTHER);
});
afterAll(wipe);

describe("reviewing a place without a meetup", () => {
  it("accepts a plain review and stores no meetup association", async () => {
    await seedLocation("loc1");

    const result = await callAs<{ id: string }>(submitReviewCallable, OWNER, {
      locationId: "loc1",
      rating: 5,
      comment: "Great fenced area.",
    });

    const review = await db.doc(`locations/loc1/reviews/${result.id}`).get();
    expect(review.exists).toBe(true);
    expect(review.data()?.rating).toBe(5);
    // Absent, not null: src/services/locations.ts only ever queries
    // `where("meetupId", "==", <an id>)`, so a null would be dead weight that
    // a future range/order query could trip over.
    expect("meetupId" in (review.data() ?? {})).toBe(false);
  });

  it("still records the meetup association when there is one", async () => {
    await seedLocation("locA");
    await db.doc("meetups/m1").set({
      organizerId: OWNER,
      locationId: "locA",
      status: "completed",
      isRatingOpen: true,
    });

    const result = await callAs<{ id: string }>(submitReviewCallable, OWNER, {
      locationId: "locA",
      meetupId: "m1",
      rating: 4,
    });

    const review = await db.doc(`locations/locA/reviews/${result.id}`).get();
    expect(review.data()?.meetupId).toBe("m1");
  });
});

describe("checking in without a pet", () => {
  it("accepts a check-in from a person with no pet selected", async () => {
    await seedLocation("loc1");

    const result = await callAs<{ id: string }>(checkInCallable, OWNER, {
      locationId: "loc1",
      photoUrl: PHOTO,
      caption: "Sunny morning",
    });

    const checkin = await db.doc(`locations/loc1/checkins/${result.id}`).get();
    expect(checkin.exists).toBe(true);
    expect(checkin.data()?.caption).toBe("Sunny morning");
    expect("petId" in (checkin.data() ?? {})).toBe(false);
    expect("petName" in (checkin.data() ?? {})).toBe(false);
  });

  it("still records the pet when one is selected", async () => {
    await seedLocation("loc1");
    const pet = await callAs<{ id?: string; petId?: string }>(
      createPetCallable,
      OWNER,
      { name: "Mochi", species: "dog", gender: "female" }
    );
    const petId = (pet.id ?? pet.petId) as string;

    const result = await callAs<{ id: string }>(checkInCallable, OWNER, {
      locationId: "loc1",
      photoUrl: PHOTO,
      petId,
    });

    const checkin = await db.doc(`locations/loc1/checkins/${result.id}`).get();
    expect(checkin.data()?.petId).toBe(petId);
    expect(checkin.data()?.petName).toBe("Mochi");
  });
});

describe("a meetup review has to be about the meetup's place", () => {
  beforeEach(async () => {
    await seedLocation("locA");
    await seedLocation("locB");
    await db.doc("meetups/m1").set({
      organizerId: OWNER,
      locationId: "locA",
      status: "completed",
      isRatingOpen: true,
    });
  });

  it("refuses a meetup at place A as grounds for reviewing place B", async () => {
    const code = await errorCodeOf(() =>
      callAs(submitReviewCallable, OWNER, {
        locationId: "locB",
        meetupId: "m1",
        rating: 1,
      })
    );
    expect(code).toBe("permission-denied");
    const reviews = await db.collection("locations/locB/reviews").get();
    expect(reviews.empty).toBe(true);
  });

  it("refuses a meetup that has no public place at all", async () => {
    // A participants_only meetup never gets a locationId, so there is no
    // place it can vouch for.
    await db.doc("meetups/private1").set({
      organizerId: OWNER,
      status: "completed",
      isRatingOpen: true,
    });

    const code = await errorCodeOf(() =>
      callAs(submitReviewCallable, OWNER, {
        locationId: "locA",
        meetupId: "private1",
        rating: 5,
      })
    );
    expect(code).toBe("permission-denied");
  });

  it("still lets a participant review the place the meetup happened at", async () => {
    await db.doc(`meetups/m1/participants/${OTHER}`).set({
      userId: OTHER,
      petName: "Bud",
      joinedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const code = await errorCodeOf(() =>
      callAs(submitReviewCallable, OTHER, {
        locationId: "locA",
        meetupId: "m1",
        rating: 5,
      })
    );
    expect(code).toBe(null);
  });
});

/**
 * The admin repair for a place's rating aggregates, against the same two
 * hazards the post repairs had.
 *
 * `onReviewCreated` flips a review's `counted` marker in the same transaction
 * that folds its rating into the location, so a review with `counted: false`
 * has not been folded in yet. A repair that counts every review document
 * therefore over-reports, and then the pending trigger adds the same rating
 * again. And an absolute write loses any fold that lands between the scan and
 * the write.
 */
describe("repairing a place's rating aggregates", () => {
  const ADMIN_UID = "place-admin";
  const LOC = "locagg";

  async function seedAggregateWorld() {
    await clearEventLedger();
    await clearRateLimits();
    await db.recursiveDelete(db.doc(`locations/${LOC}`)).catch(() => undefined);
    await db.doc(`users/${ADMIN_UID}`).set({ displayName: "Admin" });
    await db.doc(`users/${ADMIN_UID}/admin/state`).set({ role: "admin" });
    await db.doc(`locations/${LOC}`).set({
      name: "Aggregate park",
      addedBy: OWNER,
      totalRatings: 1,
      sumRating: 4,
      averageRating: 4,
    });
    // One review already folded in.
    await db.doc(`locations/${LOC}/reviews/counted-1`).set({
      userId: "reviewer-1",
      rating: 4,
      tags: [],
      photos: [],
      counted: true,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }

  it("does not count a review whose trigger has not folded it in yet", async () => {
    await seedAggregateWorld();
    await db.doc(`locations/${LOC}/reviews/pending-1`).set({
      userId: "reviewer-2",
      rating: 2,
      tags: [],
      photos: [],
      counted: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const repaired = await callAs<{ totalRatings: number }>(
      recomputeLocationReviewAggregatesCallable,
      ADMIN_UID,
      { locationId: LOC }
    );

    // Two review documents exist, but only one has been folded in.
    expect(repaired.totalRatings).toBe(1);
    expect(await fieldOf(`locations/${LOC}`, "sumRating")).toBe(4);

    // Now the pending trigger runs. It must reach 2, not 3.
    await deliverCreate(
      onReviewCreated,
      `locations/${LOC}/reviews/pending-1`,
      { locationId: LOC, reviewId: "pending-1" },
      newEventId("pending-review")
    );

    expect(await fieldOf(`locations/${LOC}`, "totalRatings")).toBe(2);
    expect(await fieldOf(`locations/${LOC}`, "sumRating")).toBe(6);
  });

  it("does not lose a rating folded in while the repair was running", async () => {
    for (let attempt = 0; attempt < 4; attempt += 1) {
      await seedAggregateWorld();
      const pendingPath = `locations/${LOC}/reviews/pending-race`;
      await db.doc(pendingPath).set({
        userId: "reviewer-3",
        rating: 5,
        tags: [],
        photos: [],
        counted: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      await Promise.all([
        callAs(recomputeLocationReviewAggregatesCallable, ADMIN_UID, {
          locationId: LOC,
        }),
        deliverCreate(
          onReviewCreated,
          pendingPath,
          { locationId: LOC, reviewId: "pending-race" },
          newEventId("race-review")
        ),
      ]);

      // Order-independent: totalRatings equals the number of reviews that have
      // been folded in, whichever side finished first.
      const reviews = await db.collection(`locations/${LOC}/reviews`).get();
      const folded = reviews.docs.filter((d) => d.data().counted !== false).length;
      expect(
        await fieldOf(`locations/${LOC}`, "totalRatings"),
        `attempt ${attempt}, folded ${folded}`
      ).toBe(folded);
    }
  }, 60_000);
});
