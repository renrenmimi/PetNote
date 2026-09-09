import "./setup";
import { beforeEach, afterAll, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import { onLikeCreated, onCommentCreated } from "../notifications";
import {
  createPostCallable,
  onPostWritten,
  recomputePetPostCountCallable,
  recomputePostInteractionCountsCallable,
} from "../posts";
import {
  callAs,
  captureSnapshot,
  clearEventLedger,
  clearRateLimits,
  deliverCreate,
  deliverWritten,
  errorCodeOf,
  fieldOf,
  newEventId,
  purge,
} from "./helpers";

/**
 * A post's aggregate contribution — its pet's postCount and its hashtags'
 * postCount — under the two things Firestore actually guarantees: at-least-once
 * delivery, and no ordering.
 *
 * The handler used to compute a delta from the event (before → after) and clamp
 * at zero, which is only correct if events arrive in order. Delivering a post's
 * delete before its create left the aggregates holding a post that never
 * existed: the early decrement clamped to 0, losing the inverse, and the later
 * increment then applied for real. Event-id deduplication cannot fix that —
 * they are two different events.
 *
 * It now records what it applied on the post itself and converges on that, so
 * any order and any number of deliveries reach the same place. The admin repair
 * callables run the same protocol instead of writing an absolute count over the
 * top of it.
 */

const POST = "posts/contrib-post";
const PET = "pets/contrib-pet";
const OWNER = "contrib-owner";
const ADMIN_UID = "contrib-admin";
const TAG = "hashtags/parkday";

async function resetWorld() {
  await purge(POST, PET, `users/${OWNER}`, `users/${ADMIN_UID}`);
  await db.recursiveDelete(db.doc(TAG)).catch(() => undefined);
  await clearEventLedger();
  await clearRateLimits();
  await db.doc(POST).set({
    authorId: OWNER,
    text: "post",
    likeCount: 0,
    commentCount: 0,
  });
  await db.doc(PET).set({
    name: "Contrib",
    ownerId: OWNER,
    primaryOwnerId: OWNER,
    postCount: 0,
  });
  await db.doc(`pets/contrib-pet/family/${OWNER}`).set({
    userId: OWNER,
    role: "primary",
    joinedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  await db.doc(`users/${OWNER}`).set({ displayName: "Owner" });
  await db.doc(`users/${ADMIN_UID}`).set({ displayName: "Admin" });
  await db.doc(`users/${ADMIN_UID}/admin/state`).set({ role: "admin" });
}

beforeEach(resetWorld);
afterAll(async () => {
  await purge(POST, PET, `users/${OWNER}`, `users/${ADMIN_UID}`);
  await db.recursiveDelete(db.doc(TAG)).catch(() => undefined);
  await clearEventLedger();
});

const params = { postId: "contrib-post" };

describe("out-of-order delivery", () => {
  it("leaves the counts at zero when a delete overtakes its create", async () => {
    // A post created with the contribution protocol: the marker says nothing
    // has been counted yet, which is what separates this case from a legacy
    // post being deleted.
    await db.doc(POST).update({
      tags: ["parkday"],
      petId: "contrib-pet",
      countedContribution: { petId: null, tags: [] },
    });
    const created = await captureSnapshot(POST);
    await db.doc(POST).delete();
    const gone = await captureSnapshot(POST);

    await deliverWritten(onPostWritten, created, gone, params, newEventId("del"));
    await deliverWritten(onPostWritten, undefined, created, params, newEventId("cre"));

    expect((await db.doc(TAG).get()).exists).toBe(false);
    expect(await fieldOf(PET, "postCount")).toBe(0);
  });

  it("ignores an update event for a post that has since been deleted", async () => {
    await db.doc(POST).update({
      tags: ["parkday"],
      petId: "contrib-pet",
      countedContribution: { petId: null, tags: [] },
    });
    const before = await captureSnapshot(POST);
    await db.doc(POST).update({ tags: ["beachday"] });
    const after = await captureSnapshot(POST);
    await db.doc(POST).delete();

    await deliverWritten(onPostWritten, before, after, params, newEventId("upd"));

    expect((await db.doc(TAG).get()).exists).toBe(false);
    expect((await db.doc("hashtags/beachday").get()).exists).toBe(false);
    expect(await fieldOf(PET, "postCount")).toBe(0);
  });

  it("converges when the create is redelivered after the real state moved on", async () => {
    await db.doc(POST).update({
      tags: ["parkday"],
      petId: "contrib-pet",
      countedContribution: { petId: null, tags: [] },
    });
    const created = await captureSnapshot(POST);
    await deliverWritten(onPostWritten, undefined, created, params, newEventId("cre"));
    expect(await fieldOf(TAG, "postCount")).toBe(1);

    // The post moves to a different tag, and only *then* does a stale create
    // event get redelivered. It must not re-add the tag the post no longer has.
    await db.doc(POST).update({ tags: ["beachday"] });
    await deliverWritten(onPostWritten, undefined, created, params, newEventId("cre-again"));

    expect((await db.doc(TAG).get()).exists).toBe(false);
    expect(await fieldOf("hashtags/beachday", "postCount")).toBe(1);
    expect(await fieldOf(PET, "postCount")).toBe(1);

    await db.recursiveDelete(db.doc("hashtags/beachday"));
  });
});

describe("posts written before the contribution marker existed", () => {
  it("still counts a legacy post on its create event", async () => {
    // No countedContribution field at all: the create event's before is
    // absent, so nothing has been applied.
    await db.doc(POST).update({ tags: ["parkday"], petId: "contrib-pet" });
    const after = await captureSnapshot(POST);

    await deliverWritten(onPostWritten, undefined, after, params, newEventId("legacy-cre"));

    expect(await fieldOf(TAG, "postCount")).toBe(1);
    expect(await fieldOf(PET, "postCount")).toBe(1);
  });

  it("still moves a legacy post's count between pets", async () => {
    const OTHER = "pets/contrib-pet-2";
    await db.doc(OTHER).set({ name: "Other", ownerId: OWNER, postCount: 0 });
    await db.doc(POST).update({ petId: "contrib-pet", tags: [] });
    await db.doc(PET).update({ postCount: 1 });
    const before = await captureSnapshot(POST);
    await db.doc(POST).update({ petId: "contrib-pet-2" });
    const after = await captureSnapshot(POST);

    await deliverWritten(onPostWritten, before, after, params, newEventId("legacy-move"));

    expect(await fieldOf(PET, "postCount")).toBe(0);
    expect(await fieldOf(OTHER, "postCount")).toBe(1);
    await db.recursiveDelete(db.doc(OTHER));
  });

  it("undoes a legacy post's contribution when it is deleted", async () => {
    await db.doc(POST).update({ tags: ["parkday"], petId: "contrib-pet" });
    await db.doc(PET).update({ postCount: 1 });
    await db.doc(TAG).set({ name: "parkday", postCount: 1 });
    const before = await captureSnapshot(POST);
    await db.doc(POST).delete();
    const gone = await captureSnapshot(POST);

    await deliverWritten(onPostWritten, before, gone, params, newEventId("legacy-del"));

    expect((await db.doc(TAG).get()).exists).toBe(false);
    expect(await fieldOf(PET, "postCount")).toBe(0);
  });

  it("adopts the marker on the next write, without double-counting", async () => {
    await db.doc(POST).update({ tags: ["parkday"], petId: "contrib-pet" });
    await db.doc(PET).update({ postCount: 1 });
    await db.doc(TAG).set({ name: "parkday", postCount: 1 });
    const snap = await captureSnapshot(POST);

    // An unrelated write (the display-name fanout, say): same tags, same pet.
    await deliverWritten(onPostWritten, snap, snap, params, newEventId("legacy-touch"));

    expect(await fieldOf(TAG, "postCount")).toBe(1);
    expect(await fieldOf(PET, "postCount")).toBe(1);
    const marker = (await db.doc(POST).get()).data()?.countedContribution;
    expect(marker).toEqual({ petId: "contrib-pet", tags: ["parkday"] });
  });
});

describe("a tag that cannot be a document id", () => {
  it("is refused when the post is created", async () => {
    const code = await errorCodeOf(() =>
      callAs(createPostCallable, OWNER, {
        petId: "contrib-pet",
        text: "hi",
        tags: ["dogs/cats"],
      })
    );
    expect(code).toBe("invalid-argument");
  });

  it("is refused on edit too", async () => {
    // Both write paths went through different validators, which is how post
    // tags ended up laxer than place-review tags.
    const created = await callAs<{ id: string }>(createPostCallable, OWNER, {
      petId: "contrib-pet",
      text: "hi",
      tags: ["dogs"],
    });
    const { updatePostCallable } = await import("../posts");
    const code = await errorCodeOf(() =>
      callAs(updatePostCallable, OWNER, {
        postId: created.id,
        tags: ["dogs.cats"],
      })
    );
    expect(code).toBe("invalid-argument");
    await db.recursiveDelete(db.doc(`posts/${created.id}`));
    await db.recursiveDelete(db.doc("hashtags/dogs")).catch(() => undefined);
  });

  it("does not take the pet's postCount down with it if one is already stored", async () => {
    // A post that predates the validator. The trigger must skip the unusable
    // tag rather than throw out of the transaction that also carries the pet
    // count — that failure was silent, and cost the pet its count.
    await db.doc(POST).update({ tags: ["dogs/cats"], petId: "contrib-pet" });
    const after = await captureSnapshot(POST);

    const code = await errorCodeOf(() =>
      deliverWritten(onPostWritten, undefined, after, params, newEventId("slash"))
    );

    expect(code).toBe(null);
    expect(await fieldOf(PET, "postCount")).toBe(1);
  });
});

describe("admin repair", () => {
  it("does not double-count a like whose trigger has not run yet", async () => {
    await db.doc(`${POST}/likes/liker1`).set({ userId: "liker1", counted: false });

    const repaired = await callAs<{ likeCount: number; pendingLikes: number }>(
      recomputePostInteractionCountsCallable,
      ADMIN_UID,
      { postId: "contrib-post" }
    );
    // One like exists but has not been folded in, so the repaired count is 0.
    expect(repaired.likeCount).toBe(0);
    expect(repaired.pendingLikes).toBe(1);

    await deliverCreate(
      onLikeCreated,
      `${POST}/likes/liker1`,
      { postId: "contrib-post", likeId: "liker1" },
      newEventId("like")
    );

    expect(await fieldOf(POST, "likeCount")).toBe(1);
  });

  it("does the same for comments", async () => {
    await db.doc(`${POST}/comments/c1`).set({
      authorId: "someone",
      authorName: "Someone",
      text: "hi",
      counted: false,
    });

    const repaired = await callAs<{ commentCount: number }>(
      recomputePostInteractionCountsCallable,
      ADMIN_UID,
      { postId: "contrib-post" }
    );
    expect(repaired.commentCount).toBe(0);

    await deliverCreate(
      onCommentCreated,
      `${POST}/comments/c1`,
      { postId: "contrib-post", commentId: "c1" },
      newEventId("comment")
    );

    expect(await fieldOf(POST, "commentCount")).toBe(1);
  });

  it("still repairs drift on an already-counted like", async () => {
    await db.doc(`${POST}/likes/liker1`).set({ userId: "liker1", counted: true });
    await db.doc(POST).update({ likeCount: 7 });

    const repaired = await callAs<{ likeCount: number }>(
      recomputePostInteractionCountsCallable,
      ADMIN_UID,
      { postId: "contrib-post" }
    );

    expect(repaired.likeCount).toBe(1);
    expect(await fieldOf(POST, "likeCount")).toBe(1);
  });

  it("settles a pet's posts before counting them, so a pending trigger is a no-op", async () => {
    const created = await callAs<{ id: string }>(createPostCallable, OWNER, {
      petId: "contrib-pet",
      text: "unpublished aggregate",
    });
    // The aggregation trigger has not been delivered: the pet's count is still
    // 0 and the post's marker says nothing has been applied.
    expect(await fieldOf(PET, "postCount")).toBe(0);

    const repaired = await callAs<{ postCount: number; settled: number }>(
      recomputePetPostCountCallable,
      ADMIN_UID,
      { petId: "contrib-pet" }
    );
    expect(repaired.postCount).toBe(1);
    expect(repaired.settled).toBe(1);

    // Now the pending trigger arrives. It must find nothing left to do.
    const snap = await captureSnapshot(`posts/${created.id}`);
    await deliverWritten(
      onPostWritten,
      undefined,
      snap,
      { postId: created.id },
      newEventId("late")
    );

    expect(await fieldOf(PET, "postCount")).toBe(1);
    await db.recursiveDelete(db.doc(`posts/${created.id}`));
  });
});
