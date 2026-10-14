import "./setup";
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Transaction } from "firebase-admin/firestore";
import { db, FieldValue } from "../platform";
import { onCommentDeleted, onFollowingPetCreated, onLikeCreated } from "../notifications";
import { CONTENTION_RETRY, nothingToCountIfGone, runEventOnce } from "../shared";
import { captureSnapshot, clearEventLedger, deliverCreate, deliverDelete, deliverLateCreate, fieldOf, newEventId, purge, serverTime } from "./helpers";

// Two hundred likes on one post at the same moment had 23 of their counting
// transactions aborted for contention on the test project, and the triggers
// are not redelivered. runEventOnce now waits and tries a contended
// transaction again, and the counting triggers no longer lock the post by
// reading it.

const POST = "posts/contention-post";
const PET = "pets/contention-pet";
const COUNTER = "contention/counter";

const aborted = () =>
  Object.assign(new Error("10 ABORTED: Aborted due to cross-transaction contention."), { code: 10 });

beforeEach(async () => {
  await purge(POST, PET, COUNTER);
  await clearEventLedger();
  await db.doc(POST).set({ authorId: "author", text: "post", likeCount: 0, commentCount: 0, petId: null });
  await db.doc(PET).set({ name: "Crowd", ownerId: "owner", followerCount: 0, postCount: 0 });
  await db.doc(COUNTER).set({ n: 0 });
});
afterEach(() => vi.restoreAllMocks());
afterAll(async () => {
  await purge(POST, PET, COUNTER);
  await clearEventLedger();
});

describe("runEventOnce under contention", () => {
  const saved = { ...CONTENTION_RETRY };
  beforeEach(() => Object.assign(CONTENTION_RETRY, { baseMs: 1, capMs: 2 }));
  afterEach(() => Object.assign(CONTENTION_RETRY, saved));

  /** The first `failures` transactions abort for contention; the rest run. */
  function contended(failures: number) {
    const real = db.runTransaction.bind(db);
    let calls = 0;
    vi.spyOn(db, "runTransaction").mockImplementation(((...args: Parameters<typeof db.runTransaction>) => {
      calls += 1;
      return calls <= failures ? Promise.reject(aborted()) : real(...args);
    }) as typeof db.runTransaction);
    return { calls: () => calls };
  }

  const increment = (t: Transaction) => {
    t.update(db.doc(COUNTER), { n: FieldValue.increment(1) });
    return Promise.resolve(true);
  };

  it("tries a contended transaction again, and applies the event once", async () => {
    const tx = contended(2);

    expect(await runEventOnce(newEventId("contended"), increment)).toBe(true);

    expect(tx.calls()).toBe(3);
    expect(await fieldOf(COUNTER, "n")).toBe(1);
  });

  it("still says so when every try is contended", async () => {
    const tx = contended(Infinity);

    await expect(runEventOnce(newEventId("hopeless"), increment)).rejects.toMatchObject({ code: 10 });

    expect(tx.calls()).toBe(CONTENTION_RETRY.retries + 1);
    expect(await fieldOf(COUNTER, "n")).toBe(0);
  });

  it("does not try again after an error that is not contention", async () => {
    let calls = 0;
    vi.spyOn(db, "runTransaction").mockImplementation((() => {
      calls += 1;
      return Promise.reject(Object.assign(new Error("7 PERMISSION_DENIED"), { code: 7 }));
    }) as unknown as typeof db.runTransaction);

    await expect(runEventOnce(newEventId("denied"), increment)).rejects.toMatchObject({ code: 7 });
    expect(calls).toBe(1);
  });

  it("treats a gone document as nothing to count, and nothing else", () => {
    expect(nothingToCountIfGone(Object.assign(new Error("5 NOT_FOUND"), { code: 5 }))).toBe(false);
    expect(() => nothingToCountIfGone(aborted())).toThrow("ABORTED");
  });
});

/** `path` is deleted when the next transaction starts: after a trigger's existence check, before its commit. */
function goneBeforeTheCommit(path: string) {
  const real = db.runTransaction.bind(db);
  let first = true;
  vi.spyOn(db, "runTransaction").mockImplementation((async (...args: Parameters<typeof db.runTransaction>) => {
    if (first) {
      first = false;
      await db.doc(path).delete();
    }
    return real(...args);
  }) as typeof db.runTransaction);
}

describe("the counting triggers without reading the post", () => {
  const like = (id: string) => `${POST}/likes/${id}`;
  const writeLike = (id: string) =>
    db.doc(like(id)).set({ userId: id, postId: "contention-post", createdAt: serverTime(), counted: false });

  it("counts many likes delivered at once, every one", async () => {
    const likers = Array.from({ length: 20 }, (_, i) => `liker-${i}`);
    await Promise.all(likers.map(writeLike));

    await Promise.all(likers.map((id) =>
      deliverCreate(onLikeCreated, like(id), { postId: "contention-post", likeId: id }, newEventId("like"))));

    expect(await fieldOf(POST, "likeCount")).toBe(20);
    const counted = await Promise.all(likers.map(async (id) => (await db.doc(like(id)).get()).get("counted")));
    expect(counted.every((c) => c === true)).toBe(true);
  });

  it("counts nothing for a like whose post goes before the count commits, and does not fail", async () => {
    await writeLike("late-liker");
    goneBeforeTheCommit(POST);

    await deliverCreate(onLikeCreated, like("late-liker"), { postId: "contention-post", likeId: "late-liker" }, newEventId("like"));

    expect((await db.doc(POST).get()).exists, "the update brought the post back").toBe(false);
    expect((await db.doc(like("late-liker")).get()).get("counted")).toBe(false);
  });

  it("undoes nothing for a comment deleted from a post that is gone, and does not fail", async () => {
    const path = `${POST}/comments/c1`;
    await db.doc(path).set({ authorId: "a", text: "hi", createdAt: serverTime(), counted: true });
    const snapshot = await captureSnapshot(path);
    await db.doc(POST).delete();

    await deliverDelete(onCommentDeleted, snapshot, { postId: "contention-post", commentId: "c1" }, newEventId("comment-delete"));

    expect((await db.doc(POST).get()).exists).toBe(false);
  });
});

describe("following without reading the pet", () => {
  const follow = (uid: string) => `users/${uid}/followingPets/contention-pet`;
  const writeFollow = async (uid: string) => {
    await db.doc(`users/${uid}`).set({ displayName: uid, followingPetsCount: 0 });
    await db.doc(follow(uid)).set({ petId: "contention-pet", followedAt: serverTime(), counted: false });
  };
  afterAll(async () => {
    await purge(...Array.from({ length: 20 }, (_, i) => `users/follower-${i}`), "users/late-follower", "users/swept-follower");
  });

  it("counts many follows of one pet delivered at once, every one", async () => {
    const followers = Array.from({ length: 20 }, (_, i) => `follower-${i}`);
    await Promise.all(followers.map(writeFollow));

    await Promise.all(followers.map((uid) =>
      deliverCreate(onFollowingPetCreated, follow(uid), { userId: uid, petId: "contention-pet" }, newEventId("follow"))));

    expect(await fieldOf(PET, "followerCount")).toBe(20);
    expect(await fieldOf("users/follower-7", "followingPetsCount")).toBe(1);
  });

  it("counts nothing for a follow whose pet goes before the count commits, and does not fail", async () => {
    await writeFollow("late-follower");
    goneBeforeTheCommit(PET);

    await deliverCreate(onFollowingPetCreated, follow("late-follower"), { userId: "late-follower", petId: "contention-pet" }, newEventId("follow"));

    expect((await db.doc(PET).get()).exists, "the update brought the pet back").toBe(false);
    expect(await fieldOf("users/late-follower", "followingPetsCount")).toBe(0);
    expect((await db.doc(follow("late-follower")).get()).get("counted")).toBe(false);
    expect((await db.doc("pets/contention-pet/followers/late-follower").get()).exists).toBe(false);
  });

  it("does not write back a follow that went with its pet before the trigger ran", async () => {
    // The pet is deleted and its follows swept before this follow's create
    // trigger runs. Finding no pet, the trigger must not write the follow
    // back: in the cloud that is a new follow, which sets the trigger off
    // again, to find the pet still gone and do the same, for as long as the
    // pet stays deleted. Here no second event is delivered, so what is
    // checked is the write itself.
    await writeFollow("swept-follower");
    const snapshot = await captureSnapshot(follow("swept-follower"));
    await db.doc(PET).delete();
    await db.doc(follow("swept-follower")).delete();
    const set = vi.spyOn(snapshot.ref, "set");
    const create = vi.spyOn(snapshot.ref, "create");

    await deliverLateCreate(onFollowingPetCreated, snapshot, { userId: "swept-follower", petId: "contention-pet" }, newEventId("follow"));

    expect(set, "the follow was written back").not.toHaveBeenCalled();
    expect(create, "the follow was written back").not.toHaveBeenCalled();
    expect((await db.doc(follow("swept-follower")).get()).exists).toBe(false);
    expect(await fieldOf("users/swept-follower", "followingPetsCount")).toBe(0);
  });
});

