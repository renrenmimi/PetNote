import type { Location } from "react-router-dom";

/**
 * Getting somebody to the sign-in screen and back to what they were doing.
 *
 * Every "you need an account for this" entry point was writing its own
 * version of this, and most of them wrote `navigate("/login")` with nothing
 * else — so signing in from a post's comment box, or from a pet's Follow
 * button, landed on the feed and left the person to find the thing they were
 * looking at again. Login already knows how to consume a `from`; the callers
 * just were not giving it one.
 */

export type SignInReturnState = {
  from: { pathname: string; search: string };
};

/**
 * The state to pass with `navigate("/login", { state })` so that signing in
 * returns to this exact place, query string included.
 */
export function signInReturnState(location: Location): SignInReturnState {
  return {
    from: { pathname: location.pathname, search: location.search },
  };
}

/**
 * Where "leave this auth screen" should go.
 *
 * Deliberately not `history.back()`. An auth page is reachable by typing a
 * URL, by a link from outside the app, or as the first page of a cold start
 * on the phone — in all of which there is nothing behind it, so `back()` does
 * nothing at all and the button appears broken. It is also reachable *from* a
 * redirect, where `back()` would bounce straight into the thing that demanded
 * sign-in and be redirected back, which reads as the button not working
 * either.
 *
 * So: use the recorded origin if there is one and it is somewhere inside this
 * app, otherwise the public feed. `from` only ever holds a path, never a
 * full URL, and this checks that anyway — a value that arrived from anywhere
 * but our own `signInReturnState` must not be able to send somebody to
 * another site.
 */
export function browseExitTarget(location: Location): string {
  const from = (
    location.state as { from?: { pathname?: unknown; search?: unknown } } | null
  )?.from;
  const pathname = typeof from?.pathname === "string" ? from.pathname : "";
  const search = typeof from?.search === "string" ? from.search : "";

  // A single leading slash and no scheme or authority. "//evil.example" is a
  // protocol-relative URL that browsers treat as another origin, which is why
  // the second character is checked too.
  const isInternalPath =
    pathname.startsWith("/") &&
    !pathname.startsWith("//") &&
    !pathname.includes(":");

  // An auth screen is not somewhere to return to.
  const isAuthScreen = /^\/(login|signup|forgot-password)\b/.test(pathname);

  if (isInternalPath && !isAuthScreen) {
    return `${pathname}${search.startsWith("?") ? search : ""}`;
  }
  return "/";
}
