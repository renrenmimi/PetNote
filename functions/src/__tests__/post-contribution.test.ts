import "./setup";
import { beforeEach, afterAll, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import { onLikeCreated, onCommentCreated } from "../notifications";
import {
  countAppliedPetPosts,
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

describe("admin repair running at the same time as a trigger", () => {
  /**
   * The repair takes aggregate counts and then writes an absolute value. A
   * trigger that increments in between has its work overwritten, and the
   * counter is left permanently one short of the truth.
   *
   * The invariant asserted here is the counter's actual meaning: once both
   * have finished, likeCount equals the number of likes whose contribution has
   * been applied — which, with every like's trigger delivered, is all of them.
   *
   * Repeated, because which side lands first is not deterministic. Before the
   * fix this fails on most runs; after it, no interleaving can break it.
   */
  it("does not lose a like that was counted while the repair was running", async () => {
    for (let attempt = 0; attempt < 4; attempt += 1) {
      await resetWorld();
      // Two likes already folded in, and a third whose trigger is about to run.
      await db.doc(`${POST}/likes/liker-a`).set({ userId: "liker-a", counted: true });
      await db.doc(`${POST}/likes/liker-b`).set({ userId: "liker-b", counted: true });
      await db.doc(POST).update({ likeCount: 2 });
      const pendingPath = `${POST}/likes/liker-c`;
      await db.doc(pendingPath).set({ userId: "liker-c", counted: false });

      await Promise.all([
        callAs(recomputePostInteractionCountsCallable, ADMIN_UID, {
          postId: "contrib-post",
        }),
        deliverCreate(
          onLikeCreated,
          pendingPath,
          { postId: "contrib-post", likeId: "liker-c" },
          newEventId("race-like")
        ),
      ]);

      // Order-independent: the counter must equal the number of likes whose
      // contribution has been applied, whichever side finished first.
      const likes = await db.collection(`${POST}/likes`).get();
      const counted = likes.docs.filter((d) => d.data().counted !== false).length;
      expect(await fieldOf(POST, "likeCount"), `attempt ${attempt}, counted ${counted}`).toBe(
        counted
      );
    }
  }, 60_000);

  it("does not lose a post that was counted while the pet repair was running", async () => {
    for (let attempt = 0; attempt < 4; attempt += 1) {
      await resetWorld();
      await db.doc(SURVIVOR).set({
        authorId: OWNER,
        petId: "contrib-pet",
        tags: [],
        text: "already counted",
        countedContribution: { petId: "contrib-pet", tags: [] },
      });
      await db.doc(PET).update({ postCount: 1 });
      // A second post whose aggregation trigger has not run yet.
      await db.doc(POST).set({
        authorId: OWNER,
        petId: "contrib-pet",
        tags: [],
        text: "pending",
        countedContribution: { petId: null, tags: [] },
      });
      const pending = await captureSnapshot(POST);

      await Promise.all([
        callAs(recomputePetPostCountCallable, ADMIN_UID, { petId: "contrib-pet" }),
        deliverWritten(onPostWritten, undefined, pending, params, newEventId("race-post")),
      ]);

      expect(await fieldOf(PET, "postCount"), `attempt ${attempt}`).toBe(2);
    }
  }, 60_000);
});

describe("repairing a pet's post count counts only settled contributions", () => {
  /**
   * The count the repair writes has to mean the same thing the triggers
   * maintain: how many posts have *applied* their contribution to this pet.
   *
   * Taking an absolute `count()` over every live post does not mean that. A
   * post that exists but whose aggregation trigger has not run yet is counted
   * by the repair and then counted again by its own trigger. Settling every
   * post first closes that for posts the scan can see — but a post created
   * after the scan and before the count is still double-counted, and the
   * compare-and-set does not notice, because it only watches the parent
   * number and the parent number has not moved yet.
   */
  it("does not count a post whose contribution has not been applied", async () => {
    await db.doc(SURVIVOR).set({
      authorId: OWNER,
      petId: "contrib-pet",
      tags: [],
      text: "settled",
      countedContribution: { petId: "contrib-pet", tags: [] },
    });
    await db.doc(PET).update({ postCount: 1 });
    // A post exactly as createPostCallable writes it: marker present, empty,
    // trigger not yet delivered. This is what a post created between the
    // repair's settle pass and its count looks like.
    await db.doc(POST).set({
      authorId: OWNER,
      petId: "contrib-pet",
      tags: [],
      text: "not applied yet",
      countedContribution: { petId: null, tags: [] },
    });

    const applied = await countAppliedPetPosts("contrib-pet");

    expect(applied).toBe(1);
  });

  it("counts a post once its contribution has been applied", async () => {
    await db.doc(SURVIVOR).set({
      authorId: OWNER,
      petId: "contrib-pet",
      tags: [],
      text: "settled",
      countedContribution: { petId: "contrib-pet", tags: [] },
    });
    await db.doc(POST).set({
      authorId: OWNER,
      petId: "contrib-pet",
      tags: [],
      text: "also settled",
      countedContribution: { petId: "contrib-pet", tags: [] },
    });

    expect(await countAppliedPetPosts("contrib-pet")).toBe(2);
  });

  it("keeps the count and the trigger consistent when a post arrives during the repair", async () => {
    // The interleaving the reviewer demonstrated with an injected pause,
    // approached from the outside: publish while the repair runs, then let the
    // new post's trigger land, and require the counter to equal the number of
    // applied contributions. Repeated, because which side wins is not
    // deterministic.
    for (let attempt = 0; attempt < 4; attempt += 1) {
      await resetWorld();
      await db.doc(SURVIVOR).set({
        authorId: OWNER,
        petId: "contrib-pet",
        tags: [],
        text: "settled",
        countedContribution: { petId: "contrib-pet", tags: [] },
      });
      await db.doc(PET).update({ postCount: 1 });

      const [, created] = await Promise.all([
        callAs(recomputePetPostCountCallable, ADMIN_UID, { petId: "contrib-pet" }),
        callAs<{ id: string }>(createPostCallable, OWNER, {
          petId: "contrib-pet",
          text: "arrived during the repair",
        }),
      ]);

      // The new post's aggregation trigger runs afterwards, as it would.
      const snap = await captureSnapshot(`posts/${created.id}`);
      await deliverWritten(
        onPostWritten,
        undefined,
        snap,
        { postId: created.id },
        newEventId("during-repair")
      );

      const applied = await countAppliedPetPosts("contrib-pet");
      expect(
        await fieldOf(PET, "postCount"),
        `attempt ${attempt}, applied ${applied}`
      ).toBe(applied);
      await db.recursiveDelete(db.doc(`posts/${created.id}`));
    }
  }, 60_000);
});
