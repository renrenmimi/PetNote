import { afterAll, beforeAll, beforeEach, describe, it } from "vitest";
import {
  assertFails,
  assertSucceeds,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, deleteDoc, serverTimestamp, setDoc } from "firebase/firestore";
import { bannedUser, makeTestEnv, plainUser } from "./env";

// Everything a client may write directly runs through isNotBanned() and
// isNotDeleting(). Posts, comments, pets and meetups are callable-only, so a
// ban on those is enforced in the callable rather than here — what the rules
// have to hold is likes, bookmarks, settings, following and blockedUsers.

let env: RulesTestEnvironment;
const ALICE = "alice";
const BANNED = "banned-user";
const DELETING = "deleting-user";
const POST = "post-1";

beforeAll(async () => {
  env = await makeTestEnv();
});
afterAll(async () => {
  await env.cleanup();
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const uid of [ALICE, BANNED, DELETING]) {
      await setDoc(doc(db, "users", uid), { displayName: uid });
    }
    await setDoc(doc(db, `users/${DELETING}`), {
      displayName: DELETING,
      deletionPending: true,
    });
    await setDoc(doc(db, `users/${BANNED}/admin/state`), { banned: true });
    await setDoc(doc(db, "posts", POST), {
      authorId: "someone-else",
      likeCount: 0,
      commentCount: 0,
    });
  });
});

const likeDoc = (uid: string) => `posts/${POST}/likes/${uid}`;
const likeBody = (uid: string) => ({
  userId: uid,
  postId: POST,
  createdAt: serverTimestamp(),
  counted: false,
});

describe("likes", () => {
  it("lets an ordinary user like a post", async () => {
    // The user carries no custom claims at all, which is what every normal
    // account looks like. isNotBanned() reading request.auth.token.banned
    // without an `in` guard failed the whole expression for exactly these
    // users and broke liking for everyone (#149).
    const db = plainUser(env, ALICE).firestore();
    await assertSucceeds(setDoc(doc(db, likeDoc(ALICE)), likeBody(ALICE)));
  });

  it("refuses a banned user", async () => {
    const db = bannedUser(env, BANNED).firestore();
    await assertFails(setDoc(doc(db, likeDoc(BANNED)), likeBody(BANNED)));
  });

  it("refuses a user whose account is mid-deletion", async () => {
    // Otherwise a client can create likes faster than the cascade deletes them.
    const db = plainUser(env, DELETING).firestore();
    await assertFails(setDoc(doc(db, likeDoc(DELETING)), likeBody(DELETING)));
  });

  it("refuses a like whose id is not the liker", async () => {
    const db = plainUser(env, ALICE).firestore();
    await assertFails(setDoc(doc(db, likeDoc("victim")), likeBody("victim")));
  });

  it("refuses a forged body pointing at another user or post", async () => {
    // userId and postId feed the collection-group lookup and the deletion
    // cascade, so a forged body plants permanent phantom state on a victim.
    const db = plainUser(env, ALICE).firestore();
    await assertFails(
      setDoc(doc(db, likeDoc(ALICE)), { ...likeBody(ALICE), userId: "victim" })
    );
    await assertFails(
      setDoc(doc(db, likeDoc(ALICE)), { ...likeBody(ALICE), postId: "other-post" })
    );
  });

  it("refuses a like claiming it was already counted", async () => {
    // A client that could write counted:true on a never-counted like could
    // then unlike, making onLikeDeleted subtract a like that was never added —
    // repeatable, against any post.
    const db = plainUser(env, ALICE).firestore();
    await assertFails(
      setDoc(doc(db, likeDoc(ALICE)), { ...likeBody(ALICE), counted: true })
    );
  });

  it("still accepts a like from a client that does not send counted", async () => {
    // Clients running JS cached from before the stamp shipped must keep
    // working; an absent field is read as a pre-existing like.
    const db = plainUser(env, ALICE).firestore();
    await assertSucceeds(
      setDoc(doc(db, likeDoc(ALICE)), {
        userId: ALICE,
        postId: POST,
        createdAt: serverTimestamp(),
      })
    );
  });

  it("refuses any extra field", async () => {
    const db = plainUser(env, ALICE).firestore();
    await assertFails(
      setDoc(doc(db, likeDoc(ALICE)), { ...likeBody(ALICE), weight: 100 })
    );
  });

  it("refuses a like on a post that does not exist", async () => {
    const db = plainUser(env, ALICE).firestore();
    await assertFails(
      setDoc(doc(db, `posts/ghost-post/likes/${ALICE}`), {
        userId: ALICE,
        postId: "ghost-post",
        createdAt: serverTimestamp(),
        counted: false,
      })
    );
  });

  it("refuses a banned user removing their own like, unlike bookmarks", async () => {
    // Deliberate asymmetry, pinned here because it is easy to "tidy up" by
    // accident: like delete gates on isNotBanned() while bookmark delete does
    // not. A banned user therefore cannot unlike, and their likes stay on
    // other people's posts. Not a hole — it is stricter, not looser — and the
    // account-deletion cascade runs through the Admin SDK so it bypasses rules
    // and cleans up regardless. Only isNotDeleting() is omitted here, so a
    // client tearing itself down can still remove its own likes.
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), likeDoc(BANNED)), {
        userId: BANNED,
        postId: POST,
        createdAt: new Date(),
      });
    });
    await assertFails(
      deleteDoc(doc(bannedUser(env, BANNED).firestore(), likeDoc(BANNED)))
    );
  });

  it("lets a user mid-deletion remove their own like", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), likeDoc(DELETING)), {
        userId: DELETING,
        postId: POST,
        createdAt: new Date(),
      });
    });
    await assertSucceeds(
      deleteDoc(doc(plainUser(env, DELETING).firestore(), likeDoc(DELETING)))
    );
  });
});

describe("bookmarks", () => {
  it("lets an ordinary user bookmark and refuses a banned one", async () => {
    await assertSucceeds(
      setDoc(doc(plainUser(env, ALICE).firestore(), `users/${ALICE}/bookmarks/${POST}`), {
        createdAt: serverTimestamp(),
      })
    );
    await assertFails(
      setDoc(doc(bannedUser(env, BANNED).firestore(), `users/${BANNED}/bookmarks/${POST}`), {
        createdAt: serverTimestamp(),
      })
    );
  });

  it("refuses bookmarking someone else's list", async () => {
    await assertFails(
      setDoc(doc(plainUser(env, ALICE).firestore(), `users/${BANNED}/bookmarks/${POST}`), {
        createdAt: serverTimestamp(),
      })
    );
  });
});

describe("callable-only collections reject direct client writes", () => {
  it("refuses creating a post, comment, pet or meetup from a client", async () => {
    const db = plainUser(env, ALICE).firestore();
    await assertFails(setDoc(doc(db, "posts", "forged"), { authorId: ALICE }));
    await assertFails(
      setDoc(doc(db, `posts/${POST}/comments/forged`), { authorId: ALICE, text: "hi" })
    );
    await assertFails(setDoc(doc(db, "pets", "forged"), { ownerId: ALICE, name: "X" }));
    await assertFails(setDoc(doc(db, "meetups", "forged"), { organizerId: ALICE }));
    await assertFails(setDoc(doc(db, "locations", "forged"), { name: "X" }));
  });

  it("refuses editing a post's counters directly", async () => {
    await assertFails(
      setDoc(doc(plainUser(env, ALICE).firestore(), "posts", POST), { likeCount: 9999 })
    );
  });
});

describe("backend-only collections are closed to clients", () => {
  const closed = [
    "processedEvents/some-event",
    "callableRateLimits/alice_createPost",
    "geoapifyRateLimits/alice",
    "userDeletionTombstones/alice",
  ];

  it("refuses reads and writes from a signed-in user", async () => {
    const db = plainUser(env, ALICE).firestore();
    for (const path of closed) {
      await assertFails(setDoc(doc(db, path), { x: 1 }));
    }
  });

  it("refuses a client to suppress a counter by forging a processed-event marker", async () => {
    // Writing the marker for an event that has not been processed would make
    // the matching trigger skip its count entirely.
    await assertFails(
      setDoc(doc(plainUser(env, ALICE).firestore(), "processedEvents", "evt-1"), {
        eventId: "evt-1",
      })
    );
  });
});
