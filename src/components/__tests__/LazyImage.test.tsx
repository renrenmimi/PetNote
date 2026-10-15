import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { cleanup, render } from "@testing-library/react";

import LazyImage from "../LazyImage";

/**
 * The image that was already there.
 *
 * `loaded` used to be set only by `onLoad`, and the <img> is `opacity-0`
 * until it flips. An image that finishes before React attaches the handler —
 * served from the HTTP cache, or decoded straight away — therefore never
 * became visible, and the pulsing placeholder above it never went away. On
 * the device that was a 464pt grey slab still pulsing 25 s after launch,
 * over a photo that had downloaded perfectly well.
 *
 * jsdom never loads anything, so `complete` and `naturalWidth` are stubbed on
 * the prototype. That is the point: the component must not depend on an event
 * to discover a state it can read.
 */

type ImageState = { complete: boolean; naturalWidth: number };

function stubImageState({ complete, naturalWidth }: ImageState) {
  const proto = HTMLImageElement.prototype;
  const originals = {
    complete: Object.getOwnPropertyDescriptor(proto, "complete"),
    naturalWidth: Object.getOwnPropertyDescriptor(proto, "naturalWidth"),
  };
  Object.defineProperty(proto, "complete", {
    configurable: true,
    get: () => complete,
  });
  Object.defineProperty(proto, "naturalWidth", {
    configurable: true,
    get: () => naturalWidth,
  });
  return () => {
    for (const [key, descriptor] of Object.entries(originals)) {
      if (descriptor) Object.defineProperty(proto, key, descriptor);
      else delete (proto as unknown as Record<string, unknown>)[key];
    }
  };
}

/**
 * jsdom has no IntersectionObserver, and LazyImage constructs one for any
 * image without `priority`. The stub never reports an intersection, which is
 * the state being asserted: below the fold, nothing is rendered.
 */
class NeverIntersects {
  observe() {}
  unobserve() {}
  disconnect() {}
  takeRecords() {
    return [];
  }
  readonly root = null;
  readonly rootMargin = "";
  readonly thresholds: ReadonlyArray<number> = [];
}
beforeAll(() => {
  if (!("IntersectionObserver" in window)) {
    Object.defineProperty(window, "IntersectionObserver", {
      configurable: true,
      writable: true,
      value: NeverIntersects,
    });
    globalThis.IntersectionObserver =
      NeverIntersects as unknown as typeof IntersectionObserver;
  }
});

let restore: (() => void) | null = null;
afterEach(() => {
  restore?.();
  restore = null;
  cleanup();
});

const pulses = (container: HTMLElement) =>
  container.querySelectorAll(".animate-pulse").length;

describe("LazyImage when the image is already complete", () => {
  it("shows a cached image that never fires onLoad", () => {
    restore = stubImageState({ complete: true, naturalWidth: 800 });

    const { container } = render(
      <LazyImage src="https://example.test/photo.jpg" alt="Post media" priority />
    );

    const img = container.querySelector("img");
    expect(img).not.toBeNull();
    // Visible, without any load event having been dispatched.
    expect(img!.className).toContain("opacity-100");
    expect(img!.className).not.toContain("opacity-0");
    // And the placeholder that would otherwise sit on top of it is gone.
    expect(pulses(container)).toBe(0);
  });

  it("treats complete-but-broken as an error, not as loaded", () => {
    // `complete` is also true for an image that finished by failing. Reading
    // it alone would have shown a blank box as though it were a photo.
    restore = stubImageState({ complete: true, naturalWidth: 0 });

    const { container } = render(
      <LazyImage src="https://example.test/gone.jpg" alt="Post media" priority />
    );

    expect(container.querySelector('button[aria-label^="Retry loading"]')).not.toBeNull();
    expect(pulses(container)).toBe(0);
  });

  it("still shows the placeholder while an image is genuinely pending", () => {
    // The control: none of the above may be achieved by never showing it.
    restore = stubImageState({ complete: false, naturalWidth: 0 });

    const { container } = render(
      <LazyImage src="https://example.test/slow.jpg" alt="Post media" priority />
    );

    expect(pulses(container)).toBe(1);
    expect(container.querySelector("img")!.className).toContain("opacity-0");
  });

  it("does not render an image at all before it is in view", () => {
    restore = stubImageState({ complete: true, naturalWidth: 800 });

    const { container } = render(
      <LazyImage src="https://example.test/below.jpg" alt="Post media" />
    );

    // No priority, and jsdom's IntersectionObserver never fires, so the
    // element stays out of the DOM and the placeholder stands in for it.
    expect(container.querySelector("img")).toBeNull();
    expect(pulses(container)).toBe(1);
  });
});
