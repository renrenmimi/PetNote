import "./setup";
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { db } from "../platform";
import { cascadeDeletePost } from "../cleanup";
import { createCommentCallable } from "../posts";
import { callAs, clearRateLimits, errorCodeOf, purge, serverTime } from "./helpers";

// Two hundred people liking and commenting on a post as its author deleted it
// left 47 likes and 6 comments under the deleted post on the test project:
// some landed while its likes and comments were being swept, before the post
// document itself went, and a comment could be written after it went.

const POST_ID = "deleted-while-busy";
const POST = `posts/${POST_ID}`;

type Method = (...args: unknown[]) => Promise<unknown>;
const refProto = () => Object.getPrototypeOf(db.doc(POST)) as Record<"set" | "delete", Method>;

beforeEach(async () => {
  await purge(POST, "users/commenter");
  await clearRateLimits();
  await db.doc("users/commenter").set({ displayName: "commenter" });
  await db.doc(POST).set({ authorId: "author", text: "post", likeCount: 0, commentCount: 0 });
});
afterEach(() => vi.restoreAllMocks());
afterAll(async () => {
  await purge(POST, "users/commenter");
  await clearRateLimits();
});

describe("a post deleted while people like and comment on it", () => {
  it("leaves no like or comment that landed while its likes and comments were swept", async () => {
    await db.doc(`${POST}/likes/early`).set({ userId: "early", postId: POST_ID, createdAt: serverTime(), counted: false });
    // Just before the post document itself goes, its likes and comments swept
    // already, one more like and one more comment land.
    const proto = refProto();
    const realDelete = proto.delete;
    let landed = false;
    vi.spyOn(proto, "delete").mockImplementation(async function (this: { path: string }, ...args: unknown[]) {
      if (this.path === POST && !landed) {
        landed = true;
        await db.doc(`${POST}/likes/late`).set({ userId: "late", postId: POST_ID, createdAt: serverTime(), counted: false });
        await db.doc(`${POST}/comments/late`).set({ authorId: "late", text: "late", createdAt: serverTime(), counted: false });
      }
      return realDelete.apply(this, args);
    });

    await cascadeDeletePost(POST_ID);

    expect(landed).toBe(true);
    expect((await db.doc(POST).get()).exists).toBe(false);
    expect((await db.collection(`${POST}/likes`).get()).size, "a like stayed under the deleted post").toBe(0);
    expect((await db.collection(`${POST}/comments`).get()).size, "a comment stayed under the deleted post").toBe(0);
  });

  it("takes back a comment written as its post went", async () => {
    // As soon as the comment is written, the post goes, its comments swept.
    const proto = refProto();
    const realSet = proto.set;
    vi.spyOn(proto, "set").mockImplementation(async function (this: { path: string }, ...args: unknown[]) {
      const written = await realSet.apply(this, args);
      if (this.path.startsWith(`${POST}/comments/`)) await db.doc(POST).delete();
      return written;
    });

    const code = await errorCodeOf(() => callAs(createCommentCallable, "commenter", { postId: POST_ID, text: "just in time" }));

    expect(code).toBe("not-found");
    expect((await db.collection(`${POST}/comments`).get()).size, "the comment stayed under the deleted post").toBe(0);
  });
});
