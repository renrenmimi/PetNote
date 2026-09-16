import { act, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { PetSpotlight } from "../PetSpotlight";
import type { Post } from "../../services/posts";

const getPopularPosts = vi.fn();

vi.mock("../../services/posts", () => ({
  getPopularPosts: (...a: unknown[]) => getPopularPosts(...a),
}));

vi.mock("../Avatar", () => ({
  default: () => null,
}));

const post = (id: string, petName: string) =>
  ({ id, petName, authorName: "someone", media: [] }) as unknown as Post;

/** Mounts and lets the load effect settle. */
async function mount() {
  const view = render(
    <MemoryRouter>
      <PetSpotlight limitCount={3} />
    </MemoryRouter>
  );
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
  return view;
}

describe("PetSpotlight", () => {
  beforeEach(() => {
    getPopularPosts.mockReset();
    localStorage.clear();
  });

  it("renders nothing at all when there are no popular pets", async () => {
    // It used to render a full-width card whose only content was "Share your
    // pet to get featured!" — a prompt the product appeared to be making,
    // above a feed that already had posts. Nothing to show is now nothing
    // rendered: no heading, no card, no space.
    getPopularPosts.mockResolvedValue([]);
    const { container } = await mount();

    expect(container.innerHTML).toBe("");
    expect(screen.queryByText(/get featured/i)).toBeNull();
    expect(screen.queryByText(/popular pets/i)).toBeNull();
  });

  it("renders nothing when the popularity query fails", async () => {
    // Same silence deliberately. A failed decorative query is not something
    // to ask the reader to act on, and it is certainly not evidence that
    // they should post more.
    getPopularPosts.mockRejectedValue(new Error("offline"));
    const { container } = await mount();

    expect(container.innerHTML).toBe("");
  });

  it("takes no space while it is still loading", async () => {
    // A skeleton that resolves to nothing has still moved the feed down and
    // back. There is no skeleton.
    getPopularPosts.mockReturnValue(new Promise(() => {}));
    const { container } = render(
      <MemoryRouter>
        <PetSpotlight limitCount={3} />
      </MemoryRouter>
    );

    expect(container.innerHTML).toBe("");
  });

  it("appears, labelled with the pets, once it has some", async () => {
    getPopularPosts.mockResolvedValue([
      post("p1", "Mochi"),
      post("p2", "Biscuit"),
      post("p3", "Pepper"),
    ]);
    await mount();

    expect(screen.getByRole("region", { name: /popular pets/i })).toBeTruthy();
    expect(screen.getByText("Mochi")).toBeTruthy();
    expect(screen.getByText("Biscuit")).toBeTruthy();
  });

  it("widens the window before giving up", async () => {
    // A short window with too few results falls back to a longer one rather
    // than showing a thin strip.
    getPopularPosts
      .mockResolvedValueOnce([post("p1", "Mochi")])
      .mockResolvedValueOnce([
        post("p1", "Mochi"),
        post("p2", "Biscuit"),
        post("p3", "Pepper"),
      ]);
    await mount();

    expect(getPopularPosts).toHaveBeenCalledTimes(2);
    expect(getPopularPosts).toHaveBeenNthCalledWith(1, 3, 24);
    expect(getPopularPosts).toHaveBeenNthCalledWith(2, 3, 24 * 7);
    expect(screen.getByText("Pepper")).toBeTruthy();
  });
});
