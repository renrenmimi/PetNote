import { useEffect, useRef } from "react";
import { useLocation } from "react-router-dom";

/**
 * Puts a list back where it was when you left it.
 *
 * Opening something from a list and coming back returned you to the top,
 * every time. That is only half a navigation: the other half is the position
 * you were reading at, which the app knew and threw away.
 *
 * Restoring it has to survive the list not being there yet. The page mounts
 * before its content does, so the target offset is usually taller than the
 * document at first paint; the restore therefore retries across a few frames
 * and gives up once the content has settled rather than fighting whatever the
 * person does next.
 *
 * `sessionStorage`, so it lasts a browsing session and no longer. Positions
 * are not worth persisting across launches, and stale ones would be worse
 * than none.
 *
 * Deliberately inert when arriving at a route for the first time in a
 * session — a fresh visit belongs at the top.
 */
const STORAGE_PREFIX = "petnote:scroll:";
/** Long enough for a cached list to render; short enough not to fight a scroll. */
const RESTORE_WINDOW_MS = 1200;

export function useScrollRestoration(key: string): void {
  const location = useLocation();
  const storageKey = `${STORAGE_PREFIX}${key}`;
  // The position is saved continuously rather than on unmount: React may
  // unmount after the browser has already scrolled to the top of the next
  // route, at which point there is nothing left to record.
  const latestScrollRef = useRef(0);

  useEffect(() => {
    const onScroll = () => {
      latestScrollRef.current = window.scrollY;
    };
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => {
      window.removeEventListener("scroll", onScroll);
      try {
        if (latestScrollRef.current > 0) {
          sessionStorage.setItem(storageKey, String(latestScrollRef.current));
        } else {
          sessionStorage.removeItem(storageKey);
        }
      } catch {
        // Private mode, or a full quota. A lost position is not worth an error.
      }
    };
  }, [storageKey]);

  useEffect(() => {
    let target = 0;
    try {
      target = Number(sessionStorage.getItem(storageKey) ?? 0);
    } catch {
      return;
    }
    if (!Number.isFinite(target) || target <= 0) return;

    let frame = 0;
    const startedAt = Date.now();
    const settle = () => {
      const reachable =
        document.documentElement.scrollHeight - window.innerHeight;
      if (reachable >= target) {
        window.scrollTo(0, target);
        return;
      }
      if (Date.now() - startedAt > RESTORE_WINDOW_MS) {
        // The list came back shorter than it was — a refresh, or content that
        // is gone. Go as far as it does go rather than leaving it at the top.
        window.scrollTo(0, Math.max(0, reachable));
        return;
      }
      frame = window.requestAnimationFrame(settle);
    };
    frame = window.requestAnimationFrame(settle);

    return () => window.cancelAnimationFrame(frame);
    // Keyed on the pathname so returning to the same list restores, while
    // moving to a different one does not.
  }, [storageKey, location.pathname]);
}
