import { useEffect } from "react";

/**
 * Holds the page still, and in place, while something covers it.
 *
 * `overflow: hidden` on its own is not enough on iOS: the page still
 * rubber-bands, and the scroll offset is gone when it comes back. Pinning the
 * body at a negative offset keeps the view exactly where it was and restores
 * it on release.
 *
 * Separated from useModalBehavior on purpose. A dialog also wants Escape and
 * focus restoration; a full-screen onboarding wants neither — Escape there
 * would mean "skip onboarding", which is a decision that belongs to the Skip
 * button, and there is nothing behind it to restore focus to. Sharing only
 * the part that is genuinely shared is the difference between reuse and
 * applying a hook because one exists.
 */
export function useBodyScrollLock(active: boolean): void {
  useEffect(() => {
    if (!active) return;

    const scrollY = window.scrollY;
    const { body } = document;
    const previous = {
      position: body.style.position,
      top: body.style.top,
      left: body.style.left,
      right: body.style.right,
      width: body.style.width,
      overflow: body.style.overflow,
    };
    body.style.position = "fixed";
    body.style.top = `-${scrollY}px`;
    body.style.left = "0";
    body.style.right = "0";
    body.style.width = "100%";
    body.style.overflow = "hidden";

    return () => {
      body.style.position = previous.position;
      body.style.top = previous.top;
      body.style.left = previous.left;
      body.style.right = previous.right;
      body.style.width = previous.width;
      body.style.overflow = previous.overflow;
      window.scrollTo(0, scrollY);
    };
  }, [active]);
}
