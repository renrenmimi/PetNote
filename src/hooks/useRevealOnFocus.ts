import { useEffect, type RefObject } from "react";

import { onKeyboardSettled } from "../utils/keyboard";

/**
 * Keeps the field a person is typing in visible above the keyboard.
 *
 * One behaviour for every surface that takes text. It used to exist only
 * inside AuthShell, so the same action — focus a field near the bottom of the
 * screen — worked on the login form and did nothing on Create or
 * EditProfile.
 *
 * Two things trigger a reveal, and both are needed:
 *
 *   - the keyboard's geometry changed, which covers it opening, closing, and
 *     growing later when a candidate bar or an autofill bar appears;
 *   - focus moved, which covers stepping from one field to the next while the
 *     keyboard is already up — no viewport change happens then, so the first
 *     trigger never fires.
 *
 * It is deliberately idempotent: it measures, and scrolls by the difference
 * or not at all. Where the document itself scrolls, WebKit usually reveals
 * the focused element on its own, and this then computes a delta of zero and
 * does nothing rather than adding a second competing scroll.
 */

/** Clears the field, its label, and any frosted edge above the keyboard. */
const MARGIN_PX = 72;

/**
 * @param scrollerRef The element that scrolls, when it is not the document.
 *   AuthShell is `position: fixed` with an inner scroller, so the document
 *   has nothing to scroll and WebKit cannot help; pages built on
 *   `min-h-screen` scroll the document and should pass nothing.
 */
export function useRevealOnFocus(
  scrollerRef?: RefObject<HTMLElement | null>
): void {
  useEffect(() => {
    const scope = (): HTMLElement | null =>
      scrollerRef ? scrollerRef.current : document.body;

    const focusedInScope = (): HTMLElement | null => {
      const container = scope();
      if (!container) return null;
      const active = document.activeElement;
      if (!(active instanceof HTMLElement)) return null;
      // `isConnected` as well as `contains`: a field can be removed from the
      // document while a reveal is pending — the reset page swaps its email
      // step for its code step — and a detached element measures as all
      // zeroes, which reads as "far above the fold" and would throw the page
      // upwards for no reason.
      if (!active.isConnected || !container.contains(active)) return null;
      return active;
    };

    const reveal = () => {
      const field = focusedInScope()?.getBoundingClientRect();
      if (!field) return;

      const scroller = scrollerRef?.current ?? null;
      // The visible band, and what to scroll. For an inner scroller that is
      // the element's own box; for the document it is the layout viewport,
      // which `KeyboardResize.Native` has already shrunk to the space above
      // the keyboard.
      const viewTop = scroller ? scroller.getBoundingClientRect().top : 0;
      const viewBottom = scroller
        ? scroller.getBoundingClientRect().bottom
        : window.innerHeight;

      const belowBy = field.bottom - (viewBottom - MARGIN_PX);
      const aboveBy = viewTop + MARGIN_PX - field.top;
      const delta = belowBy > 0 ? belowBy : aboveBy > 0 ? -aboveBy : 0;
      if (delta === 0) return;

      const smooth = !window.matchMedia("(prefers-reduced-motion: reduce)")
        .matches;
      const behavior = smooth ? "smooth" : "auto";
      if (scroller) scroller.scrollBy({ top: delta, behavior });
      else window.scrollBy({ top: delta, behavior });
    };

    let last = { visible: false, height: -1 };
    const stopKeyboard = onKeyboardSettled((geometry) => {
      /*
       * A layout change always counts, even when the numbers look unchanged.
       * `window.resize` is the only signal some keyboard frame changes
       * produce and it carries no height, so "same height as last time" is
       * not evidence that nothing moved — and treating it as evidence is how
       * the late candidate-bar resize gets dropped.
       *
       * A viewport-only report is filtered on its values, because in a
       * browser those also arrive while scrolling, and revealing then would
       * drag the page back under someone who scrolled away mid-sentence.
       */
      if (geometry.reason === "viewport") {
        if (
          geometry.visible === last.visible &&
          geometry.height === last.height
        )
          return;
      }
      last = { visible: geometry.visible, height: geometry.height };
      reveal();
    });

    // Focus changes do not resize anything, so they need their own trigger.
    // A frame's grace, so the reveal measures the layout after React has
    // committed whatever the focus change rendered.
    let frame = 0;
    const onFocusIn = () => {
      if (!focusedInScope()) return;
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(reveal);
    };
    document.addEventListener("focusin", onFocusIn);

    return () => {
      cancelAnimationFrame(frame);
      document.removeEventListener("focusin", onFocusIn);
      stopKeyboard();
    };
  }, [scrollerRef]);
}
