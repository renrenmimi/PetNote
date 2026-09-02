import "./setup";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import { ensureUserProfileCallable, deleteUserAccount } from "../users";
import { createPostCallable, createCommentCallable } from "../posts";
import { createPetCallable } from "../pets";
import { checkInCallable } from "../places";
import { createMeetupCallable } from "../meetups";
import { getCloudinaryUploadSignature } from "../media";
import { callAs, clearRateLimits, errorCodeOf } from "./helpers";
import { createHash } from "node:crypto";

// These drive the real callable handlers against the Firestore and Auth
// emulators. They cover the gates that live in the callable layer rather than
// in firestore.rules: email verification, ban enforcement, the deletion
// tombstone, and Cloudinary signing. tests/rules covers the rules layer.

const ALICE = "flow-alice";
const BANNED = "flow-banned";

// ensureUserProfileCallable reads the Auth record to seed displayName and
// email, so the Auth emulator has to know about the user before it is called.
async function seedAuthUser(uid: string, emailVerified = true) {
  await admin.auth().createUser({
    uid,
    email: `${uid}@example.com`,
    emailVerified,
    displayName: uid,
  });
}

async function seedUser(uid: string, extra: Record<string, unknown> = {}) {
  await db.doc(`users/${uid}`).set({
    displayName: uid,
    email: `${uid}@example.com`,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    ...extra,
  });
}

async function newPet(uid: string): Promise<string> {
  const pet = await callAs<{ id?: string; petId?: string }>(createPetCallable, uid, {
    name: "Flowdog",
    species: "dog",
    gender: "male",
  });
  return (pet.id ?? pet.petId) as string;
}

async function wipe() {
  for (const c of [
    "users", "posts", "pets", "meetups", "locations",
    "callableRateLimits", "userDeletionTombstones", "processedEvents",
    "notifications", "usernames", "hashtags",
  ]) {
    const snap = await db.collection(c).get();
    for (const d of snap.docs) await db.recursiveDelete(d.ref).catch(() => undefined);
  }
  const users = await admin.auth().listUsers(1000);
  await Promise.all(users.users.map((u) => admin.auth().deleteUser(u.uid).catch(() => undefined)));
}

beforeEach(async () => {
  await wipe();
  await clearRateLimits();
});
afterAll(wipe);

describe("signup and email verification", () => {
  beforeEach(async () => {
    await seedAuthUser(ALICE);
  });

  it("creates the user document on first ensureUserProfile call", async () => {
    await callAs(ensureUserProfileCallable, ALICE, {});
    const snap = await db.doc(`users/${ALICE}`).get();
    expect(snap.exists).toBe(true);
  });

  it("is safe to call twice", async () => {
    await callAs(ensureUserProfileCallable, ALICE, {});
    const first = (await db.doc(`users/${ALICE}`).get()).data();
    await callAs(ensureUserProfileCallable, ALICE, {});
    const second = (await db.doc(`users/${ALICE}`).get()).data();
    expect(second?.displayName).toBe(first?.displayName);
  });

  it("refuses an unauthenticated caller", async () => {
    expect(await errorCodeOf(() => callAs(ensureUserProfileCallable, null, {}))).toContain(
      "unauthenticated"
    );
  });

  it("refuses posting until the email is verified", async () => {
    await callAs(ensureUserProfileCallable, ALICE, {});
    const petId = await newPet(ALICE);
    const code = await errorCodeOf(() =>
      callAs(createPostCallable, ALICE, { text: "hi", petId }, { emailVerified: false })
    );
    expect(code).toContain("permission-denied");
  });

  it("refuses checking in until the email is verified", async () => {
    await callAs(ensureUserProfileCallable, ALICE, {});
    const code = await errorCodeOf(() =>
      callAs(checkInCallable, ALICE, { locationId: "somewhere" }, { emailVerified: false })
    );
    expect(code).toContain("permission-denied");
  });

  it("refuses creating a meetup until the email is verified", async () => {
    await callAs(ensureUserProfileCallable, ALICE, {});
    const code = await errorCodeOf(() =>
      callAs(createMeetupCallable, ALICE, { title: "Park day" }, { emailVerified: false })
    );
    expect(code).toContain("permission-denied");
  });

  it("allows posting once the email is verified", async () => {
    await callAs(ensureUserProfileCallable, ALICE, {});
    const petId = await newPet(ALICE);
    const post = await callAs<{ id?: string }>(createPostCallable, ALICE, {
      text: "verified post",
      petId,
    });
    expect(post.id).toBeTruthy();
  });
});

describe("ban enforcement in the callable layer", () => {
  // Posts, comments, pets and meetups are callable-only, so firestore.rules
  // never sees these writes. The ban has to be enforced here or not at all.
  //
  // The banned user owns their own pet, seeded directly, because a pet they do
  // not own is refused by the ownership check instead — which would make these
  // tests pass whether the ban is enforced or not. Confirmed by deleting the
  // ban check and watching them stay green until this was fixed.
  let bannedPetId: string;

  beforeEach(async () => {
    await seedUser(BANNED);
    await seedUser(ALICE);
    const petRef = db.collection("pets").doc();
    bannedPetId = petRef.id;
    await petRef.set({
      name: "Bannedog",
      species: "dog",
      ownerId: BANNED,
      primaryOwnerId: BANNED,
      followerCount: 0,
      postCount: 0,
    });
    await db.doc(`pets/${bannedPetId}/family/${BANNED}`).set({
      userId: BANNED,
      relationship: "dad",
    });
    await db.doc(`users/${BANNED}/admin/state`).set({ banned: true });
  });

  it("refuses a banned user creating a post on their own pet", async () => {
    const code = await errorCodeOf(() =>
      callAs(createPostCallable, BANNED, { text: "spam", petId: bannedPetId })
    );
    expect(code).toContain("permission-denied");
  });

  it("lets an unbanned owner post on that same pet", async () => {
    // The control: proves the refusal above is the ban and not the pet.
    await db.doc(`users/${BANNED}/admin/state`).delete();
    const post = await callAs<{ id?: string }>(createPostCallable, BANNED, {
      text: "fine now",
      petId: bannedPetId,
    });
    expect(post.id).toBeTruthy();
  });

  it("refuses a banned user creating a pet", async () => {
    expect(
      await errorCodeOf(() =>
        callAs(createPetCallable, BANNED, { name: "Spam", species: "dog" })
      )
    ).toContain("permission-denied");
  });

  it("refuses a banned user commenting", async () => {
    const petId = await newPet(ALICE);
    const post = await callAs<{ id: string }>(createPostCallable, ALICE, {
      text: "hello",
      petId,
    });
    expect(
      await errorCodeOf(() =>
        callAs(createCommentCallable, BANNED, { postId: post.id, text: "spam" })
      )
    ).toContain("permission-denied");
  });

  it("refuses a banned user requesting an upload signature", async () => {
    expect(
      await errorCodeOf(() =>
        callAs(getCloudinaryUploadSignature, BANNED, { resourceType: "image" })
      )
    ).toContain("permission-denied");
  });

  it("refuses a banned user creating a meetup", async () => {
    expect(
      await errorCodeOf(() => callAs(createMeetupCallable, BANNED, { title: "Spam meetup" }))
    ).toContain("permission-denied");
  });
});

describe("account deletion", () => {
  it("refuses to delete anyone else's account", async () => {
    await seedUser(ALICE);
    await seedUser(BANNED);
    expect(
      await errorCodeOf(() => callAs(deleteUserAccount, ALICE, { userId: BANNED }))
    ).toContain("permission-denied");
  });

  it("refuses a call with no userId", async () => {
    await seedUser(ALICE);
    expect(await errorCodeOf(() => callAs(deleteUserAccount, ALICE, {}))).toContain(
      "invalid-argument"
    );
  });

  it("removes the user, their pets and posts, and leaves a tombstone", async () => {
    await seedAuthUser(ALICE);
    await callAs(ensureUserProfileCallable, ALICE, {});
    const petId = await newPet(ALICE);
    const post = await callAs<{ id: string }>(createPostCallable, ALICE, {
      text: "goodbye",
      petId,
    });

    await callAs(deleteUserAccount, ALICE, { userId: ALICE });

    expect((await db.doc(`users/${ALICE}`).get()).exists).toBe(false);
    expect((await db.doc(`pets/${petId}`).get()).exists).toBe(false);
    expect((await db.doc(`posts/${post.id}`).get()).exists).toBe(false);
    expect((await db.doc(`userDeletionTombstones/${ALICE}`).get()).exists).toBe(true);
    await expect(admin.auth().getUser(ALICE)).rejects.toThrow();
  });

  it("refuses to rebuild a deleted account from a stale client", async () => {
    // The tombstone is what stops a not-yet-expired token resurrecting the
    // profile after the cascade has run.
    await seedAuthUser(ALICE);
    await callAs(ensureUserProfileCallable, ALICE, {});
    await callAs(deleteUserAccount, ALICE, { userId: ALICE });

    const code = await errorCodeOf(() => callAs(ensureUserProfileCallable, ALICE, {}));
    expect(code).toContain("failed-precondition");
    expect((await db.doc(`users/${ALICE}`).get()).exists).toBe(false);
  });

  it("blocks writes from an account that is mid-deletion", async () => {
    // assertActorNotDeleting is applied at 36 call sites so a concurrent write
    // cannot race the cascade. This pins one of them.
    await seedUser(ALICE, { deletionPending: true });
    expect(
      await errorCodeOf(() => callAs(createPetCallable, ALICE, { name: "Race", species: "dog" }))
    ).toContain("failed-precondition");
  });
});

describe("cloudinary upload signature", () => {
  beforeEach(async () => {
    await seedUser(ALICE);
  });

  it("refuses an unauthenticated caller", async () => {
    expect(
      await errorCodeOf(() => callAs(getCloudinaryUploadSignature, null, { resourceType: "image" }))
    ).toContain("unauthenticated");
  });

  it("refuses a resourceType it does not recognise", async () => {
    for (const resourceType of ["raw", "", undefined, "IMAGE"]) {
      expect(
        await errorCodeOf(() => callAs(getCloudinaryUploadSignature, ALICE, { resourceType }))
      ).toContain("invalid-argument");
    }
  });

  it("scopes the upload folder to the caller", async () => {
    // Every asset lands under petnote/users/{uid}/ so the delete callable can
    // verify ownership from the public_id prefix without trusting a
    // client-supplied owner field. A caller must not be able to influence this.
    const res = await callAs<{ folder: string }>(getCloudinaryUploadSignature, ALICE, {
      resourceType: "image",
      folder: "petnote/users/someone-else",
    });
    expect(res.folder).toBe(`petnote/users/${ALICE}`);
  });

  it("signs exactly the parameters it returns", async () => {
    // Recomputed independently here. If the handler ever signs a different set
    // of params than it hands back, Cloudinary rejects every upload.
    const res = await callAs<{
      signature: string; timestamp: number; uploadPreset: string;
      folder: string; maxFileSize: number; cloudName: string; apiKey: string;
    }>(getCloudinaryUploadSignature, ALICE, { resourceType: "image" });

    const toSign = [
      `folder=${res.folder}`,
      `max_file_size=${res.maxFileSize}`,
      `timestamp=${res.timestamp}`,
      `upload_preset=${res.uploadPreset}`,
    ].join("&");
    const expected = createHash("sha1")
      .update(`${toSign}${process.env.CLOUDINARY_API_SECRET}`)
      .digest("hex");

    expect(res.signature).toBe(expected);
    expect(res.cloudName).toBe(process.env.CLOUDINARY_CLOUD_NAME);
    expect(res.apiKey).toBe(process.env.CLOUDINARY_API_KEY);
  });

  it("binds the size limit into the signature, per resource type", async () => {
    // The limit is signed so a leaked signature cannot be replayed to upload
    // something larger than allowed.
    const image = await callAs<{ maxFileSize: number; uploadPreset: string }>(
      getCloudinaryUploadSignature, ALICE, { resourceType: "image" }
    );
    const video = await callAs<{ maxFileSize: number; uploadPreset: string }>(
      getCloudinaryUploadSignature, ALICE, { resourceType: "video" }
    );

    expect(image.maxFileSize).toBe(10 * 1024 * 1024);
    expect(video.maxFileSize).toBe(80 * 1024 * 1024);
    expect(image.uploadPreset).toBe("petnote_image_signed");
    expect(video.uploadPreset).toBe("petnote_video_signed");
  });

  it("never returns the api secret", async () => {
    const res = await callAs<Record<string, unknown>>(getCloudinaryUploadSignature, ALICE, {
      resourceType: "image",
    });
    expect(JSON.stringify(res)).not.toContain(process.env.CLOUDINARY_API_SECRET);
  });
});
