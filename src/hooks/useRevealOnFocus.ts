import { useEffect, type RefObject } from "react";

import { onKeyboardSettled } from "../utils/keyboard";

/**
 * Keeps the field a person is typing in visible above the keyboard.
 *
 * One behaviour for every surface that takes text. It used to exist only
 * inside AuthShell, so the same action — focus a field near the bottom of the
 * screen — was handled there and left to WebKit on Create and EditProfile.
 * Those pages scroll the document, where WebKit does reveal the focused
 * element, so "no code" is not the same as "broken"; what it is, is
 * unspecified.
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
 *
 * It also checks its own work, because `scrollBy(delta)` is a request and not
 * a promise that the field moves by `delta`. Measured on the search page:
 * asked for 413 px, the field moved 398, and the 15 px never came back. The
 * field there sits in a `position: sticky` bar, so part of its position comes
 * from the sticky offset rather than from the scroll; hitting the end of the
 * document clamps the same way. So each reveal waits for the scroll to stop
 * and measures again, and corrects at most twice — enough for the residual,
 * and bounded so that a field which genuinely cannot be moved any further
 * does not start a loop.
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

    /** rAF handle for the settle watcher, so cleanup can cancel it. */
    let watch = 0;

    /**
     * Runs `fn` once the scroll position has stopped moving.
     *
     * Three identical frames rather than a delay, because a smooth scroll's
     * duration is the engine's business and not a number worth guessing. The
     * frame cap is a guard against a page that scrolls continuously for some
     * other reason — it gives up rather than never running.
     */
    const afterScrollSettles = (fn: () => void) => {
      const read = () =>
        scrollerRef?.current ? scrollerRef.current.scrollTop : window.scrollY;
      let last = Number.NaN;
      let still = 0;
      let frames = 0;
      const tick = () => {
        const now = read();
        if (now === last) still += 1;
        else {
          still = 0;
          last = now;
        }
        frames += 1;
        if (still >= 3 || frames > 60) {
          fn();
          return;
        }
        watch = requestAnimationFrame(tick);
      };
      cancelAnimationFrame(watch);
      watch = requestAnimationFrame(tick);
    };

    const reveal = (pass = 0, previousDelta = Number.POSITIVE_INFINITY) => {
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
      // Stop if the last attempt bought nothing. A field pinned by sticky
      // positioning, or a document already scrolled to its end, cannot be
      // moved further and asking again would only repeat.
      if (Math.abs(delta) >= Math.abs(previousDelta)) return;

      const smooth = !window.matchMedia("(prefers-reduced-motion: reduce)")
        .matches;
      const behavior = smooth ? "smooth" : "auto";
      if (scroller) scroller.scrollBy({ top: delta, behavior });
      else window.scrollBy({ top: delta, behavior });

      if (pass >= 2) return;
      afterScrollSettles(() => reveal(pass + 1, delta));
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
      frame = requestAnimationFrame(() => reveal());
    };
    document.addEventListener("focusin", onFocusIn);

    return () => {
      cancelAnimationFrame(frame);
      cancelAnimationFrame(watch);
      document.removeEventListener("focusin", onFocusIn);
      stopKeyboard();
    };
  }, [scrollerRef]);
}
