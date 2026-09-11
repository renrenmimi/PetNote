import { useCallback, useState } from "react";
import { act, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { LikeMutationResult } from "../../services/posts";
import type { Post } from "../../services/posts";

/**
 * PostCard with the *real* useLike underneath, and a parent that behaves the
 * way Feed does: it keeps its own set of liked post ids plus its own count,
 * and feeds them back in as `initialLiked` / `post.likeCount`.
 *
 * `useMock` is deliberately not used. It replaces the hook with local state,
 * so a test that went through it would prove nothing about the code that
 * actually runs on the phone.
 */

const likePost = vi.fn<(postId: string, userId: string) => Promise<LikeMutationResult>>();
const unlikePost = vi.fn<(postId: string, userId: string) => Promise<LikeMutationResult>>();
const checkIfLiked = vi.fn<(postId: string, userId: string) => Promise<boolean>>();
const showToast = vi.fn();

vi.mock("../../services/posts", () => ({
  likePost: (...a: [string, string]) => likePost(...a),
  unlikePost: (...a: [string, string]) => unlikePost(...a),
  checkIfLiked: (...a: [string, string]) => checkIfLiked(...a),
  deletePost: vi.fn(),
  pinPost: vi.fn(),
  unpinPost: vi.fn(),
}));
vi.mock("../../services/pets", () => ({
  getPetById: vi.fn().mockResolvedValue(null),
  isBirthdayToday: () => false,
}));
vi.mock("../../services/block", () => ({ blockUser: vi.fn() }));
vi.mock("../../contexts/ToastContext", () => ({
  useToast: () => ({ showToast }),
}));
vi.mock("../../hooks/useAuth", () => ({
  useAuth: () => ({
    user: { uid: "user-1" },
    profile: null,
    isBanned: false,
    isAdmin: false,
  }),
}));
vi.mock("../../hooks/useBookmark", () => ({
  useBookmark: () => ({ isBookmarked: false, toggleBookmark: vi.fn() }),
}));
vi.mock("../../hooks/useFollow", () => ({
  useFollowPet: () => ({
    isFollowing: false,
    toggleFollow: vi.fn(),
    loading: false,
  }),
}));
vi.mock("react-router-dom", () => ({
  useNavigate: () => vi.fn(),
  Link: ({ children }: { children?: React.ReactNode }) => <span>{children}</span>,
}));

const { PostCard } = await import("../PostCard");

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

const basePost = {
  id: "post-1",
  authorId: "someone-else",
  authorName: "Tester",
  authorAvatar: "",
  caption: "a test post",
  mediaUrl: "",
  mediaType: "image",
  likeCount: 10,
  commentCount: 0,
  createdAt: new Date("2026-09-01T00:00:00Z"),
} as unknown as Post;

/** Mirrors Feed's ownership of like state. */
function FeedLikeParent({ serverCount = 10 }: { serverCount?: number }) {
  const [likedIds, setLikedIds] = useState<Set<string>>(new Set());
  const [count, setCount] = useState(serverCount);

  const onLikeChanged = useCallback((postId: string, liked: boolean) => {
    setLikedIds((prev) => {
      const next = new Set(prev);
      if (liked) next.add(postId);
      else next.delete(postId);
      return next;
    });
  }, []);

  return (
    <div>
      <span data-testid="parent-liked">
        {likedIds.has("post-1") ? "parent-liked" : "parent-not-liked"}
      </span>
      <button type="button" onClick={() => setCount((c) => c + 1)}>
        trigger-landed
      </button>
      <PostCard
        post={{ ...basePost, likeCount: count }}
        initialLiked={likedIds.has("post-1")}
        onLikeChanged={onLikeChanged}
      />
    </div>
  );
}

const likeButton = () => screen.getByLabelText("Like");

/** PostCard renders the total as "<n> likes" below the actions. */
const shownCount = () => {
  const node = screen
    .getAllByText(/\d+ likes/)
    .map((el) => el.textContent ?? "")
    .find((text) => /\d+ likes/.test(text));
  if (!node) throw new Error("like count not rendered");
  return node.trim().replace(" likes", "");
};

/** Whether the heart is in its liked (red) state. */
const heartIsFilled = () =>
  (likeButton().className ?? "").includes("text-red-500");

describe("PostCard like, integrated with the real hook and a Feed-like parent", () => {
  beforeEach(() => {
    likePost.mockReset();
    unlikePost.mockReset();
    checkIfLiked.mockReset();
    checkIfLiked.mockResolvedValue(false);
    showToast.mockReset();
  });

  it("moves the heart, the count and the parent's set before the response", async () => {
    const gate = deferred<LikeMutationResult>();
    likePost.mockReturnValue(gate.promise);

    render(<FeedLikeParent serverCount={10} />);
    expect(shownCount()).toBe("10");
    expect(screen.getByTestId("parent-liked").textContent).toBe("parent-not-liked");

    const startedAt = performance.now();
    await act(async () => {
      likeButton().click();
    });
    const elapsed = performance.now() - startedAt;

    expect(shownCount()).toBe("11");
    expect(heartIsFilled()).toBe(true);
    expect(screen.getByTestId("parent-liked").textContent).toBe("parent-liked");
    expect(elapsed).toBeLessThan(1000);

    await act(async () => {
      await new Promise((r) => setTimeout(r, 3000));
    });
    // Still showing the like three seconds into an unanswered request.
    expect(shownCount()).toBe("11");

    await act(async () => {
      gate.resolve("changed");
      await gate.promise;
    });
    expect(shownCount()).toBe("11");
  }, 15000);

  it("does not add the like twice when the aggregate catches up", async () => {
    likePost.mockResolvedValue("changed");

    render(<FeedLikeParent serverCount={10} />);
    await act(async () => {
      likeButton().click();
    });
    expect(shownCount()).toBe("11");

    // The onLikeCreated trigger lands and the parent re-renders with 11.
    await act(async () => {
      screen.getByText("trigger-landed").click();
    });

    expect(shownCount()).toBe("11");
  });

  it("rolls the card and the parent back, and says so, when the write fails", async () => {
    likePost.mockRejectedValue(new Error("permission denied"));

    render(<FeedLikeParent serverCount={4} />);
    await act(async () => {
      likeButton().click();
    });

    expect(shownCount()).toBe("4");
    expect(heartIsFilled()).toBe(false);
    expect(screen.getByTestId("parent-liked").textContent).toBe("parent-not-liked");
    expect(showToast).toHaveBeenCalledWith(
      "Could not update like. Please try again.",
      "error"
    );
  });

  it("reports a deleted post instead of showing a filled heart", async () => {
    likePost.mockResolvedValue("post-not-found");

    render(<FeedLikeParent serverCount={4} />);
    await act(async () => {
      likeButton().click();
    });

    expect(shownCount()).toBe("4");
    expect(heartIsFilled()).toBe(false);
    expect(showToast).toHaveBeenCalledWith(
      "This post is no longer available",
      "error"
    );
  });
});
