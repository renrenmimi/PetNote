import { Capacitor } from "@capacitor/core";
import { Keyboard } from "@capacitor/keyboard";

/**
 * One place that knows when the keyboard moved.
 *
 * Each surface used to handle this separately, and differently: AuthShell
 * measured a fixed 320 ms after `focusin`; CommentSection compensated with
 * `visualViewport`, which `KeyboardResize.Native` degrades to a no-op; Create
 * and EditProfile relied on WebKit alone. That divergence is the reason for
 * one module — not, by itself, evidence of the reported fault. Which of these
 * paths produces the occlusion seen on the device is a separate question, and
 * one only the device can answer.
 *
 * What can be said about the fixed delay without a device: it has no way to
 * see a change that arrives after it. A Chinese input method raises its
 * candidate bar *after* the keyboard has appeared, and password autofill adds
 * its own bar; both change the keyboard's height hundreds of milliseconds
 * later, by which time a timer started at `focusin` has fired and will not
 * fire again for that focus.
 *
 * This module is still time-based — a 50 ms trailing debounce, below — but
 * the timer measures the gap *since the last change* rather than counting
 * down from an event. Every new change restarts it, so a late change is
 * another change rather than something arriving after the deadline.
 */

export type KeyboardGeometry = {
  visible: boolean;
  /** Keyboard height in CSS pixels. 0 when hidden, and 0 when unknown. */
  height: number;
  /**
   * Why this report happened.
   *
   * `"layout"` — the web view was resized, or the plugin announced a
   * keyboard. Something that changes where things are on screen, so a
   * caller that keeps a field visible must act even if the numbers below
   * look the same as last time. They can: `window.resize` carries no
   * height, so two genuinely different keyboard heights both arrive as
   * zero, and comparing values would silently drop the second one — which
   * is precisely the late candidate-bar change this module exists to catch.
   *
   * `"viewport"` — only the visual viewport moved, which in a browser also
   * happens while scrolling. Acting on those would drag the page back under
   * someone who scrolled away mid-sentence.
   */
  reason: "layout" | "viewport";
};

/**
 * Trailing debounce: how quiet the viewport has to go before a report.
 *
 * Not a guess at how long the keyboard takes to animate. It is the gap that
 * stands in for "no further change is coming", and each change restarts it,
 * so the total wait is unbounded while changes keep arriving and is 50 ms
 * after the last one. The cost of it being too short is a report against a
 * mid-animation layout, followed by another once things stop; the cost of too
 * long is a visible delay before the field moves.
 */
const SETTLE_MS = 50;

type Listener = (geometry: KeyboardGeometry) => void;

let geometry: KeyboardGeometry = {
  visible: false,
  height: 0,
  reason: "layout",
};
const listeners = new Set<Listener>();
let teardown: (() => void) | null = null;
let settleTimer = 0;
/** The strongest reason seen since the last emit. `layout` outranks it. */
let pendingReason: "layout" | "viewport" = "viewport";

function emitSettled(reason: "layout" | "viewport") {
  if (reason === "layout") pendingReason = "layout";
  window.clearTimeout(settleTimer);
  settleTimer = window.setTimeout(() => {
    const settled: KeyboardGeometry = { ...geometry, reason: pendingReason };
    geometry = settled;
    pendingReason = "viewport";
    for (const listener of [...listeners]) listener(settled);
  }, SETTLE_MS);
}

function note(
  next: Partial<KeyboardGeometry>,
  reason: "layout" | "viewport"
) {
  geometry = { ...geometry, ...next };
  emitSettled(reason);
}

/**
 * Starts the platform subscriptions on the first listener and stops them with
 * the last, so a page that never takes input pays nothing.
 */
function start(): () => void {
  const stops: Array<() => void> = [];

  // `window.resize` is the signal that actually catches everything. Under
  // `KeyboardResize.Native` the plugin resizes the web view for any keyboard
  // frame change, including the ones it does not report as a show or a hide —
  // a candidate bar appearing, an autofill bar, a hardware keyboard being
  // paired mid-session. The plugin events below are still worth having,
  // because they carry the height and they say whether a keyboard is
  // involved at all, but they are not relied on for completeness.
  const onResize = () => emitSettled("layout");
  window.addEventListener("resize", onResize);
  stops.push(() => window.removeEventListener("resize", onResize));

  if (Capacitor.isNativePlatform()) {
    let cancelled = false;
    // Registered one name at a time rather than over a list. The plugin
    // declares `addListener` as four overloads, each accepting one literal
    // event name, so a union argument matches none of them — `tsc -b` says
    // so even though `tsc --noEmit` on the app's own config did not.
    const keep = (pending: Promise<{ remove: () => unknown }>) => {
      void pending.then((handle) => {
        if (cancelled) void handle.remove();
        else stops.push(() => void handle.remove());
      });
    };
    const shown = (info: { keyboardHeight: number }) => {
      note({ visible: true, height: info.keyboardHeight }, "layout");
    };
    const hidden = () => {
      note({ visible: false, height: 0 }, "layout");
    };
    keep(Keyboard.addListener("keyboardWillShow", shown));
    // The one that matters for a CJK input method: `didShow` reports the
    // height the keyboard actually ended up at.
    keep(Keyboard.addListener("keyboardDidShow", shown));
    keep(Keyboard.addListener("keyboardWillHide", hidden));
    keep(Keyboard.addListener("keyboardDidHide", hidden));
    stops.push(() => {
      cancelled = true;
    });
  } else if (window.visualViewport) {
    // A browser exposes no keyboard events, only the viewport shrinking.
    const viewport = window.visualViewport;
    const read = () => {
      const covered = Math.max(
        0,
        window.innerHeight - viewport.height - viewport.offsetTop
      );
      // A threshold rather than `> 0`: a browser's own toolbars move the
      // visual viewport by a few pixels while scrolling, and calling that a
      // keyboard would scroll the page under someone's finger.
      note({ visible: covered > 120, height: covered }, "viewport");
    };
    viewport.addEventListener("resize", read);
    viewport.addEventListener("scroll", read);
    stops.push(() => {
      viewport.removeEventListener("resize", read);
      viewport.removeEventListener("scroll", read);
    });
    read();
  }

  return () => {
    window.clearTimeout(settleTimer);
    for (const stop of stops) stop();
  };
}

/**
 * Calls back once the viewport has stopped changing, with the keyboard
 * geometry as last reported.
 *
 * Not "when the keyboard opens": a caller that wants to keep something
 * visible has to run when it closes too, and when it changes height without
 * opening or closing.
 */
export function onKeyboardSettled(listener: Listener): () => void {
  listeners.add(listener);
  if (!teardown) teardown = start();
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0 && teardown) {
      teardown();
      teardown = null;
      geometry = { visible: false, height: 0, reason: "layout" };
      pendingReason = "viewport";
    }
  };
}

/** Last known geometry, for a caller that needs it outside a callback. */
export function keyboardGeometry(): KeyboardGeometry {
  return geometry;
}

/**
 * The colour iOS paints where the web view used to be.
 *
 * `Keyboard.autoBackdropColor: 'dom'` re-reads the body background every time
 * the keyboard is about to show, and `html, body` carry `--app-backdrop`, so
 * setting that variable is how a surface whose own background differs from
 * the document's keeps the strip under the keyboard from being a slab of the
 * wrong colour. Inline on the root element, because `.dark` sets the same
 * variable by class and an inline value has to win over it.
 *
 * Returns the restore function rather than remembering a "previous" value:
 * removing the inline property puts the cascade back in charge, which is
 * what dark mode needs to keep working after the surface unmounts.
 */
export function setKeyboardBackdrop(color: string): () => void {
  const root = document.documentElement;
  root.style.setProperty("--app-backdrop", color);
  return () => root.style.removeProperty("--app-backdrop");
}
