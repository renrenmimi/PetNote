import "./setup";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import { createPostCallable, getPublishStatusCallable } from "../posts";
import { callAs, clearRateLimits, errorCodeOf } from "./helpers";

/**
 * Publishing the same submission twice.
 *
 * `createPostCallable` used `collection.add()`, which mints a fresh random id
 * per call. A successful publish whose *response* was lost — a dropped
 * connection, a suspended tab — looked like a failure to the client, and the
 * retry created a second post. The client's catch also deleted the uploaded
 * media, so the first post survived pointing at assets that no longer existed.
 *
 * The post's document id is now derived from (caller, operationId), so the
 * write itself is the idempotency record: a retry with the same operation id
 * gets back the post the first attempt made.
 */

const AUTHOR = "pub-author";
const OTHER = "pub-other";
const PET = "pub-pet";

async function seedUser(uid: string) {
  await db.doc(`users/${uid}`).set({
    displayName: uid,
    email: `${uid}@example.com`,
  });
}

async function wipe() {
  for (const c of ["users", "pets", "posts", "callableRateLimits", "hashtags"]) {
    const snap = await db.collection(c).get();
    for (const d of snap.docs) await db.recursiveDelete(d.ref).catch(() => undefined);
  }
}

beforeEach(async () => {
  await wipe();
  await clearRateLimits();
  await seedUser(AUTHOR);
  await seedUser(OTHER);
  await db.doc(`pets/${PET}`).set({
    name: "Mochi",
    ownerId: AUTHOR,
    primaryOwnerId: AUTHOR,
    postCount: 0,
  });
  await db.doc(`pets/${PET}/family/${AUTHOR}`).set({
    userId: AUTHOR,
    role: "primary",
    joinedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
});
afterAll(wipe);

const publish = (uid: string, operationId?: string, text = "hello") =>
  callAs<{ id: string; deduplicated: boolean }>(createPostCallable, uid, {
    petId: PET,
    text,
    ...(operationId ? { operationId } : {}),
  });

describe("retrying the same submission", () => {
  it("returns the first post instead of publishing a second", async () => {
    const first = await publish(AUTHOR, "op-lost-response-1");
    const retry = await publish(AUTHOR, "op-lost-response-1");

    expect(retry.id).toBe(first.id);
    expect(first.deduplicated).toBe(false);
    expect(retry.deduplicated).toBe(true);
    expect((await db.collection("posts").get()).size).toBe(1);
  });

  it("keeps the first attempt's content, not the retry's", async () => {
    // The retry is the *same* submission, so the first commit stands. Silently
    // rewriting it would be worse: a retry is not an edit.
    const first = await publish(AUTHOR, "op-same-1", "original");
    await publish(AUTHOR, "op-same-1", "changed on retry");

    const post = await db.doc(`posts/${first.id}`).get();
    expect(post.data()?.text).toBe("original");
  });

  it("publishes separately for a different operation id", async () => {
    const a = await publish(AUTHOR, "op-distinct-a");
    const b = await publish(AUTHOR, "op-distinct-b");

    expect(b.id).not.toBe(a.id);
    expect((await db.collection("posts").get()).size).toBe(2);
  });

  it("does not let two people collide on the same operation id", async () => {
    // The id is derived from the caller's uid too, so one person's operation
    // id cannot squat on another's or hand them somebody else's post.
    await db.doc(`pets/${PET}/family/${OTHER}`).set({
      userId: OTHER,
      role: "member",
      joinedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const mine = await publish(AUTHOR, "op-shared-id");
    const theirs = await publish(OTHER, "op-shared-id");

    expect(theirs.id).not.toBe(mine.id);
    expect(theirs.deduplicated).toBe(false);
    const theirPost = await db.doc(`posts/${theirs.id}`).get();
    expect(theirPost.data()?.authorId).toBe(OTHER);
  });
});

describe("clients without an operation id", () => {
  it("still publishes, so a tab loaded before this shipped keeps working", async () => {
    const first = await publish(AUTHOR);
    const second = await publish(AUTHOR);

    expect(first.deduplicated).toBe(false);
    expect(second.id).not.toBe(first.id);
    expect((await db.collection("posts").get()).size).toBe(2);
  });
});

describe("operation id validation", () => {
  it("refuses one that is too short to be unique", async () => {
    expect(await errorCodeOf(() => publish(AUTHOR, "short"))).toBe(
      "invalid-argument"
    );
  });

  it("refuses characters that are not safe in a document id", async () => {
    expect(await errorCodeOf(() => publish(AUTHOR, "op/with/slashes"))).toBe(
      "invalid-argument"
    );
  });

  it("refuses a non-string", async () => {
    const code = await errorCodeOf(() =>
      callAs(createPostCallable, AUTHOR, {
        petId: PET,
        text: "hi",
        operationId: 12345678,
      })
    );
    expect(code).toBe("invalid-argument");
  });
});

describe("asking whether an operation published", () => {
  /**
   * Informational only: it tells somebody "your earlier post did go through".
   * It is deliberately *not* what decides whether media may be deleted — a
   * publish paused before its write answers `published: false` and then
   * commits, so a false answer cannot license a deletion. That reasoning lives
   * in src/utils/mediaReclaim.ts and its tests.
   */
  it("reports a published operation and its post", async () => {
    const published = await publish(AUTHOR, "op-status-published");

    const status = await callAs<{ published: boolean; postId?: string }>(
      getPublishStatusCallable,
      AUTHOR,
      { operationId: "op-status-published" }
    );

    expect(status.published).toBe(true);
    expect(status.postId).toBe(published.id);
  });

  it("reports an operation that never published", async () => {
    const status = await callAs<{ published: boolean }>(
      getPublishStatusCallable,
      AUTHOR,
      { operationId: "op-status-never-ran" }
    );

    expect(status.published).toBe(false);
  });

  it("does not report another person's post for the same operation id", async () => {
    // The document id is derived from the caller's own uid, so this cannot be
    // used to probe somebody else's publishing. Checked explicitly because it
    // would otherwise be an oracle.
    await publish(AUTHOR, "op-status-shared");

    const status = await callAs<{ published: boolean; postId?: string }>(
      getPublishStatusCallable,
      OTHER,
      { operationId: "op-status-shared" }
    );

    expect(status.published).toBe(false);
    expect(status.postId).toBeUndefined();
  });

  it("refuses a missing or malformed operation id", async () => {
    expect(
      await errorCodeOf(() => callAs(getPublishStatusCallable, AUTHOR, {}))
    ).toBe("invalid-argument");
    expect(
      await errorCodeOf(() =>
        callAs(getPublishStatusCallable, AUTHOR, { operationId: "op/slash" })
      )
    ).toBe("invalid-argument");
  });
});
