import { afterEach } from "vitest";
import { cleanup } from "@testing-library/react";

// Testing Library only registers its own cleanup when vitest runs with
// globals. This project runs with `globals: false`, so without this every
// test would render into the DOM left behind by the previous one and
// getByText would find two of everything.
afterEach(() => {
  cleanup();
});

/**
 * jsdom implements no scrolling at all, so these are simply absent and
 * `vi.spyOn(el, "scrollBy")` fails with "does not exist". They are stubbed as
 * no-ops rather than faked with real geometry: a test that cares about
 * scrolling asserts on the call, and one that does not should not crash on it.
 */
for (const name of ["scrollBy", "scrollTo", "scrollIntoView"] as const) {
  if (!(name in Element.prototype)) {
    Object.defineProperty(Element.prototype, name, {
      value: () => {},
      writable: true,
      configurable: true,
    });
  }
}
