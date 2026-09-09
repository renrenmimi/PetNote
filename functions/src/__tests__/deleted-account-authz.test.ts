import "./setup";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import { createPetCallable } from "../pets";
import { createCommentCallable, createPostCallable } from "../posts";
import { createMeetupCallable } from "../meetups";
import { submitReviewCallable } from "../places";
import { ensureUserProfileCallable } from "../users";
import { reportContentCallable } from "../moderation";
import { callAs, clearRateLimits, errorCodeOf } from "./helpers";

/**
 * What happens to a deleted account's remaining credentials.
 *
 * The account-deletion cascade deletes users/{uid} on its way out and deletes
 * the Auth user last (so a failure is retryable). Between those two steps —
 * and for up to an hour afterwards, because an ID token that has already been
 * minted stays valid until it expires and Firestore rules do not check whether
 * the Auth user still exists — the uid is a signed-in caller with no profile.
 *
 * The old guard read `deletionPending` off users/{uid}, so once that document
 * was gone it read as undefined and every mutating callable let the deleted
 * account back in. userDeletionTombstones/{uid} is the record that survives,
 * and assertCallerAccountActive is what consults it.
 *
 * NOTE ON SCOPE: these drive the exported handlers through `.run()` with a
 * fabricated auth context. That is a handler-level result. Whether the
 * Firebase callable transport keeps accepting a JWT minted before deletion is
 * a separate question about Google's token verification, and it is not tested
 * here — no real ID tokens are minted anywhere in this suite.
 */

const GHOST = "del-ghost";
const LIVE = "del-live";

async function seedUser(uid: string) {
  await db.doc(`users/${uid}`).set({
    displayName: uid,
    email: `${uid}@example.com`,
  });
}

/**
 * ensureUserProfileCallable mirrors the chosen name onto the Auth user record,
 * so the first-signup case needs a real Auth-emulator user to exist. Without
 * one the callable fails with auth/user-not-found long after the guard this
 * file is about has already let it through.
 */
async function seedAuthUser(uid: string) {
  await admin
    .auth()
    .createUser({ uid, email: `${uid}@example.com`, emailVerified: true })
    .catch(() => undefined);
}

async function deleteAuthUser(uid: string) {
  await admin.auth().deleteUser(uid).catch(() => undefined);
}

/** The state the cascade leaves behind: no profile, tombstone retained. */
async function finishDeletion(uid: string) {
  await db.doc(`users/${uid}`).delete();
  await db.doc(`userDeletionTombstones/${uid}`).set({
    userId: uid,
    reason: "account_deleted",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + 86_400_000),
  });
}

async function wipe() {
  for (const c of [
    "users",
    "pets",
    "posts",
    "locations",
    "meetups",
    "reports",
    "userDeletionTombstones",
    "callableRateLimits",
    "notifications",
    "processedEvents",
    "usernames",
  ]) {
    const snap = await db.collection(c).get();
    for (const d of snap.docs) await db.recursiveDelete(d.ref).catch(() => undefined);
  }
}

beforeEach(async () => {
  await wipe();
  await clearRateLimits();
  await seedUser(GHOST);
  await seedUser(LIVE);
});
afterAll(async () => {
  await wipe();
  await Promise.all([deleteAuthUser(GHOST), deleteAuthUser(LIVE)]);
});

describe("after the deletion cascade has finished", () => {
  it("refuses to create a pet", async () => {
    await finishDeletion(GHOST);

    const code = await errorCodeOf(() =>
      callAs(createPetCallable, GHOST, {
        name: "Ghost",
        species: "dog",
        gender: "male",
      })
    );

    expect(code).toBe("failed-precondition");
    const pets = await db.collection("pets").where("ownerId", "==", GHOST).get();
    expect(pets.empty).toBe(true);
  });

  it("refuses to comment", async () => {
    await db.doc("posts/p1").set({ authorId: LIVE, caption: "hi", commentCount: 0 });
    await finishDeletion(GHOST);

    const code = await errorCodeOf(() =>
      callAs(createCommentCallable, GHOST, { postId: "p1", text: "from beyond" })
    );

    expect(code).toBe("failed-precondition");
    expect((await db.collection("posts/p1/comments").get()).empty).toBe(true);
  });

  it("refuses to post", async () => {
    await finishDeletion(GHOST);

    const code = await errorCodeOf(() =>
      callAs(createPostCallable, GHOST, { caption: "still here" })
    );

    expect(code).toBe("failed-precondition");
  });

  it("refuses to organize a meetup", async () => {
    await finishDeletion(GHOST);

    const code = await errorCodeOf(() =>
      callAs(createMeetupCallable, GHOST, {
        title: "Walk",
        dateMillis: Date.now() + 86_400_000,
        location: {
          name: "Park",
          address: "1 Park Rd",
          lat: 42.35,
          lng: -71.05,
        },
      })
    );

    expect(code).toBe("failed-precondition");
  });

  it("refuses to review a place", async () => {
    await db.doc("locations/loc1").set({ name: "Park", addedBy: LIVE });
    await finishDeletion(GHOST);

    const code = await errorCodeOf(() =>
      callAs(submitReviewCallable, GHOST, { locationId: "loc1", rating: 5 })
    );

    expect(code).toBe("failed-precondition");
  });

  it("refuses to file a report", async () => {
    await db.doc("posts/p1").set({ authorId: LIVE, caption: "hi" });
    await finishDeletion(GHOST);

    const code = await errorCodeOf(() =>
      callAs(reportContentCallable, GHOST, {
        contentType: "post",
        contentId: "p1",
        reason: "spam",
      })
    );

    expect(code).toBe("failed-precondition");
  });

  it("refuses to rebuild the profile the cascade deleted", async () => {
    await finishDeletion(GHOST);

    const code = await errorCodeOf(() =>
      callAs(ensureUserProfileCallable, GHOST, { displayName: "Ghost" })
    );

    expect(code).toBe("failed-precondition");
    expect((await db.doc(`users/${GHOST}`).get()).exists).toBe(false);
  });
});

describe("mid-deletion, before the profile is gone", () => {
  it("still refuses writes while deletionPending is set", async () => {
    await db.doc(`users/${GHOST}`).set({ deletionPending: true }, { merge: true });

    const code = await errorCodeOf(() =>
      callAs(createPetCallable, GHOST, {
        name: "Ghost",
        species: "dog",
        gender: "male",
      })
    );

    expect(code).toBe("failed-precondition");
  });
});

describe("what the tombstone check must not break", () => {
  it("lets a signed-in user with no profile yet create their first one", async () => {
    // The deliberate exception. A brand-new account has no users/{uid}
    // document until this callable writes it, which is exactly why
    // assertCallerAccountActive does not require the profile to exist — only
    // that no tombstone does.
    await db.doc(`users/${LIVE}`).delete();
    await seedAuthUser(LIVE);

    const code = await errorCodeOf(() =>
      callAs(ensureUserProfileCallable, LIVE, { displayName: "Fresh Start" })
    );

    expect(code).toBe(null);
    expect((await db.doc(`users/${LIVE}`).get()).exists).toBe(true);
  });

  it("leaves an ordinary account's writes alone", async () => {
    const code = await errorCodeOf(() =>
      callAs(createPetCallable, LIVE, {
        name: "Mochi",
        species: "cat",
        gender: "female",
      })
    );

    expect(code).toBe(null);
  });
});
