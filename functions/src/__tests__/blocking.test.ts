import "./setup";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import { createCommentCallable } from "../posts";
import { onLikeCreated } from "../notifications";
import { createPetCallable } from "../pets";
import { joinMeetupCallable } from "../meetups";
import {
  callAs,
  clearRateLimits,
  deliverCreate,
  errorCodeOf,
  newEventId,
} from "./helpers";

/**
 * Blocking used to be a client-side filter with a server-side storage rule and
 * nothing in between: the blocked account could still comment under the
 * blocker's post and still join the blocker's meetup — which, for a
 * participants_only meetup, is also how it would have learned the organizer's
 * address.
 *
 * These tests pin the rule down in both directions and pin down what it
 * deliberately does not do. See ../blocking.ts for why the pair is the two
 * humans rather than a pet's whole family.
 */

const BLOCKER = "blk-blocker";
const BLOCKED = "blk-blocked";
const BYSTANDER = "blk-bystander";

async function seedUser(uid: string) {
  await db.doc(`users/${uid}`).set({
    displayName: uid,
    email: `${uid}@example.com`,
  });
}

async function block(blockerUid: string, blockedUid: string) {
  await db.doc(`users/${blockerUid}/blockedUsers/${blockedUid}`).set({
    blockedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
}

async function seedPost(id: string, authorId: string) {
  await db.doc(`posts/${id}`).set({
    authorId,
    caption: "hello",
    commentCount: 0,
    likeCount: 0,
  });
}

async function seedMeetup(id: string, organizerId: string) {
  await db.doc(`meetups/${id}`).set({
    organizerId,
    title: "Morning walk",
    status: "upcoming",
    participantCount: 1,
    requirements: {},
    locationId: "blk-loc",
    date: admin.firestore.Timestamp.fromMillis(Date.now() + 86_400_000),
  });
}

async function petFor(uid: string, name: string): Promise<string> {
  const pet = await callAs<{ id?: string; petId?: string }>(
    createPetCallable,
    uid,
    { name, species: "dog", gender: "male" }
  );
  return (pet.id ?? pet.petId) as string;
}

async function wipe() {
  for (const c of [
    "users",
    "pets",
    "posts",
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
  for (const uid of [BLOCKER, BLOCKED, BYSTANDER]) await seedUser(uid);
});
afterAll(wipe);

describe("commenting", () => {
  it("refuses a comment from someone the author blocked", async () => {
    await seedPost("p1", BLOCKER);
    await block(BLOCKER, BLOCKED);

    const code = await errorCodeOf(() =>
      callAs(createCommentCallable, BLOCKED, { postId: "p1", text: "hi" })
    );

    expect(code).toBe("permission-denied");
    expect((await db.collection("posts/p1/comments").get()).empty).toBe(true);
  });

  it("refuses a comment on the post of someone the caller blocked", async () => {
    // Symmetric on purpose: blocking someone and then commenting under their
    // post would be a way to have the last word.
    await seedPost("p1", BLOCKED);
    await block(BLOCKER, BLOCKED);

    const code = await errorCodeOf(() =>
      callAs(createCommentCallable, BLOCKER, { postId: "p1", text: "hi" })
    );

    expect(code).toBe("permission-denied");
  });

  it("refuses a reply aimed at a commenter who blocked the caller", async () => {
    await seedPost("p1", BYSTANDER);
    const parent = await callAs<{ id: string }>(createCommentCallable, BLOCKER, {
      postId: "p1",
      text: "first",
    });
    await block(BLOCKER, BLOCKED);

    const code = await errorCodeOf(() =>
      callAs(createCommentCallable, BLOCKED, {
        postId: "p1",
        text: "reply",
        replyToCommentId: parent.id,
      })
    );

    expect(code).toBe("permission-denied");
  });

  it("leaves unrelated people alone", async () => {
    await seedPost("p1", BLOCKER);
    await block(BLOCKER, BLOCKED);

    const code = await errorCodeOf(() =>
      callAs(createCommentCallable, BYSTANDER, { postId: "p1", text: "hi" })
    );

    expect(code).toBe(null);
  });

  it("does not stop the blocked account from commenting elsewhere", async () => {
    await seedPost("p2", BYSTANDER);
    await block(BLOCKER, BLOCKED);

    const code = await errorCodeOf(() =>
      callAs(createCommentCallable, BLOCKED, { postId: "p2", text: "hi" })
    );

    expect(code).toBe(null);
  });
});

describe("joining a meetup", () => {
  it("refuses a join by someone the organizer blocked", async () => {
    await seedMeetup("m1", BLOCKER);
    await block(BLOCKER, BLOCKED);
    const petId = await petFor(BLOCKED, "Bud");

    const code = await errorCodeOf(() =>
      callAs(joinMeetupCallable, BLOCKED, { meetupId: "m1", petId })
    );

    expect(code).toBe("permission-denied");
    // The roster entry is what would have unlocked meetups/m1/private/address
    // under the participant read rule.
    expect((await db.doc(`meetups/m1/participants/${BLOCKED}`).get()).exists).toBe(
      false
    );
  });

  it("refuses a join into the meetup of someone the caller blocked", async () => {
    await seedMeetup("m1", BLOCKED);
    await block(BLOCKER, BLOCKED);
    const petId = await petFor(BLOCKER, "Kiwi");

    const code = await errorCodeOf(() =>
      callAs(joinMeetupCallable, BLOCKER, { meetupId: "m1", petId })
    );

    expect(code).toBe("permission-denied");
  });

  it("still admits everyone else", async () => {
    await seedMeetup("m1", BLOCKER);
    await block(BLOCKER, BLOCKED);
    const petId = await petFor(BYSTANDER, "Peach");

    const result = await callAs<{ success: boolean }>(
      joinMeetupCallable,
      BYSTANDER,
      { meetupId: "m1", petId }
    );

    expect(result.success).toBe(true);
    expect(
      (await db.doc(`meetups/m1/participants/${BYSTANDER}`).get()).exists
    ).toBe(true);
  });
});

describe("notification fan-out", () => {
  /**
   * A like is written straight to posts/{id}/likes/{uid} under a Firestore
   * rule, not through a callable, so the trigger fan-out is the only place a
   * block can stop the resulting "X liked your post" from arriving.
   */
  async function deliverLike(postId: string, likerUid: string) {
    const path = `posts/${postId}/likes/${likerUid}`;
    await db.doc(path).set({ userId: likerUid, counted: false });
    // The trigger reads the liker's uid out of the {likeId} path segment.
    await deliverCreate(
      onLikeCreated,
      path,
      { postId, likeId: likerUid },
      newEventId("like")
    );
  }

  it("drops a like notification aimed at someone who blocked the liker", async () => {
    await seedPost("p1", BLOCKER);
    await block(BLOCKER, BLOCKED);

    await deliverLike("p1", BLOCKED);

    const notes = await db
      .collection("notifications")
      .where("userId", "==", BLOCKER)
      .get();
    expect(notes.empty).toBe(true);
  });

  it("still delivers a like notification from anyone else", async () => {
    await seedPost("p1", BLOCKER);
    await block(BLOCKER, BLOCKED);

    await deliverLike("p1", BYSTANDER);

    const notes = await db
      .collection("notifications")
      .where("userId", "==", BLOCKER)
      .get();
    expect(notes.size).toBe(1);
    expect(notes.docs[0].data().fromUserId).toBe(BYSTANDER);
  });

  it("suppresses only the co-owner who blocked, not the pet's other owners", async () => {
    // The shared-pet case, and the reason the pair is the two humans rather
    // than the pet's family: a like on a post about a co-owned pet fans out to
    // every owner, and one owner's private block list must not decide what the
    // others hear about.
    const petId = await petFor(BLOCKER, "Shared");
    await db.doc(`pets/${petId}/family/${BYSTANDER}`).set({
      userId: BYSTANDER,
      role: "member",
      relationship: "best_friend",
      joinedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await db.doc("posts/p1").set({
      authorId: BLOCKER,
      petId,
      petName: "Shared",
      caption: "hello",
      commentCount: 0,
      likeCount: 0,
    });
    await block(BLOCKER, BLOCKED);

    await deliverLike("p1", BLOCKED);

    const recipients = (await db.collection("notifications").get()).docs.map(
      (d) => d.data().userId
    );
    expect(recipients).toContain(BYSTANDER);
    expect(recipients).not.toContain(BLOCKER);
  });
});

describe("what a block is not", () => {
  it("does not make the blocker's post unreadable", async () => {
    // Posts are world-readable by design — readable while logged out — so no
    // server check can hide them, and the UI copy must not claim it does.
    // This is here so that a future "blocking hides content" change has to
    // come past a test that says the product decided otherwise.
    await seedPost("p1", BLOCKER);
    await block(BLOCKER, BLOCKED);

    const post = await db.doc("posts/p1").get();
    expect(post.exists).toBe(true);
    expect(post.data()?.authorId).toBe(BLOCKER);
  });
});
