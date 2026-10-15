import { useEffect, useRef } from "react";

import { useBodyScrollLock } from "./useBodyScrollLock";

/**
 * The behaviour every dialog in this app owes the person using it.
 *
 * All eight modals were the same shape — a fixed overlay, a panel, a click
 * handler on the backdrop — and none of them did any of this:
 *
 * - **The page kept scrolling underneath.** Dragging anywhere outside the
 *   panel scrolled the feed behind it, and closing the modal left you
 *   somewhere else entirely.
 * - **Escape did nothing**, so a hardware keyboard could open a dialog it
 *   could not dismiss. (QuickActionMenu was the one exception.)
 * - **Focus stayed on the page behind**, so a screen reader kept reading the
 *   feed, and closing left focus on nothing rather than back on the control
 *   that opened it.
 *
 * A hook rather than a wrapper component: the panels differ in layout,
 * padding and animation, and forcing them through one shell would have meant
 * rewriting markup that is already fine.
 *
 * Returns the ref to put on the panel element.
 */
export function useModalBehavior({
  open,
  onClose,
}: {
  open: boolean;
  onClose: () => void;
}) {
  const panelRef = useRef<HTMLDivElement | null>(null);
  // Kept in a ref so the escape listener does not need re-binding when a
  // parent passes a fresh closure on every render.
  const onCloseRef = useRef(onClose);

  useEffect(() => {
    onCloseRef.current = onClose;
  }, [onClose]);

  // The scroll lock is shared with the full-screen onboarding, which wants
  // that and nothing else from this hook.
  useBodyScrollLock(open);

  useEffect(() => {
    if (!open) return;

    const previouslyFocused =
      document.activeElement instanceof HTMLElement
        ? document.activeElement
        : null;


    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        onCloseRef.current();
      }
    };
    document.addEventListener("keydown", handleKeyDown);

    // Move focus into the dialog so assistive technology follows it there.
    // The first focusable, or the panel itself when it holds only text.
    const focusTimer = window.setTimeout(() => {
      const panel = panelRef.current;
      if (!panel) return;
      const focusable = panel.querySelector<HTMLElement>(
        'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
      );
      (focusable ?? panel).focus({ preventScroll: true });
    }, 0);

    return () => {
      window.clearTimeout(focusTimer);
      document.removeEventListener("keydown", handleKeyDown);
      // Back to whatever opened the dialog, so the next Tab continues from
      // there instead of restarting at the top of the document.
      previouslyFocused?.focus({ preventScroll: true });
    };
  }, [open]);

  return panelRef;
}
