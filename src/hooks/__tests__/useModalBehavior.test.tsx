import { useState } from "react";
import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { useModalBehavior } from "../useModalBehavior";

function Dialog({ onClose }: { onClose: () => void }) {
  const panelRef = useModalBehavior({ open: true, onClose });
  return (
    <div ref={panelRef} tabIndex={-1} data-testid="panel">
      <button type="button">First action</button>
      <button type="button">Second action</button>
    </div>
  );
}

function Host() {
  const [open, setOpen] = useState(false);
  return (
    <div>
      <button type="button" onClick={() => setOpen(true)}>
        Open
      </button>
      <div style={{ height: 3000 }}>tall page</div>
      {open ? <Dialog onClose={() => setOpen(false)} /> : null}
    </div>
  );
}

describe("useModalBehavior", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    window.scrollTo = vi.fn() as unknown as typeof window.scrollTo;
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
    document.body.removeAttribute("style");
  });

  // Two acts, not one: the click's state update is flushed at the end of the
  // act block, so the mount effect — and the timer it schedules — does not
  // exist yet if the clock is advanced inside the same one.
  const open = () => {
    act(() => {
      screen.getByText("Open").click();
    });
    act(() => {
      vi.advanceTimersByTime(10);
    });
  };

  it("pins the page while open and puts it back on close", () => {
    render(<Host />);
    Object.defineProperty(window, "scrollY", { value: 640, configurable: true });

    open();
    // overflow:hidden alone still rubber-bands on iOS and loses the offset;
    // pinning the body at a negative top is what actually holds the view.
    expect(document.body.style.position).toBe("fixed");
    expect(document.body.style.top).toBe("-640px");
    expect(document.body.style.overflow).toBe("hidden");

    act(() => {
      fireEvent.keyDown(document, { key: "Escape" });
    });

    expect(document.body.style.position).toBe("");
    expect(document.body.style.top).toBe("");
    expect(window.scrollTo).toHaveBeenCalledWith(0, 640);
  });

  it("closes on Escape", () => {
    render(<Host />);
    open();
    expect(screen.getByTestId("panel")).toBeTruthy();

    act(() => {
      fireEvent.keyDown(document, { key: "Escape" });
    });

    expect(screen.queryByTestId("panel")).toBeNull();
  });

  it("ignores other keys", () => {
    render(<Host />);
    open();
    act(() => {
      fireEvent.keyDown(document, { key: "Enter" });
      fireEvent.keyDown(document, { key: "a" });
    });
    expect(screen.getByTestId("panel")).toBeTruthy();
  });

  it("moves focus into the dialog and back to the opener", () => {
    render(<Host />);
    const opener = screen.getByText("Open") as HTMLButtonElement;
    act(() => {
      opener.focus();
    });

    open();
    expect(document.activeElement?.textContent).toBe("First action");

    act(() => {
      fireEvent.keyDown(document, { key: "Escape" });
    });
    // Back where it came from, so the next Tab continues from the control
    // that opened the dialog rather than the top of the document.
    expect(document.activeElement?.textContent).toBe("Open");
  });

  it("falls back to the panel when there is nothing focusable inside", () => {
    function TextOnly() {
      const panelRef = useModalBehavior({ open: true, onClose: () => {} });
      return (
        <div ref={panelRef} tabIndex={-1} data-testid="panel">
          Just a message
        </div>
      );
    }
    render(<TextOnly />);
    act(() => {
      vi.advanceTimersByTime(10);
    });
    expect(document.activeElement).toBe(screen.getByTestId("panel"));
  });
});
