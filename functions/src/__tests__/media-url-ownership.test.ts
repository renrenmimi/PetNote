import "./setup";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { admin, db } from "../platform";
import { createPostCallable } from "../posts";
import { updatePetCallable } from "../pets";
import { callAs, clearRateLimits, errorCodeOf } from "./helpers";

// A host allowlist proves the bytes are served by Cloudinary. It does not
// prove they are OUR bytes. Anyone can register a free Cloudinary account, and
// https://res.cloudinary.com/<their-cloud>/... passes a hostname check
// unchanged — skipping the whole upload pipeline (size caps, per-user folder,
// signature rate limit) and, worse, keeping the attacker in control of the
// asset, so anything that survives moderation can be swapped afterwards at the
// same URL.
//
// setup.ts sets CLOUDINARY_CLOUD_NAME=test-cloud, so "test-cloud" is ours.

const OWNER = "media-owner";
const PET = "media-pet";

const ours = (p = "petnote/users/media-owner/photo.jpg") =>
  `https://res.cloudinary.com/test-cloud/image/upload/v1700000000/${p}`;
const foreignCloud =
  "https://res.cloudinary.com/attacker-cloud/image/upload/v1700000000/petnote/users/media-owner/photo.jpg";
const ourCloudOutsideFolder =
  "https://res.cloudinary.com/test-cloud/image/upload/v1700000000/somewhere-else/photo.jpg";

async function wipe() {
  for (const c of ["users", "pets", "posts", "callableRateLimits", "notifications"]) {
    const snap = await db.collection(c).get();
    for (const d of snap.docs) await db.recursiveDelete(d.ref).catch(() => undefined);
  }
  const users = await admin.auth().listUsers(1000);
  await Promise.all(
    users.users.map((u) => admin.auth().deleteUser(u.uid).catch(() => undefined))
  );
}

beforeEach(async () => {
  await wipe();
  await clearRateLimits();
  await admin.auth().createUser({
    uid: OWNER,
    email: `${OWNER}@example.com`,
    emailVerified: true,
  });
  await db.doc(`users/${OWNER}`).set({ displayName: OWNER });
  await db.doc(`pets/${PET}`).set({ name: "Rex", ownerId: OWNER, species: "dog" });
});
afterAll(wipe);

const post = (url: string) =>
  callAs<{ id: string }>(createPostCallable, OWNER, {
    text: "hello",
    petId: PET,
    media: [{ url, type: "image" }],
  });

describe("cloudinary media urls must be our own assets", () => {
  it("accepts an asset in our cloud, under our folder", async () => {
    const res = await post(ours());
    const stored = (await db.doc(`posts/${res.id}`).get()).data() ?? {};
    expect(stored.media[0].url).toBe(ours());
  });

  it("refuses an identical path in someone else's cloud", async () => {
    // The whole attack in one line: same host, same folder, different bucket.
    expect(await errorCodeOf(() => post(foreignCloud))).toBe("invalid-argument");
  });

  it("refuses our cloud outside the petnote folder", async () => {
    expect(await errorCodeOf(() => post(ourCloudOutsideFolder))).toBe(
      "invalid-argument"
    );
  });

  it("refuses a foreign cloud in the thumbnail as well as the url", async () => {
    // thumbUrl is validated separately and was just as exploitable.
    expect(
      await errorCodeOf(() =>
        callAs(createPostCallable, OWNER, {
          text: "hello",
          petId: PET,
          media: [{ url: ours(), type: "image", thumbUrl: foreignCloud }],
        })
      )
    ).toBe("invalid-argument");
  });

  it("still refuses a host that was never allowed", async () => {
    expect(
      await errorCodeOf(() => post("https://evil.example.com/x.jpg"))
    ).toBe("invalid-argument");
  });

  it("applies to pet avatars too, not just post media", async () => {
    expect(
      await errorCodeOf(() =>
        callAs(updatePetCallable, OWNER, { petId: PET, avatarUrl: foreignCloud })
      )
    ).toBe("invalid-argument");
    const ok = await callAs(updatePetCallable, OWNER, {
      petId: PET,
      avatarUrl: ours("petnote/users/media-owner/avatar.jpg"),
    });
    expect(ok).toBeTruthy();
  });

  it("leaves the non-Cloudinary avatar hosts alone", async () => {
    // dicebear generates our default avatars and Google serves profile photos
    // from sign-in; neither is ours to fingerprint by path, and breaking them
    // would blank the avatar of every user who has not uploaded one.
    const dicebear = "https://api.dicebear.com/7.x/thumbs/svg?seed=media-owner";
    const ok = await callAs(updatePetCallable, OWNER, {
      petId: PET,
      avatarUrl: dicebear,
    });
    expect(ok).toBeTruthy();
    expect((await db.doc(`pets/${PET}`).get()).data()?.avatarUrl).toBe(dicebear);
  });
});
