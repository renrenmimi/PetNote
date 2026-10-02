import "./setup";
import { createHash } from "node:crypto";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import { onReviewCreated, onReviewDeleted } from "../places";
import { captureSnapshot, clearEventLedger, deliverCreate, deliverDelete, fieldOf, newEventId } from "./helpers";

/**
 * A review's photos go with it. onReviewCreated puts them in the location's
 * preview list and writes a photo entry for each; a delete that left both
 * would leave someone's photos on a place after they took their review down.
 * An address the place's own photos hold, or another review there carries,
 * stays.
 */

const LOC = "review-photos-loc";
const OWN = "https://res.cloudinary.com/dgeunvmmn/image/upload/v1/petnote/users/owner/own.jpg";
const A_PHOTO = "https://res.cloudinary.com/dgeunvmmn/image/upload/v1/petnote/users/a/one.jpg";
const SHARED = "https://res.cloudinary.com/dgeunvmmn/image/upload/v1/petnote/users/a/shared.jpg";

const entryPath = (url: string) =>
  `locations/${LOC}/photoEntries/${createHash("sha1").update(url).digest("hex")}`;

async function wipe() {
  await db.recursiveDelete(db.doc(`locations/${LOC}`)).catch(() => undefined);
  for (const uid of ["reviewer-a", "reviewer-b"]) {
    await db.doc(`users/${uid}`).delete().catch(() => undefined);
  }
  await clearEventLedger();
}

beforeEach(async () => {
  await wipe();
  for (const uid of ["reviewer-a", "reviewer-b"]) {
    await db.doc(`users/${uid}`).set({ displayName: uid, email: `${uid}@example.com` });
  }
  await db.doc(`locations/${LOC}`).set({
    name: "Review photos park",
    addedBy: "owner",
    photos: [OWN],
    locationPhotos: [OWN],
    totalPhotos: 1,
    totalRatings: 0,
    averageRating: 0,
  });
});
afterAll(wipe);

/** Writes a review as submitReviewCallable does, and delivers its create event. */
async function review(uid: string, photos: string[]): Promise<string> {
  const path = `locations/${LOC}/reviews/${uid}`;
  await db.doc(path).set({
    userId: uid,
    rating: 4,
    tags: [],
    photos,
    counted: false,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  await deliverCreate(onReviewCreated, path, { locationId: LOC, reviewId: uid }, newEventId("review-create"));
  return path;
}

async function removeReview(path: string, uid: string, eventId = newEventId("review-delete")) {
  const snap = await captureSnapshot(path);
  await db.doc(path).delete();
  await deliverDelete(onReviewDeleted, snap, { locationId: LOC, reviewId: uid }, eventId);
  return snap;
}

describe("a deleted review's photos", () => {
  it("leave the place's preview list and photo entries", async () => {
    const path = await review("reviewer-a", [A_PHOTO]);
    expect(await fieldOf<string[]>(`locations/${LOC}`, "photos")).toContain(A_PHOTO);
    expect((await db.doc(entryPath(A_PHOTO)).get()).exists).toBe(true);

    await removeReview(path, "reviewer-a");

    expect(await fieldOf<string[]>(`locations/${LOC}`, "photos")).toEqual([OWN]);
    expect((await db.doc(entryPath(A_PHOTO)).get()).exists).toBe(false);
    expect(await fieldOf<number>(`locations/${LOC}`, "totalRatings")).toBe(0);
  });

  it("stay while another review there carries the same address", async () => {
    const pathA = await review("reviewer-a", [SHARED]);
    await review("reviewer-b", [SHARED]);

    await removeReview(pathA, "reviewer-a");

    expect(await fieldOf<string[]>(`locations/${LOC}`, "photos")).toContain(SHARED);
    expect((await db.doc(entryPath(SHARED)).get()).exists).toBe(true);
  });

  it("leave the place's own photo where it is", async () => {
    const path = await review("reviewer-a", [OWN]);

    await removeReview(path, "reviewer-a");

    expect(await fieldOf<string[]>(`locations/${LOC}`, "photos")).toEqual([OWN]);
    expect(await fieldOf<string[]>(`locations/${LOC}`, "locationPhotos")).toEqual([OWN]);
    expect((await db.doc(entryPath(OWN)).get()).exists).toBe(true);
  });

  it("are taken out once when the delete arrives twice", async () => {
    const path = await review("reviewer-a", [A_PHOTO]);
    const eventId = newEventId("review-delete");
    const snap = await removeReview(path, "reviewer-a", eventId);

    await deliverDelete(onReviewDeleted, snap, { locationId: LOC, reviewId: "reviewer-a" }, eventId);

    expect(await fieldOf<string[]>(`locations/${LOC}`, "photos")).toEqual([OWN]);
    expect(await fieldOf<number>(`locations/${LOC}`, "totalRatings")).toBe(0);
  });

  /** Deleted before its create event ran: nothing of its photos is left behind. */
  it("are not written back by a create event that arrives after the delete", async () => {
    const path = `locations/${LOC}/reviews/reviewer-a`;
    await db.doc(path).set({
      userId: "reviewer-a",
      rating: 4,
      tags: [],
      photos: [A_PHOTO],
      counted: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    const created = await captureSnapshot(path);
    await removeReview(path, "reviewer-a");

    await onReviewCreated.run({
      id: newEventId("review-create"),
      params: { locationId: LOC, reviewId: "reviewer-a" },
      data: created,
    } as never);

    expect(await fieldOf<string[]>(`locations/${LOC}`, "photos")).toEqual([OWN]);
    expect((await db.doc(entryPath(A_PHOTO)).get()).exists).toBe(false);
  });
});
