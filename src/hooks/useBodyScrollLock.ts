import { useEffect } from "react";

/**
 * Holds the page still, and in place, while something covers it.
 *
 * `overflow: hidden` on its own is not enough on iOS: the page still
 * rubber-bands, and the scroll offset is gone when it comes back. Pinning the
 * body at a negative offset keeps the view exactly where it was and restores
 * it on release.
 *
 * **Reference counted**, because overlays nest. Long-pressing a post opens the
 * quick-action menu, and choosing Share from it opens the share sheet on top —
 * two locks at once. Without counting, the second lock reads `window.scrollY`
 * while the body is already pinned, records 0, and restores the page to the
 * top when it closes. The count also means the first overlay to close does not
 * release the page while the second is still covering it.
 *
 * Separated from useModalBehavior on purpose. A dialog also wants Escape and
 * focus restoration; a full-screen onboarding wants neither — Escape there
 * would mean "skip onboarding", which is the Skip button's decision. Sharing
 * only the part that is genuinely shared is the difference between reuse and
 * applying a hook because one exists.
 */

let lockCount = 0;
let lockedScrollY = 0;
let savedStyles: {
  position: string;
  top: string;
  left: string;
  right: string;
  width: string;
  overflow: string;
} | null = null;

function engage() {
  lockCount += 1;
  if (lockCount > 1) return;

  lockedScrollY = window.scrollY;
  const { body } = document;
  savedStyles = {
    position: body.style.position,
    top: body.style.top,
    left: body.style.left,
    right: body.style.right,
    width: body.style.width,
    overflow: body.style.overflow,
  };
  body.style.position = "fixed";
  body.style.top = `-${lockedScrollY}px`;
  body.style.left = "0";
  body.style.right = "0";
  body.style.width = "100%";
  body.style.overflow = "hidden";
}

function release() {
  lockCount = Math.max(0, lockCount - 1);
  if (lockCount > 0 || !savedStyles) return;

  const { body } = document;
  body.style.position = savedStyles.position;
  body.style.top = savedStyles.top;
  body.style.left = savedStyles.left;
  body.style.right = savedStyles.right;
  body.style.width = savedStyles.width;
  body.style.overflow = savedStyles.overflow;
  savedStyles = null;
  window.scrollTo(0, lockedScrollY);
}

export function useBodyScrollLock(active: boolean): void {
  useEffect(() => {
    if (!active) return;
    engage();
    return release;
  }, [active]);
}
