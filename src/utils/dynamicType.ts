/**
 * Let the app follow the text size the person chose in iOS Settings.
 *
 * Measured first, because the obvious assumption is wrong in both
 * directions. iOS *does* deliver the setting to WebKit: a span with
 * `font: -apple-system-body` computes to 17px at the default and 53px at
 * Accessibility XXXL. But the app never asked — every size is a Tailwind
 * `rem` against a root that WebKit pins at 16px, and `-webkit-text-size-adjust`
 * is 100%. So at the largest accessibility size the layout was pixel-identical
 * to the smallest, and "nothing overflowed" meant "nothing responded", not
 * "this adapts".
 *
 * Reading the keyword font and scaling the root is the only route: there is no
 * media query for text size, and `font: -apple-system-body` on `html` itself
 * would hand 53px straight to every rem in the app — a 3.3x layout.
 *
 * Deliberately clamped, and deliberately asymmetric:
 *
 * - **Never below 16px.** A browser that does not know the keyword resolves it
 *   to something arbitrary (desktop Safari says 13px; Chrome leaves the
 *   inherited 16px), and shrinking the whole app on a misread would be worse
 *   than ignoring the setting. The floor makes an unsupported keyword a no-op.
 * - **Never above 19px.** Tailwind spacing is rem too, so the root scales
 *   padding and gaps along with type. 1.19x is what a 375pt screen absorbs
 *   without horizontal overflow — verified with the geometry probe at
 *   Accessibility XXXL on an iPhone SE, `scrollWidth` 375 against `clientWidth`
 *   375. It does not deliver the full accessibility range, and does not claim
 *   to; it delivers the part that the existing layout can honour.
 *
 * At the default setting the computation lands on exactly 16px, so for anyone
 * who has not changed their text size this function does nothing at all.
 *
 * Re-read on resume: iOS text size can be changed while the app is in the
 * background, and a WebView that never looks again would keep the old scale
 * until the process restarted.
 */

const BASE_PX = 16;
/** `-apple-system-body` at the default iOS text size. */
const SYSTEM_BODY_DEFAULT_PX = 17;
const MAX_PX = 19;

function measureSystemBodyPx(): number | null {
  const probe = document.createElement("span");
  // Off-screen rather than `display: none`, which would not compute a size.
  probe.setAttribute(
    "style",
    "position:absolute;left:-9999px;top:0;visibility:hidden;font:-apple-system-body"
  );
  probe.textContent = "M";
  document.body.appendChild(probe);
  const px = Number.parseFloat(window.getComputedStyle(probe).fontSize);
  probe.remove();
  return Number.isFinite(px) && px > 0 ? px : null;
}

export function applyDynamicType(): void {
  const systemBodyPx = measureSystemBodyPx();
  if (systemBodyPx === null) return;

  const scaled = BASE_PX * (systemBodyPx / SYSTEM_BODY_DEFAULT_PX);
  const clamped = Math.min(Math.max(scaled, BASE_PX), MAX_PX);

  // Rounded to a tenth: sub-pixel roots make rem-derived borders and
  // hairlines land off the device pixel grid at 2x and 3x.
  const next = `${Math.round(clamped * 10) / 10}px`;
  if (document.documentElement.style.fontSize !== next) {
    document.documentElement.style.fontSize = next;
  }
}

export function watchDynamicType(): () => void {
  applyDynamicType();

  const onVisible = () => {
    if (document.visibilityState === "visible") applyDynamicType();
  };
  document.addEventListener("visibilitychange", onVisible);
  // Capacitor resumes without a visibilitychange in some iOS versions, so the
  // window's own focus event backs it up. Both are idempotent.
  window.addEventListener("focus", applyDynamicType);

  return () => {
    document.removeEventListener("visibilitychange", onVisible);
    window.removeEventListener("focus", applyDynamicType);
  };
}
