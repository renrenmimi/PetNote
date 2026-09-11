import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { PullToRefreshIndicator } from "../PullToRefreshIndicator";

const labels = {
  pullLabel: "Pull to refresh",
  releaseLabel: "Release to refresh",
  refreshingLabel: "Refreshing...",
};

describe("PullToRefreshIndicator", () => {
  it("renders nothing at rest", () => {
    const { container } = render(
      <PullToRefreshIndicator
        state="idle"
        distance={0}
        threshold={64}
        {...labels}
      />
    );
    // The old feed kept a permanent "Pull to refresh" line above the first
    // card whether or not the gesture was in progress.
    expect(container.innerHTML).toBe("");
  });

  it("says what will happen at each stage of the gesture", () => {
    const view = render(
      <PullToRefreshIndicator
        state="pulling"
        distance={20}
        threshold={64}
        {...labels}
      />
    );
    expect(screen.getByText("Pull to refresh")).toBeTruthy();

    view.rerender(
      <PullToRefreshIndicator
        state="armed"
        distance={70}
        threshold={64}
        {...labels}
      />
    );
    expect(screen.getByText("Release to refresh")).toBeTruthy();

    view.rerender(
      <PullToRefreshIndicator
        state="refreshing"
        distance={0}
        threshold={64}
        {...labels}
      />
    );
    expect(screen.getByText("Refreshing...")).toBeTruthy();
  });

  it("turns the arrow by the real gesture distance, not a timer", () => {
    const view = render(
      <PullToRefreshIndicator
        state="pulling"
        distance={16}
        threshold={64}
        {...labels}
      />
    );
    const rotationAt = () => {
      const svg = document.querySelector("svg");
      return svg?.getAttribute("style") ?? "";
    };
    // A quarter of the way there is a quarter of the turn.
    expect(rotationAt()).toContain("rotate(45deg)");

    view.rerender(
      <PullToRefreshIndicator
        state="pulling"
        distance={64}
        threshold={64}
        {...labels}
      />
    );
    expect(rotationAt()).toContain("rotate(180deg)");

    // Past the threshold it stops at half a turn instead of spinning on.
    view.rerender(
      <PullToRefreshIndicator
        state="armed"
        distance={200}
        threshold={64}
        {...labels}
      />
    );
    expect(rotationAt()).toContain("rotate(180deg)");
  });

  it("announces politely and keeps the arrow out of the accessibility tree", () => {
    render(
      <PullToRefreshIndicator
        state="refreshing"
        distance={0}
        threshold={64}
        {...labels}
      />
    );
    const status = screen.getByRole("status");
    expect(status.getAttribute("aria-live")).toBe("polite");
    expect(document.querySelector("svg")?.getAttribute("aria-hidden")).toBe(
      "true"
    );
  });

  it("lets reduced-motion turn the spinner off", () => {
    render(
      <PullToRefreshIndicator
        state="refreshing"
        distance={0}
        threshold={64}
        {...labels}
      />
    );
    const svg = document.querySelector("svg");
    expect(svg?.getAttribute("class")).toContain("motion-reduce:animate-none");
  });
});
