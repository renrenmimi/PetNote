import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";

import { PostActions } from "../PostActions";
import { PostIdentity } from "../PostIdentity";

vi.mock("../../Avatar", () => ({
  default: ({ alt }: { alt: string }) => <img alt={alt} src="" />,
}));

const identity = (over: Partial<Parameters<typeof PostIdentity>[0]> = {}) =>
  render(
    <MemoryRouter>
      <PostIdentity
        authorId="u1"
        authorName="mochi_owner"
        timeLabel="1h"
        {...over}
      />
    </MemoryRouter>
  );

/**
 * These are the two components E2 exists for: the same post must introduce
 * itself the same way, and offer the same controls, wherever it appears.
 *
 * The tests are deliberately about behaviour a person would notice — which
 * name leads, whether attribution survives, what a control is called and
 * whether its state is announced — not about class names. A test asserting
 * `className` would have passed happily while the feed used a lucide icon and
 * the detail page used 💬.
 */
describe("PostIdentity", () => {
  it("leads with the pet and keeps the owner as attribution", () => {
    identity({ petId: "p1", petName: "Mochi" });

    // Pet is the heading-weight name...
    const pet = screen.getByRole("button", { name: "Mochi" });
    expect(pet.className).toContain("font-semibold");
    // ...and the owner is still there, still tappable, one line down.
    expect(screen.getByRole("button", { name: "mochi_owner" })).toBeTruthy();
    expect(screen.getByText("1h")).toBeTruthy();
  });

  it("offers one accessible control per destination, not two", () => {
    // The avatar and the name both navigate to the pet, so exposing both made
    // a screen reader read "Mochi, button" twice for one destination.
    identity({ petId: "p1", petName: "Mochi" });
    expect(screen.getAllByRole("button", { name: "Mochi" })).toHaveLength(1);
    expect(screen.getAllByRole("button", { name: "mochi_owner" })).toHaveLength(1);
  });

  it("leads with the author when the post has no pet", () => {
    identity();
    const author = screen.getByRole("button", { name: "mochi_owner" });
    expect(author.className).toContain("font-semibold");
    // No invented pet, and no empty byline slot pretending one exists.
    expect(screen.queryByText("·")).toBeNull();
  });

  it("leads with the author when the pet has been deleted", () => {
    // petId survives on the post; petName does not, once the pet is gone.
    identity({ petId: "p1", petName: null });
    expect(
      screen.getByRole("button", { name: "mochi_owner" }).className
    ).toContain("font-semibold");
  });

  it("does not drop the birthday marker it is given", () => {
    identity({ petId: "p1", petName: "Mochi", isBirthday: true });
    expect(screen.getByText("Birthday")).toBeTruthy();
  });
});

describe("PostActions", () => {
  const actions = (over: Partial<Parameters<typeof PostActions>[0]> = {}) =>
    render(
      <PostActions
        liked={false}
        onLike={() => {}}
        onComment={() => {}}
        onShare={() => {}}
        bookmarked={false}
        onBookmark={() => {}}
        {...over}
      />
    );

  it("names all four controls the same way on every surface", () => {
    actions();
    expect(screen.getByRole("button", { name: "Like" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "Comment" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "Share" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "Save" })).toBeTruthy();
  });

  it("announces like and save state rather than relying on colour", () => {
    actions({ liked: true, bookmarked: true });
    expect(
      screen.getByRole("button", { name: "Unlike" }).getAttribute("aria-pressed")
    ).toBe("true");
    expect(
      screen
        .getByRole("button", { name: "Remove bookmark" })
        .getAttribute("aria-pressed")
    ).toBe("true");
  });

  it("gives every control a 44pt target", () => {
    // Only the comment button used to have one. The heart and the share arrow
    // were 24px of glyph with no padding.
    actions();
    for (const name of ["Like", "Comment", "Share", "Save"]) {
      const button = screen.getByRole("button", { name });
      expect(button.className).toContain("h-11");
      expect(button.className).toContain("w-11");
    }
  });

  it("renders no emoji", () => {
    // The detail page's comment control was 💬 — a colour bitmap at its own
    // baseline, unable to take a tint, beside three line icons.
    const { container } = actions();
    expect(/[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}]/u.test(container.innerHTML))
      .toBe(false);
  });

  it("draws each icon as an svg, once", () => {
    const { container } = actions();
    expect(container.querySelectorAll("svg")).toHaveLength(4);
  });
});
