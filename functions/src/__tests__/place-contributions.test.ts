import "./setup";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import {
  checkInCallable,
  onReviewCreated,
  onReviewDeleted,
  recomputeLocationReviewAggregatesCallable,
  submitReviewCallable,
} from "../places";
import { createPetCallable } from "../pets";
import {
  callAs,
  captureSnapshot,
  clearEventLedger,
  clearRateLimits,
  deliverCreate,
  deliverDelete,
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
describe("the suspended location rating repair", () => {
  /**
   * Same window as the two post repairs. Measured before disabling: two
   * folded-in reviews, one deleted with its onReviewDeleted event not yet
   * delivered, the repair wrote totalRatings 1, then the event landed and it
   * reached 0 with one review still there.
   *
   * Skipping reviews whose `counted` marker is still false — added earlier —
   * covers a review not folded in *yet*. It cannot cover one that has been
   * folded in and is on its way out: that document is simply gone from the
   * scan while the location still owes its subtraction.
   */
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
      totalRatings: 2,
      sumRating: 8,
      averageRating: 4,
    });
    for (const id of ["counted-1", "counted-2"]) {
      await db.doc(`locations/${LOC}/reviews/${id}`).set({
        userId: id,
        rating: 4,
        tags: [],
        photos: [],
        counted: true,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }

  it("refuses, and leaves the aggregates untouched", async () => {
    await seedAggregateWorld();

    const code = await errorCodeOf(() =>
      callAs(recomputeLocationReviewAggregatesCallable, ADMIN_UID, {
        locationId: LOC,
      })
    );

    expect(code).toBe("failed-precondition");
    expect(await fieldOf(`locations/${LOC}`, "totalRatings")).toBe(2);
    expect(await fieldOf(`locations/${LOC}`, "sumRating")).toBe(8);
  });

  it("refuses even with a review deleted and its event still pending", async () => {
    // The exact shape that made the repair corrupt the aggregate.
    await seedAggregateWorld();
    const reviewPath = `locations/${LOC}/reviews/counted-2`;
    const snap = await captureSnapshot(reviewPath);
    await db.doc(reviewPath).delete();

    const code = await errorCodeOf(() =>
      callAs(recomputeLocationReviewAggregatesCallable, ADMIN_UID, {
        locationId: LOC,
      })
    );
    expect(code).toBe("failed-precondition");
    expect(await fieldOf(`locations/${LOC}`, "totalRatings")).toBe(2);

    // The delete event lands, and the trigger gets it right unaided.
    await deliverDelete(
      onReviewDeleted,
      snap,
      { locationId: LOC, reviewId: "counted-2" },
      newEventId("pending-review-delete")
    );

    expect(await fieldOf(`locations/${LOC}`, "totalRatings")).toBe(1);
    expect(await fieldOf(`locations/${LOC}`, "sumRating")).toBe(4);
  });

  it("still folds a pending review in through its own trigger", async () => {
    await seedAggregateWorld();
    const pendingPath = `locations/${LOC}/reviews/pending-1`;
    await db.doc(pendingPath).set({
      userId: "reviewer-p",
      rating: 2,
      tags: [],
      photos: [],
      counted: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    await deliverCreate(
      onReviewCreated,
      pendingPath,
      { locationId: LOC, reviewId: "pending-1" },
      newEventId("pending-review")
    );

    expect(await fieldOf(`locations/${LOC}`, "totalRatings")).toBe(3);
    expect(await fieldOf(`locations/${LOC}`, "sumRating")).toBe(10);
  });
});
