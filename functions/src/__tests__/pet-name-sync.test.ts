import "./setup";
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { db } from "../platform";
import { onPetUpdated } from "../pets";
import { captureSnapshot, deliverWritten, newEventId, purge } from "./helpers";

// A pet's name and photo are copied onto its posts, its followers' follow
// lists, meetup rosters and check-ins, and the apps show those copies. A pet
// renamed or given a new photo went on showing the old ones everywhere but its
// own page. onPetUpdated now writes the pet's current name and photo onto
// every copy.

const PET_ID = "sync-pet";
const PET = `pets/${PET_ID}`;
const OWNER = "sync-owner";
const FOLLOWER = "sync-follower";
const POST = "posts/sync-post";
const OTHER_POST = "posts/sync-other-post";
const FOLLOW = `users/${FOLLOWER}/followingPets/${PET_ID}`;
const ENTRY = `meetups/sync-meetup/participants/${OWNER}`;
const CHECKIN = `locations/sync-place/checkins/${OWNER}_2026-10-14`;
const OLD_PHOTO = "https://res.cloudinary.com/demo/image/upload/old.jpg";
const NEW_PHOTO = "https://res.cloudinary.com/demo/image/upload/new.jpg";

type Method = (...args: unknown[]) => Promise<unknown>;
const refProto = () => Object.getPrototypeOf(db.doc(PET)) as Record<"update", Method>;

async function wipe() {
  await purge(PET, POST, OTHER_POST, `users/${FOLLOWER}`, "meetups/sync-meetup", "locations/sync-place");
}

async function seed() {
  await db.doc(PET).set({ name: "Mochi", avatarUrl: OLD_PHOTO, ownerId: OWNER, primaryOwnerId: OWNER, followerCount: 1, postCount: 1 });
  await db.doc(`${PET}/family/${OWNER}`).set({ userId: OWNER, role: "primary" });
  await db.doc(POST).set({ authorId: OWNER, petId: PET_ID, petName: "Mochi", petAvatarUrl: OLD_PHOTO, text: "a post" });
  await db.doc(OTHER_POST).set({ authorId: OWNER, petId: "another-pet", petName: "Other", petAvatarUrl: OLD_PHOTO, text: "another" });
  await db.doc(FOLLOW).set({ petId: PET_ID, petName: "Mochi", petAvatar: OLD_PHOTO, counted: true });
  await db.doc(ENTRY).set({ meetupId: "sync-meetup", userId: OWNER, petId: PET_ID, petName: "Mochi", petAvatar: OLD_PHOTO });
  await db.doc(CHECKIN).set({ userId: OWNER, petId: PET_ID, petName: "Mochi" });
}

/** Changes the pet, then delivers that change's event the way Firestore would. */
async function change(fields: Record<string, unknown>) {
  const before = await captureSnapshot(PET);
  await db.doc(PET).update(fields);
  const after = await captureSnapshot(PET);
  await deliverWritten(onPetUpdated, before, after, { petId: PET_ID }, newEventId("pet"));
}

async function copies() {
  const [post, follow, entry, checkin, other] = await Promise.all(
    [POST, FOLLOW, ENTRY, CHECKIN, OTHER_POST].map(async (path) => (await db.doc(path).get()).data())
  );
  return { post, follow, entry, checkin, other };
}

beforeEach(async () => {
  await wipe();
  await seed();
});
afterEach(() => vi.restoreAllMocks());
afterAll(wipe);

describe("a pet's name and photo, wherever they are copied", () => {
  it("are the new ones on its posts, follow lists, meetup rosters and check-ins", async () => {
    await change({ name: "Mochi Jr", avatarUrl: NEW_PHOTO });

    const c = await copies();
    expect([c.post?.petName, c.post?.petAvatarUrl]).toEqual(["Mochi Jr", NEW_PHOTO]);
    expect([c.follow?.petName, c.follow?.petAvatar]).toEqual(["Mochi Jr", NEW_PHOTO]);
    expect([c.entry?.petName, c.entry?.petAvatar]).toEqual(["Mochi Jr", NEW_PHOTO]);
    expect(c.checkin?.petName).toBe("Mochi Jr");
    expect([c.other?.petName, c.other?.petAvatarUrl], "another pet's post changed").toEqual(["Other", OLD_PHOTO]);
  });

  it("are not written when only the pet's counts change", async () => {
    const before = await captureSnapshot(PET);
    await db.doc(PET).update({ followerCount: 2 });
    const after = await captureSnapshot(PET);
    const update = vi.spyOn(refProto(), "update");

    await deliverWritten(onPetUpdated, before, after, { petId: PET_ID }, newEventId("pet"));

    expect(update).not.toHaveBeenCalled();
  });

  it("end with the latest name when an earlier change is copied last", async () => {
    const first = await captureSnapshot(PET);
    await db.doc(PET).update({ name: "Mochi Jr" });
    const second = await captureSnapshot(PET);
    await db.doc(PET).update({ name: "Mochi the Third" });
    const third = await captureSnapshot(PET);

    await deliverWritten(onPetUpdated, second, third, { petId: PET_ID }, newEventId("pet"));
    await deliverWritten(onPetUpdated, first, second, { petId: PET_ID }, newEventId("pet"));

    const c = await copies();
    expect([c.post?.petName, c.follow?.petName, c.entry?.petName, c.checkin?.petName]).toEqual(Array(4).fill("Mochi the Third"));
  });

  it("end with the latest name when the pet is renamed again while they are written", async () => {
    // As soon as the first copy is written, the pet is renamed once more, and
    // that rename's own event is never delivered here: the sync has to notice.
    const proto = refProto();
    const realUpdate = proto.update;
    let renamed = false;
    vi.spyOn(proto, "update").mockImplementation(async function (this: { path: string }, ...args: unknown[]) {
      if (!renamed && this.path !== PET) {
        renamed = true;
        await realUpdate.call(db.doc(PET), { name: "Mochi the Third" });
      }
      return realUpdate.apply(this, args);
    });

    await change({ name: "Mochi Jr" });

    expect(renamed).toBe(true);
    const c = await copies();
    expect([c.post?.petName, c.follow?.petName, c.entry?.petName, c.checkin?.petName]).toEqual(Array(4).fill("Mochi the Third"));
  });

  it("leave out a follow undone while they are written, and write the rest", async () => {
    // The follower unfollows just as their copy is about to be written.
    const proto = refProto();
    const realUpdate = proto.update;
    vi.spyOn(proto, "update").mockImplementation(async function (this: { path: string }, ...args: unknown[]) {
      if (this.path === FOLLOW) await db.doc(FOLLOW).delete();
      return realUpdate.apply(this, args);
    });

    await change({ name: "Mochi Jr" });

    expect((await db.doc(FOLLOW).get()).exists, "the undone follow was written back").toBe(false);
    const c = await copies();
    expect([c.post?.petName, c.entry?.petName, c.checkin?.petName]).toEqual(Array(3).fill("Mochi Jr"));
  });
});
