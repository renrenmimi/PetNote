import "./setup";
import { beforeEach, afterAll, describe, expect, it } from "vitest";
import { db } from "../platform";
import { onLikeCreated, onLikeDeleted, onCommentCreated, onCommentDeleted, onFollowingPetCreated, onFollowingPetDeleted } from "../notifications";
import { onPostWritten } from "../posts";
import { onParticipantDeleted } from "../meetups";
import { onReviewCreated, onReviewDeleted, onCheckinCreated, onCheckinDeleted } from "../places";
import {
  captureSnapshot, clearEventLedger, deliverCreate, deliverDelete, deliverWritten,
  fieldOf, newEventId, purge, serverTime, timestampAt,
} from "./helpers";

// Every assertion below is about the two things Firestore actually guarantees:
// events arrive AT LEAST once, and they arrive in NO PARTICULAR ORDER. A count
// that only survives exactly-once, in-order delivery is not correct, it is
// lucky.

const POST = "posts/idem-post";
const PET = "pets/idem-pet";
const USER = "users/idem-user";
const MEETUP = "meetups/idem-meetup";
const LOCATION = "locations/idem-location";

async function resetWorld() {
  await purge(POST, PET, USER, MEETUP, LOCATION);
  await clearEventLedger();
  await db.doc(POST).set({ authorId: "someone-else", text: "post", likeCount: 0, commentCount: 0, petId: null });
  await db.doc(PET).set({ name: "Idem", ownerId: "idem-user", followerCount: 0, postCount: 0 });
  await db.doc(USER).set({ displayName: "Idem", followingPetsCount: 0 });
  await db.doc(MEETUP).set({ title: "Idem meetup", organizerId: "organizer", participantCount: 1 });
  await db.doc(LOCATION).set({ name: "Idem park", totalRatings: 0, sumRating: 0, averageRating: 0, totalCheckins: 0, verifiedByCheckins: false });
}

beforeEach(resetWorld);
afterAll(async () => {
  await purge(POST, PET, USER, MEETUP, LOCATION);
  await clearEventLedger();
});

describe("likeCount", () => {
  const likePath = `${POST}/likes/liker-1`;
  const params = { postId: "idem-post", likeId: "liker-1" };
  // Matches what likePost writes from the client, including counted:false.
  const writeLike = () =>
    db.doc(likePath).set({
      userId: "liker-1",
      postId: "idem-post",
      createdAt: serverTime(),
      counted: false,
    });

  it("counts a like once when the same event is delivered twice", async () => {
    await writeLike();
    const eventId = newEventId("like-create");

    await deliverCreate(onLikeCreated, likePath, params, eventId);
    await deliverCreate(onLikeCreated, likePath, params, eventId);

    expect(await fieldOf(POST, "likeCount")).toBe(1);
  });

  it("counts a like once even when a redelivery arrives after the ledger entry is gone", async () => {
    await writeLike();
    await deliverCreate(onLikeCreated, likePath, params, newEventId("like-create"));

    // Simulate the ledger entry ageing out under its TTL policy, then a very
    // late retry arriving with a fresh id. The counted stamp on the like doc
    // outlives the ledger and still holds the line.
    await clearEventLedger();
    await deliverCreate(onLikeCreated, likePath, params, newEventId("like-create-late"));

    expect(await fieldOf(POST, "likeCount")).toBe(1);
  });

  it("returns to zero on a like then unlike delivered in order", async () => {
    await writeLike();
    await deliverCreate(onLikeCreated, likePath, params, newEventId("like-create"));

    const snap = await captureSnapshot(likePath);
    await db.doc(likePath).delete();
    await deliverDelete(onLikeDeleted, snap, params, newEventId("like-delete"));

    expect(await fieldOf(POST, "likeCount")).toBe(0);
  });

  it("stays at zero when the delete event overtakes the create it undoes", async () => {
    await writeLike();
    const createSnap = await captureSnapshot(likePath);
    await db.doc(likePath).delete();

    // Out of order: the delete lands first, carrying an unstamped snapshot
    // because onLikeCreated never ran.
    await deliverDelete(onLikeDeleted, createSnap, params, newEventId("like-delete"));
    expect(await fieldOf(POST, "likeCount")).toBe(0);

    // The create arrives late. Its source document is gone, so it must not
    // count either.
    await deliverCreate(onLikeCreated, likePath, params, newEventId("like-create"));
    expect(await fieldOf(POST, "likeCount")).toBe(0);
  });

  it("subtracts once when the same unlike is delivered twice", async () => {
    await writeLike();
    await deliverCreate(onLikeCreated, likePath, params, newEventId("like-create"));
    await db.doc(POST).update({ likeCount: 5 });

    const snap = await captureSnapshot(likePath);
    await db.doc(likePath).delete();
    const deleteId = newEventId("like-delete");
    await deliverDelete(onLikeDeleted, snap, params, deleteId);
    await deliverDelete(onLikeDeleted, snap, params, deleteId);

    expect(await fieldOf(POST, "likeCount")).toBe(4);
  });

  it("still subtracts for a like written before the counted stamp shipped", async () => {
    // No `counted` field at all: written by the old client, and counted
    // unconditionally by the old trigger. Removing it must still decrement,
    // which is what makes this deployable without backfilling every like.
    await db.doc(likePath).set({
      userId: "liker-1",
      postId: "idem-post",
      createdAt: timestampAt("2026-01-01T00:00:00.000Z"),
    });
    await db.doc(POST).update({ likeCount: 1 });

    const snap = await captureSnapshot(likePath);
    await db.doc(likePath).delete();
    await deliverDelete(onLikeDeleted, snap, params, newEventId("like-delete"));

    expect(await fieldOf(POST, "likeCount")).toBe(0);
  });

  it("does not subtract a like whose create trigger never counted it", async () => {
    // counted:false and still false — the create event has not been delivered.
    await writeLike();
    await db.doc(POST).update({ likeCount: 3 });

    const snap = await captureSnapshot(likePath);
    await db.doc(likePath).delete();
    await deliverDelete(onLikeDeleted, snap, params, newEventId("like-delete"));

    expect(await fieldOf(POST, "likeCount")).toBe(3);
  });
});

describe("commentCount", () => {
  const commentPath = `${POST}/comments/comment-1`;
  const params = { postId: "idem-post", commentId: "comment-1" };
  // Matches what createCommentCallable writes.
  const writeComment = () =>
    db.doc(commentPath).set({
      authorId: "commenter-1",
      text: "hi",
      createdAt: serverTime(),
      counted: false,
    });

  it("counts a comment once when the same event is delivered twice", async () => {
    await writeComment();
    const eventId = newEventId("comment-create");

    await deliverCreate(onCommentCreated, commentPath, params, eventId);
    await deliverCreate(onCommentCreated, commentPath, params, eventId);

    expect(await fieldOf(POST, "commentCount")).toBe(1);
  });

  it("returns to zero on create then delete delivered in order", async () => {
    await writeComment();
    await deliverCreate(onCommentCreated, commentPath, params, newEventId("comment-create"));

    const snap = await captureSnapshot(commentPath);
    await db.doc(commentPath).delete();
    await deliverDelete(onCommentDeleted, snap, params, newEventId("comment-delete"));

    expect(await fieldOf(POST, "commentCount")).toBe(0);
  });

  it("stays at zero when the delete event overtakes the create", async () => {
    await writeComment();
    const snap = await captureSnapshot(commentPath);
    await db.doc(commentPath).delete();

    await deliverDelete(onCommentDeleted, snap, params, newEventId("comment-delete"));
    await deliverCreate(onCommentCreated, commentPath, params, newEventId("comment-create"));

    expect(await fieldOf(POST, "commentCount")).toBe(0);
  });
});

describe("pet follower counts", () => {
  const followPath = `${USER}/followingPets/idem-pet`;
  const params = { userId: "idem-user", petId: "idem-pet" };

  it("counts a follow once when the same event is delivered twice", async () => {
    // This is the trigger the codebase already treated as the good example.
    // Re-reading the follow doc protects it against a delete that arrives
    // first, but the doc still exists on a redelivery, so before the ledger
    // this incremented a second time.
    await db.doc(followPath).set({ petId: "idem-pet", followedAt: serverTime(), counted: false });
    const eventId = newEventId("follow-create");

    await deliverCreate(onFollowingPetCreated, followPath, params, eventId);
    await deliverCreate(onFollowingPetCreated, followPath, params, eventId);

    expect(await fieldOf(PET, "followerCount")).toBe(1);
    expect(await fieldOf(USER, "followingPetsCount")).toBe(1);
  });

  it("subtracts once when the same unfollow is delivered twice", async () => {
    await db.doc(followPath).set({ petId: "idem-pet", followedAt: serverTime(), counted: false });
    await deliverCreate(onFollowingPetCreated, followPath, params, newEventId("follow-create"));
    await db.doc(PET).update({ followerCount: 5 });
    await db.doc(USER).update({ followingPetsCount: 5 });

    const snap = await captureSnapshot(followPath);
    await db.doc(followPath).delete();
    const deleteId = newEventId("follow-delete");
    await deliverDelete(onFollowingPetDeleted, snap, params, deleteId);
    await deliverDelete(onFollowingPetDeleted, snap, params, deleteId);

    expect(await fieldOf(PET, "followerCount")).toBe(4);
    expect(await fieldOf(USER, "followingPetsCount")).toBe(4);
  });
});

describe("meetup participantCount", () => {
  const participantPath = `${MEETUP}/participants/joiner-1`;
  const params = { meetupId: "idem-meetup", participantId: "joiner-1" };

  it("subtracts once when the same leave event is delivered twice", async () => {
    // joinMeetupCallable stamps counted:true in the same transaction as the
    // increment, so the participant below is what that callable produces.
    await db.doc(participantPath).set({ userId: "joiner-1", joinedAt: serverTime(), counted: true });
    await db.doc(MEETUP).update({ participantCount: 2 });

    const snap = await captureSnapshot(participantPath);
    await db.doc(participantPath).delete();
    const eventId = newEventId("participant-delete");
    await deliverDelete(onParticipantDeleted, snap, params, eventId);
    await deliverDelete(onParticipantDeleted, snap, params, eventId);

    expect(await fieldOf(MEETUP, "participantCount")).toBe(1);
  });

  it("does not subtract for a participant that was never counted", async () => {
    await db.doc(participantPath).set({ userId: "joiner-1", joinedAt: serverTime(), counted: false });
    const snap = await captureSnapshot(participantPath);
    await db.doc(participantPath).delete();

    await deliverDelete(onParticipantDeleted, snap, params, newEventId("participant-delete"));

    expect(await fieldOf(MEETUP, "participantCount")).toBe(1);
  });
});

describe("location review aggregates", () => {
  const reviewPath = `${LOCATION}/reviews/review-1`;
  const params = { locationId: "idem-location", reviewId: "review-1" };
  const writeReview = () =>
    db.doc(reviewPath).set({
      userId: "reviewer-1", rating: 4, tags: [], photos: [],
      createdAt: serverTime(), counted: false,
    });

  it("folds a rating in once when the same event is delivered twice", async () => {
    await writeReview();
    const eventId = newEventId("review-create");

    await deliverCreate(onReviewCreated, reviewPath, params, eventId);
    await deliverCreate(onReviewCreated, reviewPath, params, eventId);

    expect(await fieldOf(LOCATION, "totalRatings")).toBe(1);
    expect(await fieldOf(LOCATION, "sumRating")).toBe(4);
    expect(await fieldOf(LOCATION, "averageRating")).toBe(4);
  });

  it("returns to empty on create then delete delivered in order", async () => {
    await writeReview();
    await deliverCreate(onReviewCreated, reviewPath, params, newEventId("review-create"));

    const snap = await captureSnapshot(reviewPath);
    await db.doc(reviewPath).delete();
    await deliverDelete(onReviewDeleted, snap, params, newEventId("review-delete"));

    expect(await fieldOf(LOCATION, "totalRatings")).toBe(0);
    expect(await fieldOf(LOCATION, "sumRating")).toBe(0);
  });

  it("leaves the average alone when the delete event overtakes the create", async () => {
    await writeReview();
    const snap = await captureSnapshot(reviewPath);
    await db.doc(reviewPath).delete();

    await deliverDelete(onReviewDeleted, snap, params, newEventId("review-delete"));
    await deliverCreate(onReviewCreated, reviewPath, params, newEventId("review-create"));

    expect(await fieldOf(LOCATION, "totalRatings")).toBe(0);
    expect(await fieldOf(LOCATION, "sumRating")).toBe(0);
  });
});

describe("location check-in count", () => {
  const params = (id: string) => ({ locationId: "idem-location", checkinId: id });
  const checkinPath = (id: string) => `${LOCATION}/checkins/${id}`;
  const writeCheckin = (id: string) =>
    db.doc(checkinPath(id)).set({
      userId: id, locationId: "idem-location",
      createdAt: serverTime(), counted: false,
    });

  it("counts a check-in once when the same event is delivered twice", async () => {
    await writeCheckin("visitor-1");
    const eventId = newEventId("checkin-create");

    await deliverCreate(onCheckinCreated, checkinPath("visitor-1"), params("visitor-1"), eventId);
    await deliverCreate(onCheckinCreated, checkinPath("visitor-1"), params("visitor-1"), eventId);

    expect(await fieldOf(LOCATION, "totalCheckins")).toBe(1);
  });

  it("does not let redelivery push the location over the verified threshold", async () => {
    // verifiedByCheckins flips at 3. Two genuine check-ins plus a redelivery
    // of one of them used to be enough to mark the place verified.
    for (const id of ["visitor-1", "visitor-2"]) {
      await writeCheckin(id);
      await deliverCreate(onCheckinCreated, checkinPath(id), params(id), newEventId("checkin-create"));
    }
    const replayId = newEventId("checkin-create");
    await deliverCreate(onCheckinCreated, checkinPath("visitor-2"), params("visitor-2"), replayId);
    await deliverCreate(onCheckinCreated, checkinPath("visitor-2"), params("visitor-2"), replayId);

    expect(await fieldOf(LOCATION, "totalCheckins")).toBe(2);
    expect(await fieldOf(LOCATION, "verifiedByCheckins")).toBe(false);
  });

  it("stays at zero when the delete event overtakes the create", async () => {
    await writeCheckin("visitor-1");
    const snap = await captureSnapshot(checkinPath("visitor-1"));
    await db.doc(checkinPath("visitor-1")).delete();

    await deliverDelete(onCheckinDeleted, snap, params("visitor-1"), newEventId("checkin-delete"));
    await deliverCreate(onCheckinCreated, checkinPath("visitor-1"), params("visitor-1"), newEventId("checkin-create"));

    expect(await fieldOf(LOCATION, "totalCheckins")).toBe(0);
  });
});

describe("hashtag and pet post counts", () => {
  const params = { postId: "idem-post" };

  it("counts a tagged post once when the same write event is delivered twice", async () => {
    await db.doc(POST).update({ tags: ["parkday"], petId: "idem-pet" });
    await db.recursiveDelete(db.doc("hashtags/parkday"));

    const before = undefined;
    const after = await captureSnapshot(POST);
    const eventId = newEventId("post-written");

    await deliverWritten(onPostWritten, before, after, params, eventId);
    await deliverWritten(onPostWritten, before, after, params, eventId);

    expect(await fieldOf("hashtags/parkday", "postCount")).toBe(1);
    expect(await fieldOf(PET, "postCount")).toBe(1);

    await db.recursiveDelete(db.doc("hashtags/parkday"));
  });

  it("moves the post count when a post changes pet, and only once", async () => {
    // Two pets means two reads. An earlier version of this handler read each
    // pet inside the loop that also wrote them, and Firestore rejects a read
    // that follows a write in the same transaction — so this case failed
    // outright while the single-pet case above passed.
    const OTHER_PET = "pets/idem-pet-2";
    await db.doc(OTHER_PET).set({ name: "Other", ownerId: "idem-user", postCount: 0 });
    await db.doc(PET).update({ postCount: 1 });

    await db.doc(POST).update({ petId: "idem-pet", tags: [] });
    const before = await captureSnapshot(POST);
    await db.doc(POST).update({ petId: "idem-pet-2" });
    const after = await captureSnapshot(POST);

    const eventId = newEventId("post-written");
    await deliverWritten(onPostWritten, before, after, params, eventId);
    await deliverWritten(onPostWritten, before, after, params, eventId);

    expect(await fieldOf(PET, "postCount")).toBe(0);
    expect(await fieldOf(OTHER_PET, "postCount")).toBe(1);

    await db.recursiveDelete(db.doc(OTHER_PET));
  });
});
