import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { AuthShell } from "../AuthShell";

/**
 * jsdom gives every element a zero-sized rect, so the geometry the component
 * reads has to be supplied. Each test states where the scroller and the field
 * are, which is the whole input to the decision being tested.
 */
function stubRects(scrollBox: DOMRectInit, fieldBox: DOMRectInit) {
  const scroller = document.querySelector(".auth-scroll") as HTMLElement;
  const field = screen.getByLabelText("Password") as HTMLElement;
  vi.spyOn(scroller, "getBoundingClientRect").mockReturnValue(
    DOMRect.fromRect(scrollBox)
  );
  vi.spyOn(field, "getBoundingClientRect").mockReturnValue(
    DOMRect.fromRect(fieldBox)
  );
  return { scroller, field };
}

function renderShell() {
  return render(
    <AuthShell gradient="bg-test">
      <label htmlFor="pw">Password</label>
      <input id="pw" type="password" />
    </AuthShell>
  );
}

describe("AuthShell", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    // jsdom has no matchMedia.
    vi.stubGlobal(
      "matchMedia",
      vi.fn().mockReturnValue({ matches: false, addEventListener: vi.fn() })
    );
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("lifts a focused field out from under the bottom frosted edge", () => {
    renderShell();
    // Scroller occupies 0–500; the field's lower half is past 500 − 72.
    const { scroller, field } = stubRects(
      { x: 0, y: 0, width: 390, height: 500 },
      { x: 0, y: 450, width: 300, height: 44 }
    );
    const scrollBy = vi.spyOn(scroller, "scrollBy").mockImplementation(() => {});

    act(() => {
      field.focus();
      // The web view is resized after focus, so the component waits before
      // measuring; nothing should have moved yet.
      expect(scrollBy).not.toHaveBeenCalled();
      vi.advanceTimersByTime(400);
    });

    expect(scrollBy).toHaveBeenCalledTimes(1);
    const arg = scrollBy.mock.calls[0][0] as ScrollToOptions;
    // 494 (field bottom) − (500 − 72) = 66px down.
    expect(arg.top).toBe(66);
    expect(arg.behavior).toBe("smooth");
  });

  it("pulls a field down from under the top frosted edge", () => {
    renderShell();
    const { scroller, field } = stubRects(
      { x: 0, y: 0, width: 390, height: 500 },
      { x: 0, y: 20, width: 300, height: 44 }
    );
    const scrollBy = vi.spyOn(scroller, "scrollBy").mockImplementation(() => {});

    act(() => {
      field.focus();
      vi.advanceTimersByTime(400);
    });

    // 0 + 72 − 20 = 52px up.
    expect((scrollBy.mock.calls[0][0] as ScrollToOptions).top).toBe(-52);
  });

  it("leaves a comfortably placed field alone", () => {
    renderShell();
    const { scroller, field } = stubRects(
      { x: 0, y: 0, width: 390, height: 500 },
      { x: 0, y: 200, width: 300, height: 44 }
    );
    const scrollBy = vi.spyOn(scroller, "scrollBy").mockImplementation(() => {});

    act(() => {
      field.focus();
      vi.advanceTimersByTime(400);
    });

    expect(scrollBy).not.toHaveBeenCalled();
  });

  it("does not animate when reduced motion is asked for", () => {
    vi.stubGlobal(
      "matchMedia",
      vi.fn().mockReturnValue({ matches: true, addEventListener: vi.fn() })
    );
    renderShell();
    const { scroller, field } = stubRects(
      { x: 0, y: 0, width: 390, height: 500 },
      { x: 0, y: 450, width: 300, height: 44 }
    );
    const scrollBy = vi.spyOn(scroller, "scrollBy").mockImplementation(() => {});

    act(() => {
      field.focus();
      vi.advanceTimersByTime(400);
    });

    expect((scrollBy.mock.calls[0][0] as ScrollToOptions).behavior).toBe("auto");
  });

  it("does nothing when focus was given up before the timer fired", () => {
    renderShell();
    const { scroller, field } = stubRects(
      { x: 0, y: 0, width: 390, height: 500 },
      { x: 0, y: 450, width: 300, height: 44 }
    );
    const scrollBy = vi.spyOn(scroller, "scrollBy").mockImplementation(() => {});

    act(() => {
      field.focus();
      field.blur();
      vi.advanceTimersByTime(400);
    });

    // Scrolling to a field nobody is in is worse than doing nothing.
    expect(scrollBy).not.toHaveBeenCalled();
  });

  it("does not move the page for a field removed while the timer was pending", () => {
    renderShell();
    const { scroller, field } = stubRects(
      { x: 0, y: 0, width: 390, height: 500 },
      { x: 0, y: 450, width: 300, height: 44 }
    );
    const scrollBy = vi.spyOn(scroller, "scrollBy").mockImplementation(() => {});

    act(() => {
      field.focus();
      // The reset page swaps its email step for its code step exactly like
      // this. A detached element measures as all zeroes, which used to read
      // as "far above the fold" and threw the page upwards.
      field.remove();
      vi.advanceTimersByTime(400);
    });

    expect(scrollBy).not.toHaveBeenCalled();
  });

  it("only reacts to focus inside its own scroller", () => {
    renderShell();
    const outside = document.createElement("input");
    document.body.appendChild(outside);
    const scroller = document.querySelector(".auth-scroll") as HTMLElement;
    const scrollBy = vi.spyOn(scroller, "scrollBy").mockImplementation(() => {});

    act(() => {
      outside.focus();
      fireEvent.focusIn(scroller);
      vi.advanceTimersByTime(400);
    });

    expect(scrollBy).not.toHaveBeenCalled();
    outside.remove();
  });
});
