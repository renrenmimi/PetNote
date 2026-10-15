import { act, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { Post } from "../../services/posts";

const getPosts = vi.fn();
const getFollowingPosts = vi.fn();

vi.mock("../../services/posts", () => ({
  getPosts: (...a: unknown[]) => getPosts(...a),
  getFollowingPosts: (...a: unknown[]) => getFollowingPosts(...a),
}));

/**
 * Re-imported for every test. usePosts keeps the loaded pages in a
 * module-level cache so returning from a post detail does not throw them
 * away — which also means the cache would otherwise carry from one test into
 * the next.
 */
let usePosts: typeof import("../usePosts").usePosts;

const post = (id: string) =>
  ({ id, authorId: "a", likeCount: 0, commentCount: 0 }) as unknown as Post;

function Harness() {
  const { posts, loading, error, refresh } = usePosts("all", null);
  return (
    <div>
      <span data-testid="ids">{posts.map((p) => p.id).join(",")}</span>
      <span data-testid="loading">{loading ? "loading" : "idle"}</span>
      <span data-testid="error">{error ?? "none"}</span>
      <button
        type="button"
        onClick={() => {
          void refresh();
        }}
      >
        refresh
      </button>
    </div>
  );
}

const ids = () => screen.getByTestId("ids").textContent;

describe("usePosts refresh", () => {
  beforeEach(async () => {
    getPosts.mockReset();
    getFollowingPosts.mockReset();
    vi.resetModules();
    ({ usePosts } = await import("../usePosts"));
  });

  async function mountWithFirstPage() {
    getPosts.mockResolvedValueOnce({
      posts: [post("p1"), post("p2")],
      lastDoc: null,
      hasMore: false,
    });
    render(<Harness />);
    await act(async () => {
      await Promise.resolve();
    });
    expect(ids()).toBe("p1,p2");
  }

  it("keeps the loaded pages when the list unmounts and comes back", async () => {
    getPosts.mockResolvedValueOnce({
      posts: [post("p1"), post("p2")],
      lastDoc: null,
      hasMore: false,
    });
    const first = render(<Harness />);
    await act(async () => {
      await Promise.resolve();
    });
    expect(ids()).toBe("p1,p2");
    expect(getPosts).toHaveBeenCalledTimes(1);

    // Opening a post detail and coming back. Without the cache this started
    // again at page one, so somebody four pages deep was returned to the top
    // of a feed that no longer held what they were looking at.
    first.unmount();
    render(<Harness />);
    await act(async () => {
      await Promise.resolve();
    });

    expect(ids()).toBe("p1,p2");
    // And it cost nothing: no second query went out.
    expect(getPosts).toHaveBeenCalledTimes(1);
  });

  it("forgets the cached pages when something is published", async () => {
    /*
     * The cache is right for going into a post and coming back, and wrong for
     * the one case where you have just made something it cannot contain.
     * Publishing navigates to the feed, and the feed showed the pages it had
     * loaded before the composer opened — so the new post was not in it.
     * Verified end to end on the simulator before this was written: the post
     * existed in Firestore and appeared on the pet page, and not in the feed.
     */
    getPosts.mockResolvedValueOnce({
      posts: [post("p1")],
      lastDoc: null,
      hasMore: false,
    });
    const first = render(<Harness />);
    await act(async () => {
      await Promise.resolve();
    });
    expect(getPosts).toHaveBeenCalledTimes(1);

    const { invalidateFeedCache } = await import("../usePosts");
    first.unmount();
    invalidateFeedCache();

    getPosts.mockResolvedValueOnce({
      posts: [post("new"), post("p1")],
      lastDoc: null,
      hasMore: false,
    });
    render(<Harness />);
    await act(async () => {
      await Promise.resolve();
    });

    // It asked again, and the new post is there.
    expect(getPosts).toHaveBeenCalledTimes(2);
    expect(ids()).toBe("new,p1");
  });

  it("keeps the existing posts on screen while refreshing", async () => {
    await mountWithFirstPage();

    let release!: () => void;
    getPosts.mockReturnValueOnce(
      new Promise((resolve) => {
        release = () =>
          resolve({ posts: [post("p3")], lastDoc: null, hasMore: false });
      })
    );

    await act(async () => {
      screen.getByText("refresh").click();
    });

    // The old behaviour set posts to [] here, which flashed the whole feed
    // away to skeletons on every pull.
    expect(ids()).toBe("p1,p2");
    expect(screen.getByTestId("loading").textContent).toBe("idle");

    await act(async () => {
      release();
      await Promise.resolve();
    });
    expect(ids()).toBe("p3");
  });

  it("keeps the existing posts when the refresh fails, and reports it", async () => {
    await mountWithFirstPage();
    getPosts.mockRejectedValueOnce(new Error("offline"));

    await act(async () => {
      screen.getByText("refresh").click();
    });

    expect(ids()).toBe("p1,p2");
    expect(screen.getByTestId("error").textContent).toBe("offline");
  });

  it("resolves false on failure so the caller can offer a retry", async () => {
    getPosts.mockResolvedValueOnce({
      posts: [post("p1")],
      lastDoc: null,
      hasMore: false,
    });

    const outcomes: boolean[] = [];
    function Probe() {
      const { refresh } = usePosts("all", null);
      return (
        <button
          type="button"
          onClick={() => {
            void refresh().then((ok) => outcomes.push(ok));
          }}
        >
          go
        </button>
      );
    }

    render(<Probe />);
    await act(async () => {
      await Promise.resolve();
    });

    getPosts.mockRejectedValueOnce(new Error("nope"));
    await act(async () => {
      screen.getByText("go").click();
    });

    getPosts.mockResolvedValueOnce({
      posts: [post("p9")],
      lastDoc: null,
      hasMore: false,
    });
    await act(async () => {
      screen.getByText("go").click();
    });

    expect(outcomes).toEqual([false, true]);
  });
});
