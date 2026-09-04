import { afterAll, beforeAll, beforeEach, describe, it } from "vitest";
import {
  assertFails,
  assertSucceeds,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  collection,
  collectionGroup,
  doc,
  deleteDoc,
  getDoc,
  getDocs,
  query,
  serverTimestamp,
  setDoc,
  where,
} from "firebase/firestore";
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

  it("refuses a like that omits counted entirely", async () => {
    // This used to be allowed, on the reasoning that clients running JS from
    // before the stamp shipped had to keep working. It was exploitable, and
    // the exemption is what made it exploitable:
    //
    //   1. write a like with no `counted` — the old rule permitted it
    //   2. delete it before onLikeCreated runs — delete is permitted too
    //   3. onLikeDeleted calls wasCountedAtCreate(), which reads an ABSENT
    //      field as *already counted* (functions/src/shared.ts:341 — that
    //      reading is deliberate, it is what lets the scheme deploy without a
    //      backfill), so it applies increment(-1)
    //   4. the create trigger arrives late, finds the doc gone, declines, and
    //      never adds the 1 that was just subtracted
    //
    // Net -1 on any post the attacker chooses, repeatable: likes are the one
    // mutation with no rate limit and onLikeDeleted has no clamp, so
    // likeCount goes negative without limit.
    //
    // Neither half was wrong on its own — an optional field in the rules, and
    // absent-means-counted on the server. Only together.
    //
    // The stale-client cost that justified the exemption is bounded: there is
    // no service worker in this repo, and Vercel serves index.html with
    // `max-age=0, must-revalidate` in front of hash-named bundles, so a stale
    // client stops being stale on its next page load.
    const db = plainUser(env, ALICE).firestore();
    await assertFails(
      setDoc(doc(db, likeDoc(ALICE)), {
        userId: ALICE,
        postId: POST,
        createdAt: serverTimestamp(),
      })
    );
  });

  it("still accepts a like that sends counted: false, which every current client does", async () => {
    // The other side of the change: requiring the field must not break the
    // shipped client. src/services/posts.ts:309 writes counted: false
    // unconditionally, so this is what a real like looks like today.
    const db = plainUser(env, ALICE).firestore();
    await assertSucceeds(
      setDoc(doc(db, likeDoc(ALICE)), {
        userId: ALICE,
        postId: POST,
        createdAt: serverTimestamp(),
        counted: false,
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

describe("an account whose deletion cascade has already finished", () => {
  // The mid-cascade state is covered above via DELETING's deletionPending
  // flag. This is the state AFTER the cascade: user doc gone, admin/state
  // gone, tombstone written, Auth record deleted last — and an id token issued
  // before all that, still inside its hour.
  //
  // Rules check a JWT's signature and expiry, not whether the Auth user still
  // exists, so the token keeps authenticating. Without the tombstone check,
  // `!exists(userDoc)` read as "not deleting" and a missing admin/state read
  // as "not banned", so every isNotBanned() && isNotDeleting() gate opened.
  const GHOST = "ghost-user";

  beforeEach(async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      // Exactly what deleteUserAccount leaves behind.
      await setDoc(doc(db, `userDeletionTombstones/${GHOST}`), {
        userId: GHOST,
        reason: "account_deleted",
        createdAt: new Date(),
        expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000),
      });
    });
  });

  it("cannot rebuild its own user document", async () => {
    // completeOnboarding is a setDoc(..., {merge:true}); with the doc deleted
    // that is a create, and onboardingComplete is an allowlisted field. This
    // was the resurrection path — and the rebuilt doc is world-readable.
    const db = plainUser(env, GHOST).firestore();
    await assertFails(
      setDoc(doc(db, "users", GHOST), { onboardingComplete: true }, { merge: true })
    );
  });

  it("cannot like other people's posts", async () => {
    // Each like would fire onLikeCreated and increment likeCount for a uid
    // that no longer exists, with no cleanup pass left to undo it.
    const db = plainUser(env, GHOST).firestore();
    await assertFails(
      setDoc(doc(db, `posts/${POST}/likes/${GHOST}`), {
        userId: GHOST,
        postId: POST,
        createdAt: serverTimestamp(),
        counted: false,
      })
    );
  });

  it("cannot create bookmarks", async () => {
    const db = plainUser(env, GHOST).firestore();
    await assertFails(
      setDoc(doc(db, `users/${GHOST}/bookmarks/${POST}`), {
        createdAt: serverTimestamp(),
      })
    );
  });

  it("cannot block anyone or write settings", async () => {
    const db = plainUser(env, GHOST).firestore();
    await assertFails(
      setDoc(doc(db, `users/${GHOST}/blockedUsers/${ALICE}`), {
        blockedAt: serverTimestamp(),
      })
    );
    await assertFails(
      setDoc(
        doc(db, `users/${GHOST}/settings/preferences`),
        { language: "en" },
        { merge: true }
      )
    );
  });

  it("can still delete its own leftovers, so cleanup paths keep working", async () => {
    // Same reasoning as the banned/mid-deletion cases: delete must stay open
    // or a client tearing itself down strands rows the cascade already missed.
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await setDoc(doc(db, `posts/${POST}/likes/${GHOST}`), {
        userId: GHOST,
        postId: POST,
        createdAt: new Date(),
      });
      await setDoc(doc(db, `users/${GHOST}/bookmarks/${POST}`), {
        createdAt: new Date(),
      });
    });
    const db = plainUser(env, GHOST).firestore();
    await assertSucceeds(deleteDoc(doc(db, `posts/${POST}/likes/${GHOST}`)));
    await assertSucceeds(deleteDoc(doc(db, `users/${GHOST}/bookmarks/${POST}`)));
  });
});

describe("a brand-new signup is not mistaken for a deleted one", () => {
  // The guard against fixing the above by breaking onboarding: a fresh uid has
  // no tombstone AND no user doc, and both must read as "not deleting".
  const FRESH = "fresh-user";

  it("can create its own user document", async () => {
    const db = plainUser(env, FRESH).firestore();
    await assertSucceeds(
      setDoc(doc(db, "users", FRESH), { onboardingComplete: true })
    );
  });

  it("can like a post", async () => {
    const db = plainUser(env, FRESH).firestore();
    await assertSucceeds(
      setDoc(doc(db, `posts/${POST}/likes/${FRESH}`), {
        userId: FRESH,
        postId: POST,
        createdAt: serverTimestamp(),
        counted: false,
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

describe("the likes collection group is scoped to the requesting user", () => {
  // posts/{postId}/likes is world-readable and stays that way — a post's
  // likers are public. The collection group answers a different question:
  // "every like matching a filter, across all posts". Left open, that turned
  // any uid into a complete, queryable like history for an unauthenticated
  // caller. No UI has ever exposed that aggregate.
  beforeEach(async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      for (const uid of [ALICE, BANNED]) {
        await setDoc(doc(db, `posts/${POST}/likes/${uid}`), {
          userId: uid,
          postId: POST,
          createdAt: new Date(),
          counted: true,
        });
      }
    });
  });

  it("still lets anyone read a single post's likes", async () => {
    // The public half. An unauthenticated visitor sees who liked a post.
    const db = env.unauthenticatedContext().firestore();
    await assertSucceeds(getDoc(doc(db, `posts/${POST}/likes/${ALICE}`)));
    await assertSucceeds(getDocs(collection(db, `posts/${POST}/likes`)));
  });

  it("refuses an unauthenticated cross-post query for one person's likes", async () => {
    const db = env.unauthenticatedContext().firestore();
    await assertFails(
      getDocs(
        query(collectionGroup(db, "likes"), where("userId", "==", ALICE))
      )
    );
  });

  it("refuses a signed-in user querying someone else's like history", async () => {
    const db = plainUser(env, BANNED).firestore();
    await assertFails(
      getDocs(
        query(collectionGroup(db, "likes"), where("userId", "==", ALICE))
      )
    );
  });

  it("refuses an unfiltered collection-group scan", async () => {
    const db = plainUser(env, ALICE).firestore();
    await assertFails(getDocs(collectionGroup(db, "likes")));
  });

  it("still serves the batched own-likes query the feed depends on", async () => {
    // useBatchLikeStatus: where(userId == me) + where(postId in [...]).
    // This is the only collection-group likes query in the client, and it
    // must keep working or every feed card loses its like state.
    const db = plainUser(env, ALICE).firestore();
    await assertSucceeds(
      getDocs(
        query(
          collectionGroup(db, "likes"),
          where("userId", "==", ALICE),
          where("postId", "in", [POST])
        )
      )
    );
  });
});
