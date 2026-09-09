import "./setup";
import { beforeEach, afterAll, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import { onLikeCreated } from "../notifications";
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
const SURVIVOR = "posts/contrib-survivor";
const PET = "pets/contrib-pet";
const OWNER = "contrib-owner";
const ADMIN_UID = "contrib-admin";
const TAG = "hashtags/parkday";

async function resetWorld() {
  await purge(POST, SURVIVOR, PET, `users/${OWNER}`, `users/${ADMIN_UID}`);
  // Posts published through the callable get random ids, so purging the two
  // fixture paths is not enough — a leftover from an earlier test would be
  // counted by anything that aggregates over the pet.
  const strays = await db.collection("posts").where("petId", "==", "contrib-pet").get();
  for (const d of strays.docs) await db.recursiveDelete(d.ref).catch(() => undefined);
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
  await purge(POST, SURVIVOR, PET, `users/${OWNER}`, `users/${ADMIN_UID}`);
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

  /**
   * Every assertion in this block keeps a *second*, still-counted post on the
   * same pet and tag.
   *
   * That is the whole point. An earlier version of these tests started the
   * aggregates at zero, so a spurious extra decrement went to -1, got clamped
   * back to 0, and the assertion passed — the clamp hid the bug it was
   * supposed to catch. With a surviving contribution the count has somewhere
   * to fall to, and a double subtraction is visible as 1 → 0.
   */
  async function twoCountedPosts() {
    const shared = {
      authorId: OWNER,
      petId: "contrib-pet",
      tags: ["parkday"],
      countedContribution: { petId: "contrib-pet", tags: ["parkday"] },
    };
    await db.doc(SURVIVOR).set({ ...shared, text: "survivor" });
    await db.doc(POST).set({ ...shared, text: "before" });
    await db.doc(PET).update({ postCount: 2 });
    await db.doc(TAG).set({ name: "parkday", postCount: 2 });
  }

  it("subtracts a deleted post's contribution exactly once, not twice", async () => {
    // The reported failure: the post is edited, then deleted; the delete event
    // is processed first and takes the count 2 → 1; then the post's own
    // delayed update event arrives. `live` is gone, but the handler fell back
    // to the update's `before` snapshot and derived a contribution to undo all
    // over again — 1 → 0, with one post still standing.
    await twoCountedPosts();
    const before = await captureSnapshot(POST);
    await db.doc(POST).update({ text: "after" });
    const after = await captureSnapshot(POST);
    await db.doc(POST).delete();
    const gone = await captureSnapshot(POST);

    await deliverWritten(onPostWritten, after, gone, params, newEventId("del"));
    expect(await fieldOf(PET, "postCount")).toBe(1);
    expect(await fieldOf(TAG, "postCount")).toBe(1);

    // The late update for a post that no longer exists.
    await deliverWritten(onPostWritten, before, after, params, newEventId("late"));

    const surviving = await db
      .collection("posts")
      .where("petId", "==", "contrib-pet")
      .count()
      .get();
    expect(surviving.data().count).toBe(1);
    expect(await fieldOf(PET, "postCount")).toBe(1);
    expect(await fieldOf(TAG, "postCount")).toBe(1);
    expect((await db.doc(TAG).get()).exists).toBe(true);
  });

  it("ignores a late create event for a post that has since been deleted", async () => {
    await twoCountedPosts();
    const created = await captureSnapshot(POST);
    await db.doc(POST).delete();
    const gone = await captureSnapshot(POST);

    await deliverWritten(onPostWritten, created, gone, params, newEventId("del"));
    await deliverWritten(onPostWritten, undefined, created, params, newEventId("cre"));

    expect(await fieldOf(PET, "postCount")).toBe(1);
    expect(await fieldOf(TAG, "postCount")).toBe(1);
  });

  it("subtracts a legacy post's contribution exactly once when its update is late", async () => {
    // Same shape, but the deleted post has no contribution marker at all —
    // the path where the handler is *supposed* to fall back to `before`.
    // Falling back is right for the delete event and wrong for anything that
    // arrives after it.
    await twoCountedPosts();
    await db.doc(POST).update({
      countedContribution: admin.firestore.FieldValue.delete(),
    });
    const before = await captureSnapshot(POST);
    await db.doc(POST).update({ text: "legacy edit" });
    const after = await captureSnapshot(POST);
    await db.doc(POST).delete();
    const gone = await captureSnapshot(POST);

    await deliverWritten(onPostWritten, after, gone, params, newEventId("legacy-del"));
    expect(await fieldOf(PET, "postCount")).toBe(1);

    await deliverWritten(onPostWritten, before, after, params, newEventId("legacy-late"));
    expect(await fieldOf(PET, "postCount")).toBe(1);
    expect(await fieldOf(TAG, "postCount")).toBe(1);
  });

  it("does nothing when the handler's own marker write comes back as an event", async () => {
    // Stamping countedContribution is itself a document write, so it produces
    // another onPostWritten event. That event must be a no-op, or every post
    // would be counted twice.
    await db.doc(SURVIVOR).set({
      authorId: OWNER,
      petId: "contrib-pet",
      tags: ["parkday"],
      text: "survivor",
      countedContribution: { petId: "contrib-pet", tags: ["parkday"] },
    });
    await db.doc(POST).set({
      authorId: OWNER,
      petId: "contrib-pet",
      tags: ["parkday"],
      text: "legacy",
    });
    await db.doc(PET).update({ postCount: 1 });
    await db.doc(TAG).set({ name: "parkday", postCount: 1 });

    const beforeStamp = await captureSnapshot(POST);
    await deliverWritten(onPostWritten, undefined, beforeStamp, params, newEventId("legacy-cre"));
    expect(await fieldOf(PET, "postCount")).toBe(2);
    expect(await fieldOf(TAG, "postCount")).toBe(2);

    // The write the handler just made, delivered back to it.
    const afterStamp = await captureSnapshot(POST);
    await deliverWritten(onPostWritten, beforeStamp, afterStamp, params, newEventId("marker-echo"));

    expect(await fieldOf(PET, "postCount")).toBe(2);
    expect(await fieldOf(TAG, "postCount")).toBe(2);
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

describe("the suspended interaction-count repair", () => {
  /**
   * Same window as the pet repair, and disabled for the same reason. Measured
   * before disabling: two counted likes, one deleted with its onLikeDeleted
   * event not yet delivered, the repair wrote 1 and reported converged, then
   * the event landed and the counter reached 0 with one like still there.
   */
  it("refuses, and leaves the stored counts untouched", async () => {
    await db.doc(`${POST}/likes/liker-a`).set({ userId: "liker-a", counted: true });
    await db.doc(POST).update({ likeCount: 9, commentCount: 4 });

    const code = await errorCodeOf(() =>
      callAs(recomputePostInteractionCountsCallable, ADMIN_UID, {
        postId: "contrib-post",
      })
    );

    expect(code).toBe("failed-precondition");
    // Not even a partial write: the refusal happens before any read.
    expect(await fieldOf(POST, "likeCount")).toBe(9);
    expect(await fieldOf(POST, "commentCount")).toBe(4);
  });

  it("refuses a non-admin with a permission error, not the unavailable one", async () => {
    // The authorisation answer must not change just because the feature is
    // off, or an ordinary user learns about admin endpoints.
    const code = await errorCodeOf(() =>
      callAs(recomputePostInteractionCountsCallable, OWNER, {
        postId: "contrib-post",
      })
    );
    expect(code).toBe("permission-denied");
  });

  it("leaves a pending like's count to its own trigger", async () => {
    // What the repair used to be for. The trigger still gets there unaided.
    await db.doc(POST).update({ likeCount: 0 });
    const likePath = `${POST}/likes/liker-c`;
    await db.doc(likePath).set({ userId: "liker-c", counted: false });

    await deliverCreate(
      onLikeCreated,
      likePath,
      { postId: "contrib-post", likeId: "liker-c" },
      newEventId("pending-like")
    );

    expect(await fieldOf(POST, "likeCount")).toBe(1);
  });
});

describe("a post arriving while the pet repair is called", () => {
  /**
   * The other direction from the pending-delete case below, kept because the
   * two fail differently: a post *added* during a repair was double-counted,
   * a post *being removed* was double-subtracted.
   *
   * With the repair suspended, both reduce to the same requirement — the
   * entry point must refuse, and the triggers must reach the right number on
   * their own.
   */
  it("refuses, and the trigger still gets the count right", async () => {
    await db.doc(SURVIVOR).set({
      authorId: OWNER,
      petId: "contrib-pet",
      tags: [],
      text: "settled",
      countedContribution: { petId: "contrib-pet", tags: [] },
    });
    await db.doc(PET).update({ postCount: 1 });

    const created = await callAs<{ id: string }>(createPostCallable, OWNER, {
      petId: "contrib-pet",
      text: "arrived alongside the repair",
    });
    const code = await errorCodeOf(() =>
      callAs(recomputePetPostCountCallable, ADMIN_UID, { petId: "contrib-pet" })
    );
    expect(code).toBe("failed-precondition");
    expect(await fieldOf(PET, "postCount")).toBe(1);

    const snap = await captureSnapshot(`posts/${created.id}`);
    await deliverWritten(
      onPostWritten,
      undefined,
      snap,
      { postId: created.id },
      newEventId("arrived")
    );

    const surviving = await db
      .collection("posts")
      .where("petId", "==", "contrib-pet")
      .count()
      .get();
    expect(surviving.data().count).toBe(2);
    expect(await fieldOf(PET, "postCount")).toBe(2);
    await db.recursiveDelete(db.doc(`posts/${created.id}`));
  });
});

describe("a post being deleted while the pet repair runs", () => {
  /**
   * The other direction from "a post arrives during the repair", and the one
   * the marker-keyed count does not cover.
   *
   * Creating is symmetric: the marker and the parent counter can move in one
   * transaction. Deleting is not. The post document — and with it the
   * contribution marker — goes first, and the parent counter waits for the
   * asynchronous delete event. In that window the marker query cannot see the
   * post, which does *not* mean the parent has already given up its
   * contribution. So "count the markers" and "what the triggers maintain" are
   * not the same quantity there, and an absolute write in between is wrong by
   * exactly one.
   */
  it("does not let the repair write a count that the pending delete will subtract again", async () => {
    await db.doc(SURVIVOR).set({
      authorId: OWNER,
      petId: "contrib-pet",
      tags: [],
      text: "survivor",
      countedContribution: { petId: "contrib-pet", tags: [] },
    });
    await db.doc(POST).set({
      authorId: OWNER,
      petId: "contrib-pet",
      tags: [],
      text: "being deleted",
      countedContribution: { petId: "contrib-pet", tags: [] },
    });
    await db.doc(PET).update({ postCount: 2 });

    // The post is gone; its delete event has not been delivered yet, so the
    // pet still owes a decrement.
    const beforeDelete = await captureSnapshot(POST);
    await db.doc(POST).delete();
    const gone = await captureSnapshot(POST);

    const code = await errorCodeOf(() =>
      callAs(recomputePetPostCountCallable, ADMIN_UID, { petId: "contrib-pet" })
    );
    // The repair must refuse rather than write a number it cannot justify.
    expect(code).toBe("failed-precondition");
    expect(await fieldOf(PET, "postCount")).toBe(2);

    // The delete event lands, and the triggers get it right on their own.
    await deliverWritten(onPostWritten, beforeDelete, gone, params, newEventId("late-del"));

    const surviving = await db
      .collection("posts")
      .where("petId", "==", "contrib-pet")
      .count()
      .get();
    expect(surviving.data().count).toBe(1);
    expect(await fieldOf(PET, "postCount")).toBe(1);
  });

  it("refuses the repair even when nothing is pending, and says why", async () => {
    // Disabled outright rather than conditionally: deciding "is anything
    // pending?" is the same unanswerable question, and a repair that works
    // most of the time is worse than one an admin knows is unavailable.
    await db.doc(SURVIVOR).set({
      authorId: OWNER,
      petId: "contrib-pet",
      tags: [],
      text: "survivor",
      countedContribution: { petId: "contrib-pet", tags: [] },
    });
    await db.doc(PET).update({ postCount: 1 });

    const code = await errorCodeOf(() =>
      callAs(recomputePetPostCountCallable, ADMIN_UID, { petId: "contrib-pet" })
    );

    expect(code).toBe("failed-precondition");
    expect(await fieldOf(PET, "postCount")).toBe(1);
  });

  it("still refuses for an admin, and does not report success", async () => {
    await db.doc(PET).update({ postCount: 7 });

    let reported: unknown = "no-result";
    const code = await errorCodeOf(async () => {
      reported = await callAs(recomputePetPostCountCallable, ADMIN_UID, {
        petId: "contrib-pet",
      });
    });

    expect(code).toBe("failed-precondition");
    expect(reported).toBe("no-result");
    // Untouched: a disabled repair must not half-write.
    expect(await fieldOf(PET, "postCount")).toBe(7);
  });
});
