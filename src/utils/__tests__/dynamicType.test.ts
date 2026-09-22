import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { applyDynamicType, watchDynamicType } from "../dynamicType";

/**
 * jsdom has no `-apple-system-body`, so the measurement is stubbed at the one
 * seam that matters: what `getComputedStyle().fontSize` reports for the probe
 * span. Everything above that — the ratio, the clamp, the rounding, the
 * re-read on resume — is the code under test.
 */
function stubSystemBody(px: string | null) {
  const real = window.getComputedStyle.bind(window);
  vi.spyOn(window, "getComputedStyle").mockImplementation(
    ((el: Element, pseudo?: string | null) => {
      const style = (el as HTMLElement).getAttribute?.("style") ?? "";
      if (style.includes("-apple-system-body")) {
        return { fontSize: px ?? "" } as CSSStyleDeclaration;
      }
      return real(el as Element, pseudo);
    }) as typeof window.getComputedStyle
  );
}

describe("applyDynamicType", () => {
  beforeEach(() => {
    document.documentElement.style.fontSize = "";
  });

  afterEach(() => {
    vi.restoreAllMocks();
    document.documentElement.style.fontSize = "";
  });

  it("does nothing at the default text size", () => {
    // 17px is -apple-system-body with the slider untouched. Most people are
    // here, and they must see no change at all.
    stubSystemBody("17px");
    applyDynamicType();
    expect(document.documentElement.style.fontSize).toBe("16px");
  });

  it("scales the root in proportion for a larger setting", () => {
    stubSystemBody("19px");
    applyDynamicType();
    // 16 * 19/17 = 17.88 -> 17.9
    expect(document.documentElement.style.fontSize).toBe("17.9px");
  });

  it("clamps the largest accessibility size to something the layout survives", () => {
    // Measured on a real simulator at accessibility-extra-extra-extra-large.
    stubSystemBody("53px");
    applyDynamicType();
    // 16 * 53/17 = 49.9px would be a 3.1x layout; 19px is the ceiling.
    expect(document.documentElement.style.fontSize).toBe("19px");
  });

  it("never shrinks the app when the keyword is not understood", () => {
    // Desktop Safari resolves -apple-system-body to about 13px, and a browser
    // that ignores the keyword leaves the inherited 16px. Either way the
    // result must be a no-op rather than a smaller app.
    for (const px of ["13px", "16px", "1px"]) {
      document.documentElement.style.fontSize = "";
      vi.restoreAllMocks();
      stubSystemBody(px);
      applyDynamicType();
      expect(document.documentElement.style.fontSize).toBe("16px");
    }
  });

  it("leaves the root alone when the probe cannot be measured", () => {
    stubSystemBody(null);
    applyDynamicType();
    expect(document.documentElement.style.fontSize).toBe("");
  });

  it("re-reads on resume, because the setting can change in the background", () => {
    stubSystemBody("17px");
    const stop = watchDynamicType();
    expect(document.documentElement.style.fontSize).toBe("16px");

    // The person went to Settings, made text bigger, and came back.
    vi.restoreAllMocks();
    stubSystemBody("24px");
    window.dispatchEvent(new Event("focus"));
    // 16 * 24/17 = 22.6 -> clamped to 19
    expect(document.documentElement.style.fontSize).toBe("19px");

    stop();
    vi.restoreAllMocks();
    stubSystemBody("17px");
    window.dispatchEvent(new Event("focus"));
    // Detached: no longer listening.
    expect(document.documentElement.style.fontSize).toBe("19px");
  });

  it("leaves the probe span out of the document", () => {
    stubSystemBody("17px");
    const before = document.body.childElementCount;
    applyDynamicType();
    expect(document.body.childElementCount).toBe(before);
  });
});
