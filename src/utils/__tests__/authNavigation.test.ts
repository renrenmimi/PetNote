import { describe, expect, it } from "vitest";
import type { Location } from "react-router-dom";

import { browseExitTarget, signInReturnState } from "../authNavigation";

const loc = (over: Partial<Location> = {}): Location =>
  ({
    pathname: "/post/abc",
    search: "",
    hash: "",
    state: null,
    key: "k",
    ...over,
  }) as Location;

describe("signInReturnState", () => {
  it("records where to come back to, query string included", () => {
    expect(
      signInReturnState(loc({ pathname: "/search", search: "?tag=corgi" }))
    ).toEqual({ from: { pathname: "/search", search: "?tag=corgi" } });
  });
});

describe("browseExitTarget", () => {
  it("returns to the page that sent you to sign in", () => {
    expect(
      browseExitTarget(
        loc({
          pathname: "/login",
          state: { from: { pathname: "/pet/p1", search: "" } },
        })
      )
    ).toBe("/pet/p1");
  });

  it("keeps the query string of the origin", () => {
    expect(
      browseExitTarget(
        loc({
          pathname: "/login",
          state: { from: { pathname: "/search", search: "?tag=corgi" } },
        })
      )
    ).toBe("/search?tag=corgi");
  });

  it("falls back to the public feed when there is no origin", () => {
    // Typing the URL, following a link from outside, or a cold start on the
    // phone: nothing is behind the page, which is why this is not
    // history.back().
    expect(browseExitTarget(loc({ pathname: "/login" }))).toBe("/");
  });

  it("refuses an absolute URL", () => {
    expect(
      browseExitTarget(
        loc({
          pathname: "/login",
          state: { from: { pathname: "https://evil.example/x", search: "" } },
        })
      )
    ).toBe("/");
  });

  it("refuses a protocol-relative URL", () => {
    // "//evil.example" is another origin as far as a browser is concerned,
    // and it starts with a slash, so a naive check passes it.
    expect(
      browseExitTarget(
        loc({
          pathname: "/login",
          state: { from: { pathname: "//evil.example", search: "" } },
        })
      )
    ).toBe("/");
  });

  it("does not send somebody back to an auth screen", () => {
    // Otherwise leaving sign-up returns to sign-in, which returns to
    // sign-up, and the exit appears not to work.
    for (const pathname of ["/login", "/signup", "/forgot-password"]) {
      expect(
        browseExitTarget(loc({ pathname: "/signup", state: { from: { pathname, search: "" } } }))
      ).toBe("/");
    }
  });

  it("ignores a search value that is not a query string", () => {
    expect(
      browseExitTarget(
        loc({
          pathname: "/login",
          state: { from: { pathname: "/places", search: "javascript:alert(1)" } },
        })
      )
    ).toBe("/places");
  });
});
