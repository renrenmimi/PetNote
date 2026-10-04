import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  keyboardGeometry,
  onKeyboardSettled,
  setKeyboardBackdrop,
} from "../keyboard";

/**
 * These run on the web path — `Capacitor.isNativePlatform()` is false under
 * jsdom — so what they pin is the settling contract and the visual viewport
 * reading. The native listeners feed the same `note()` and the same settle
 * timer, so the coalescing behaviour below is the behaviour on the device
 * too; what a test here cannot prove is that the plugin fires at all, which
 * is why the device evidence is recorded separately.
 */

type FakeViewport = {
  height: number;
  offsetTop: number;
  addEventListener: (name: string, fn: () => void) => void;
  removeEventListener: (name: string, fn: () => void) => void;
  fire: () => void;
};

function installViewport(height: number, offsetTop = 0): FakeViewport {
  const handlers = new Set<() => void>();
  const vp: FakeViewport = {
    height,
    offsetTop,
    addEventListener: (_name, fn) => handlers.add(fn),
    removeEventListener: (_name, fn) => handlers.delete(fn),
    fire: () => handlers.forEach((fn) => fn()),
  };
  Object.defineProperty(window, "visualViewport", {
    value: vp,
    configurable: true,
    writable: true,
  });
  return vp;
}

describe("keyboard settling", () => {
  /*
   * Subscriptions are torn down here rather than at the end of each test.
   * The module keeps its listener set at module scope, so a test that throws
   * before its own `stop()` leaves the platform subscription attached and the
   * next test's viewport is never subscribed at all — one genuine failure
   * reported as five. Registering the undo the moment it exists removes that
   * whole class of cascade.
   */
  const stops: Array<() => void> = [];
  const subscribe = (listener: Parameters<typeof onKeyboardSettled>[0]) => {
    const stop = onKeyboardSettled(listener);
    stops.push(stop);
    return stop;
  };

  beforeEach(() => {
    vi.useFakeTimers();
    window.innerHeight = 900;
  });

  afterEach(() => {
    while (stops.length) stops.pop()!();
    vi.useRealTimers();
    Object.defineProperty(window, "visualViewport", {
      value: undefined,
      configurable: true,
      writable: true,
    });
  });

  it("reports the keyboard height once the viewport has settled", () => {
    const vp = installViewport(900);
    const seen: Array<{ visible: boolean; height: number }> = [];
    const stop = subscribe((g) => seen.push({ ...g }));

    vp.height = 500; // keyboard open
    vp.fire();
    // Nothing yet: a change on its own is not a settled state.
    expect(seen).toHaveLength(0);

    vi.advanceTimersByTime(60);
    expect(seen).toEqual([{ visible: true, height: 400, reason: "viewport" }]);
    stop();
  });

  it("coalesces a burst into one callback", () => {
    const vp = installViewport(900);
    let calls = 0;
    const stop = subscribe(() => {
      calls += 1;
    });

    // iOS reports the frame more than once as the keyboard animates.
    for (const height of [800, 650, 520, 500]) {
      vp.height = height;
      vp.fire();
      vi.advanceTimersByTime(20);
    }
    vi.advanceTimersByTime(60);

    expect(calls).toBe(1);
    expect(keyboardGeometry()).toEqual({
      visible: true,
      height: 400,
      reason: "viewport",
    });
    stop();
  });

  it("reports a later change that a fixed delay would have missed", () => {
    /*
     * The case this whole module exists for. A Chinese input method raises
     * its candidate bar after the keyboard has already settled — here, 400 ms
     * later, which is past any delay started when the field was focused.
     * The old implementation timed 320 ms from `focusin`; this one has no
     * deadline to miss, so the second change arrives as its own settled
     * report with the taller keyboard.
     */
    const vp = installViewport(900);
    const seen: number[] = [];
    const stop = subscribe((g) => seen.push(g.height));

    vp.height = 500;
    vp.fire();
    vi.advanceTimersByTime(60);
    expect(seen).toEqual([400]);

    vi.advanceTimersByTime(400);
    vp.height = 440; // candidate bar adds 60px
    vp.fire();
    vi.advanceTimersByTime(60);

    expect(seen).toEqual([400, 460]);
    stop();
  });

  it("does not call a small viewport shift a keyboard", () => {
    const vp = installViewport(900);
    const seen: boolean[] = [];
    const stop = subscribe((g) => seen.push(g.visible));

    // A browser's own toolbar collapsing, not a keyboard.
    vp.height = 840;
    vp.fire();
    vi.advanceTimersByTime(60);

    expect(seen).toEqual([false]);
    stop();
  });

  it("stops listening when the last subscriber leaves", () => {
    const vp = installViewport(900);
    let calls = 0;
    const stopA = subscribe(() => {
      calls += 1;
    });
    const stopB = subscribe(() => {
      calls += 1;
    });

    stopA();
    vp.height = 500;
    vp.fire();
    vi.advanceTimersByTime(60);
    expect(calls).toBe(1); // only B

    stopB();
    vp.height = 900;
    vp.fire();
    vi.advanceTimersByTime(60);
    expect(calls).toBe(1); // nobody
  });
});

describe("keyboard backdrop", () => {
  afterEach(() => {
    document.documentElement.style.removeProperty("--app-backdrop");
    document.documentElement.classList.remove("dark");
  });

  it("overrides the document colour and hands back the undo", () => {
    const restore = setKeyboardBackdrop("#ec4899");
    expect(
      document.documentElement.style.getPropertyValue("--app-backdrop")
    ).toBe("#ec4899");

    restore();
    // Removed rather than set back to a remembered value, so the cascade —
    // and therefore dark mode — is in charge again.
    expect(
      document.documentElement.style.getPropertyValue("--app-backdrop")
    ).toBe("");
  });
});
