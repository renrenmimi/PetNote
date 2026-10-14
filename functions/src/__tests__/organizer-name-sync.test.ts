import "./setup";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { db } from "../platform";
import { onUserUpdated } from "../users";
import { captureSnapshot, deliverWritten, newEventId, purge } from "./helpers";

// A meetup keeps its organizer's name and photo, shown as "Organized by …".
// onUserUpdated copied a new name onto posts, comments, rosters and the rest,
// but not onto the meetups the person organizes, which kept the old name until
// the meetup itself was edited.

const ORGANIZER = "rename-organizer";
const SOMEONE_ELSE = "rename-someone-else";
const USER = `users/${ORGANIZER}`;
const THEIRS = "meetups/rename-theirs";
const NOT_THEIRS = "meetups/rename-not-theirs";
const POST = "posts/rename-post";
const OLD_PHOTO = "https://res.cloudinary.com/demo/image/upload/old.jpg";
const NEW_PHOTO = "https://res.cloudinary.com/demo/image/upload/new.jpg";

async function wipe() {
  await purge(USER, THEIRS, NOT_THEIRS, POST);
}

beforeEach(async () => {
  await wipe();
  await db.doc(USER).set({ displayName: "Old Name", avatarUrl: OLD_PHOTO });
  await db.doc(THEIRS).set({ organizerId: ORGANIZER, organizerName: "Old Name", organizerAvatar: OLD_PHOTO, title: "Theirs", status: "upcoming" });
  await db.doc(NOT_THEIRS).set({ organizerId: SOMEONE_ELSE, organizerName: "Someone Else", organizerAvatar: OLD_PHOTO, title: "Not theirs", status: "upcoming" });
  await db.doc(POST).set({ authorId: ORGANIZER, authorName: "Old Name", authorAvatar: OLD_PHOTO, text: "a post" });
});
afterAll(wipe);

describe("a renamed organizer", () => {
  it("is named, with the new photo, on the meetups they organize", async () => {
    const before = await captureSnapshot(USER);
    await db.doc(USER).update({ displayName: "New Name", avatarUrl: NEW_PHOTO });
    const after = await captureSnapshot(USER);

    await deliverWritten(onUserUpdated, before, after, { userId: ORGANIZER }, newEventId("user"));

    const theirs = (await db.doc(THEIRS).get()).data();
    expect([theirs?.organizerName, theirs?.organizerAvatar]).toEqual(["New Name", NEW_PHOTO]);
    const post = (await db.doc(POST).get()).data();
    expect([post?.authorName, post?.authorAvatar]).toEqual(["New Name", NEW_PHOTO]);
    const notTheirs = (await db.doc(NOT_THEIRS).get()).data();
    expect(notTheirs?.organizerName, "someone else's meetup changed").toBe("Someone Else");
  });
});
