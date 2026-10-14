import "./setup";
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { db } from "../platform";
import { onCommentCreated, onLikeCreated } from "../notifications";
import { clearEventLedger, deliverCreate, newEventId, purge, serverTime } from "./helpers";

// A notification about a post is written a moment after the like or comment
// that caused it. A post deleted in that moment has had its notifications
// swept already (onPostDeleted), so one written after the sweep stayed, about
// a post that is gone. The trigger now looks at the post again once it has
// written, and takes back what it wrote if the post is gone.

const POST_ID = "deleted-while-notifying";
const POST = `posts/${POST_ID}`;
const PEOPLE = ["users/author", "users/liker", "users/commenter"];

async function notificationsAboutThePost(): Promise<number> {
  return (await db.collection("notifications").where("postId", "==", POST_ID).get()).size;
}

async function clearNotifications(): Promise<void> {
  const snap = await db.collection("notifications").where("postId", "==", POST_ID).get();
  await Promise.all(snap.docs.map((d) => d.ref.delete()));
}

/** As soon as a notification has been written, the post goes, its own sweep already done. */
function postGoesOnceNotified(method: "create" | "add") {
  const proto = (method === "create"
    ? Object.getPrototypeOf(db.doc("notifications/probe"))
    : Object.getPrototypeOf(db.collection("notifications"))) as Record<"create" | "add", (...args: unknown[]) => Promise<unknown>>;
  const real = proto[method];
  vi.spyOn(proto, method).mockImplementation(async function (this: { path: string }, ...args: unknown[]) {
    const written = await real.apply(this, args);
    if (this.path.startsWith("notifications")) await db.doc(POST).delete();
    return written;
  });
}

beforeEach(async () => {
  await purge(POST, ...PEOPLE);
  await clearNotifications();
  await clearEventLedger();
  await Promise.all(PEOPLE.map((path) => db.doc(path).set({ displayName: path.split("/")[1] })));
  await db.doc(POST).set({ authorId: "author", text: "post", likeCount: 0, commentCount: 0 });
});
afterEach(() => vi.restoreAllMocks());
afterAll(async () => {
  await purge(POST, ...PEOPLE);
  await clearNotifications();
  await clearEventLedger();
});

describe("notifications about a post deleted while they are written", () => {
  it("keeps a like's notification while the post is there", async () => {
    await db.doc(`${POST}/likes/liker`).set({ userId: "liker", postId: POST_ID, createdAt: serverTime(), counted: false });

    await deliverCreate(onLikeCreated, `${POST}/likes/liker`, { postId: POST_ID, likeId: "liker" }, newEventId("like"));

    expect(await notificationsAboutThePost()).toBe(1);
  });

  it("takes back a like's notification when the post goes as it is written", async () => {
    await db.doc(`${POST}/likes/liker`).set({ userId: "liker", postId: POST_ID, createdAt: serverTime(), counted: false });
    postGoesOnceNotified("create");

    await deliverCreate(onLikeCreated, `${POST}/likes/liker`, { postId: POST_ID, likeId: "liker" }, newEventId("like"));

    expect(await notificationsAboutThePost(), "a notification about the deleted post stayed").toBe(0);
  });

  it("takes back a comment's notification when the post goes as it is written", async () => {
    await db.doc(`${POST}/comments/c1`).set({ authorId: "commenter", text: "hi", createdAt: serverTime(), counted: false });
    postGoesOnceNotified("add");

    await deliverCreate(onCommentCreated, `${POST}/comments/c1`, { postId: POST_ID, commentId: "c1" }, newEventId("comment"));

    expect(await notificationsAboutThePost(), "a notification about the deleted post stayed").toBe(0);
  });
});
