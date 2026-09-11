import { useState } from "react";
import { act, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { LikeMutationResult } from "../../services/posts";

const likePost = vi.fn<(postId: string, userId: string) => Promise<LikeMutationResult>>();
const unlikePost = vi.fn<(postId: string, userId: string) => Promise<LikeMutationResult>>();
const checkIfLiked = vi.fn<(postId: string, userId: string) => Promise<boolean>>();

// services/posts pulls in services/firebase, which throws without the Vite
// env vars. Only the three functions the hook calls are needed here.
vi.mock("../../services/posts", () => ({
  likePost: (...args: [string, string]) => likePost(...args),
  unlikePost: (...args: [string, string]) => unlikePost(...args),
  checkIfLiked: (...args: [string, string]) => checkIfLiked(...args),
}));

const { useLike } = await import("../useLike");

/** A promise plus the handles to settle it later, so a request can be held open. */
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

type HarnessProps = {
  initialLiked?: boolean;
  initialCount?: number;
  userId?: string | null;
  onLikedChange?: (liked: boolean) => void;
  onFailure?: (reason: string) => void;
};

/**
 * Stands in for the parent that owns the like state — Feed and Search both
 * keep their own set of liked post ids and their own count, and feed them
 * back in as props, which is the interaction most of these cases are about.
 */
function Harness({
  initialLiked,
  initialCount = 10,
  userId = "user-1",
  onLikedChange,
  onFailure,
}: HarnessProps) {
  const [count, setCount] = useState(initialCount);
  const [likedProp, setLikedProp] = useState(initialLiked);
  const { isLiked, likeCount, toggleLike, loading } = useLike(
    "post-1",
    userId,
    count,
    likedProp,
    { onLikedChange, onFailure }
  );

  return (
    <div>
      <button type="button" onClick={toggleLike}>
        toggle
      </button>
      <span data-testid="liked">{isLiked ? "liked" : "not-liked"}</span>
      <span data-testid="count">{likeCount}</span>
      <span data-testid="loading">{loading ? "busy" : "idle"}</span>
      {/* Lets a test play the parent: a refreshed feed page, or a batched
          like-status query landing after the tap. */}
      <button type="button" onClick={() => setCount((c) => c + 1)}>
        parent-count-up
      </button>
      <button type="button" onClick={() => setLikedProp(false)}>
        parent-says-not-liked
      </button>
      <button type="button" onClick={() => setLikedProp(true)}>
        parent-says-liked
      </button>
    </div>
  );
}

const liked = () => screen.getByTestId("liked").textContent;
const count = () => screen.getByTestId("count").textContent;
const click = async (label: string) => {
  await act(async () => {
    screen.getByText(label).click();
  });
};

describe("useLike", () => {
  beforeEach(() => {
    likePost.mockReset();
    unlikePost.mockReset();
    checkIfLiked.mockReset();
    checkIfLiked.mockResolvedValue(false);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("shows the like before the request resolves, with a 3s response", async () => {
    const gate = deferred<LikeMutationResult>();
    likePost.mockReturnValue(gate.promise);

    render(<Harness initialLiked={false} initialCount={10} />);
    expect(liked()).toBe("not-liked");

    const startedAt = performance.now();
    await click("toggle");
    const feedbackAfterMs = performance.now() - startedAt;

    // The whole point: feedback is on screen while the request is still open.
    expect(liked()).toBe("liked");
    expect(count()).toBe("11");
    expect(screen.getByTestId("loading").textContent).toBe("busy");
    // Not a performance assertion about a device — just proof that nothing
    // waits on the network. The target of <=100ms on a real phone is
    // recorded in the progress notes, not here.
    expect(feedbackAfterMs).toBeLessThan(1000);

    // Hold the response for three seconds, on fake timers: sleeping for real
    // makes the suite slow and, worse, makes it depend on the machine not
    // being busy.
    vi.useFakeTimers();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(3000);
    });
    vi.useRealTimers();
    expect(liked()).toBe("liked");

    await act(async () => {
      gate.resolve("changed");
      await gate.promise;
    });
    expect(liked()).toBe("liked");
    expect(count()).toBe("11");
    expect(screen.getByTestId("loading").textContent).toBe("idle");
  });

  it("rolls back and reports the reason when the request fails", async () => {
    likePost.mockRejectedValue(new Error("permission-denied"));
    const onFailure = vi.fn();
    const onLikedChange = vi.fn();

    render(
      <Harness
        initialLiked={false}
        initialCount={4}
        onFailure={onFailure}
        onLikedChange={onLikedChange}
      />
    );

    await click("toggle");

    expect(liked()).toBe("not-liked");
    expect(count()).toBe("4");
    expect(onFailure).toHaveBeenCalledWith("request-failed");
    // The parent is told both the optimistic value and the rollback, so its
    // own copy of the state cannot be left disagreeing with the heart.
    expect(onLikedChange.mock.calls.map((c) => c[0])).toEqual([true, false]);
  });

  it("treats a missing post as a failure, not a successful like", async () => {
    likePost.mockResolvedValue("post-not-found");
    const onFailure = vi.fn();

    render(<Harness initialLiked={false} initialCount={7} onFailure={onFailure} />);
    await click("toggle");

    expect(liked()).toBe("not-liked");
    expect(count()).toBe("7");
    expect(onFailure).toHaveBeenCalledWith("post-missing");
  });

  it("does not offset the count when the server was already liked", async () => {
    // "unchanged" means the like doc already existed, so the aggregate
    // already counts it. Adding an offset here is how a count gains a
    // phantom +1.
    likePost.mockResolvedValue("unchanged");

    render(<Harness initialLiked={false} initialCount={5} />);
    await click("toggle");

    expect(liked()).toBe("liked");
    expect(count()).toBe("5");
  });

  it("collapses like/unlike/like in one tick into a single request", async () => {
    likePost.mockResolvedValue("changed");
    unlikePost.mockResolvedValue("changed");

    render(<Harness initialLiked={false} initialCount={2} />);

    await act(async () => {
      const button = screen.getByText("toggle");
      button.click();
      button.click();
      button.click();
    });

    expect(liked()).toBe("liked");
    expect(likePost).toHaveBeenCalledTimes(1);
    expect(unlikePost).not.toHaveBeenCalled();
  });

  it("honours the newest intent when a tap lands mid-request", async () => {
    const gate = deferred<LikeMutationResult>();
    likePost.mockReturnValue(gate.promise);
    unlikePost.mockResolvedValue("changed");

    render(<Harness initialLiked={false} initialCount={3} />);

    await click("toggle"); // like, request now open
    expect(liked()).toBe("liked");

    await click("toggle"); // unlike while the like is still in flight
    expect(liked()).toBe("not-liked");

    await act(async () => {
      gate.resolve("changed");
      await gate.promise;
    });

    // The stale success must not put the heart back on.
    expect(liked()).toBe("not-liked");
    expect(count()).toBe("3");
    expect(unlikePost).toHaveBeenCalledTimes(1);
  });

  it("ignores a late like-status answer that contradicts the user's tap", async () => {
    likePost.mockResolvedValue("changed");

    render(<Harness initialLiked={false} initialCount={1} />);
    await click("toggle");
    expect(liked()).toBe("liked");

    // A batched query that started before the tap reports "not liked".
    await click("parent-says-not-liked");

    expect(liked()).toBe("liked");
    expect(count()).toBe("2");
  });

  it("drops its offset once the parent's count accounts for the like", async () => {
    likePost.mockResolvedValue("changed");

    render(<Harness initialLiked={false} initialCount={10} />);
    await click("toggle");
    expect(count()).toBe("11"); // 10 + our offset

    // The trigger lands and the feed reloads with the real number.
    await click("parent-count-up");

    // 11, not 12: the offset was released rather than stacked on top.
    expect(count()).toBe("11");

    // And now props are trusted again.
    await click("parent-says-liked");
    expect(liked()).toBe("liked");
  });

  it("does nothing when nobody is signed in", async () => {
    render(<Harness userId={null} initialCount={9} />);
    await click("toggle");

    expect(liked()).toBe("not-liked");
    expect(count()).toBe("9");
    expect(likePost).not.toHaveBeenCalled();
  });

  it("survives unmounting while a request is open", async () => {
    const gate = deferred<LikeMutationResult>();
    likePost.mockReturnValue(gate.promise);
    const onFailure = vi.fn();

    const view = render(
      <Harness initialLiked={false} initialCount={6} onFailure={onFailure} />
    );
    await click("toggle");

    view.unmount();

    await act(async () => {
      gate.resolve("changed");
      await gate.promise;
    });

    expect(onFailure).not.toHaveBeenCalled();
  });

  it("resets everything when the signed-in account changes", async () => {
    likePost.mockResolvedValue("changed");

    const view = render(<Harness initialLiked={false} initialCount={8} />);
    await click("toggle");
    expect(liked()).toBe("liked");
    expect(count()).toBe("9");

    // Same post, different person: nothing we believed carries over.
    await act(async () => {
      view.rerender(<Harness key="other" userId="user-2" initialCount={8} />);
    });

    expect(liked()).toBe("not-liked");
    expect(count()).toBe("8");
  });
});
