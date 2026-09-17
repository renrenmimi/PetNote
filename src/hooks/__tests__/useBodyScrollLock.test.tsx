import { act, render } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { useBodyScrollLock } from "../useBodyScrollLock";

function Locker({ active }: { active: boolean }) {
  useBodyScrollLock(active);
  return null;
}

describe("useBodyScrollLock", () => {
  beforeEach(() => {
    window.scrollTo = vi.fn() as unknown as typeof window.scrollTo;
    Object.defineProperty(window, "scrollY", { value: 900, configurable: true });
  });

  afterEach(() => {
    vi.restoreAllMocks();
    document.body.removeAttribute("style");
  });

  it("pins the page at its current offset and restores it", () => {
    const view = render(<Locker active />);
    expect(document.body.style.position).toBe("fixed");
    expect(document.body.style.top).toBe("-900px");

    act(() => view.unmount());
    expect(document.body.style.position).toBe("");
    expect(window.scrollTo).toHaveBeenCalledWith(0, 900);
  });

  it("survives nesting: two overlays, one page position", () => {
    // Long-pressing a post opens the quick-action menu; choosing Share opens
    // the sheet on top of it. Without counting, the second lock reads
    // window.scrollY while the body is already pinned, records 0, and sends
    // the page to the top when it closes.
    const outer = render(<Locker active />);
    expect(document.body.style.top).toBe("-900px");

    // The inner overlay mounts while the body is pinned, so scrollY is now 0.
    Object.defineProperty(window, "scrollY", { value: 0, configurable: true });
    const inner = render(<Locker active />);
    expect(document.body.style.top).toBe("-900px");

    // Closing the inner one must not release the page — the outer is still up.
    act(() => inner.unmount());
    expect(document.body.style.position).toBe("fixed");
    expect(window.scrollTo).not.toHaveBeenCalled();

    act(() => outer.unmount());
    expect(document.body.style.position).toBe("");
    expect(window.scrollTo).toHaveBeenCalledWith(0, 900);
  });

  it("does nothing while inactive", () => {
    render(<Locker active={false} />);
    expect(document.body.style.position).toBe("");
  });
});
