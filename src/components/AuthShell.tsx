import { useEffect, useRef, type ReactNode } from "react";
import { Link, useLocation } from "react-router-dom";
import { ChevronLeft } from "lucide-react";

import PawIcon from "./PawIcon";
import { browseExitTarget } from "../utils/authNavigation";

type AuthShellProps = {
  /** What this screen is for. The only heading on it. */
  title: string;
  subtitle?: string;
  /** "Back to browsing", already translated by the caller. */
  exitLabel: string;
  /** Top-right slot — the language selector. */
  topRight?: ReactNode;
  children: ReactNode;
};

/**
 * Page frame for the three unauthenticated screens.
 *
 * **One shell, one background.** Login was purple-to-pink, sign-up was
 * sky-to-teal-to-emerald, and the reset screen was a short card floating in
 * another purple gradient — three colour systems across three screens of the
 * same flow, so moving between them read as moving between products. The
 * background is now the brand gradient, once, here.
 *
 * **One heading.** Each page used to stack five things before its first
 * field: a language selector, a paw, "PetNote", a coloured badge pill whose
 * colour was itself different per page, a heading, and a tagline. The brand
 * appears once and small; the badges and taglines are gone. What is left is
 * the title of the screen and, if it needs one, a sentence.
 *
 * **A way out that works.** None of the three had one. `history.back()` is
 * not it: an auth screen is reachable by typing a URL, from an outside link,
 * or as the first page of a cold start, and in all of those there is nothing
 * behind it. See `browseExitTarget`.
 *
 * The layout itself is in index.css (`.auth-shell` / `.auth-scroll` /
 * `.auth-card`), including the soft top and bottom transitions, which stay:
 * they are there so a scrolled card fades instead of being cut, and they are
 * behind the content rather than over it. What lives here is the one
 * behaviour CSS cannot express.
 *
 * WebKit scrolls a newly focused field into view by itself, but it parks it
 * flush against the bottom of the web view — which, with the keyboard plugin
 * resizing that view, is exactly the top of the keyboard. Measured in the
 * simulator: the focused password field sat half under the frosted edge with
 * its lower half cut off. `scroll-padding-bottom` on the scroller does not
 * change where WebKit puts it, so the field is moved here instead, after the
 * resize has settled.
 */
export function AuthShell({
  title,
  subtitle,
  exitLabel,
  topRight,
  children,
}: AuthShellProps) {
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const location = useLocation();

  useEffect(() => {
    const scroller = scrollRef.current;
    if (!scroller) return;

    let timer = 0;

    const focusedFieldInside = (): HTMLElement | null => {
      const active = document.activeElement;
      if (!(active instanceof HTMLElement)) return null;
      // isConnected as well as contains: a field can be removed from the
      // document while the timer is pending — the reset page swaps its email
      // step for its code step — and a detached element measures as all
      // zeroes, which reads as "far above the fold" and would throw the page
      // upwards for no reason.
      if (!active.isConnected || !scroller.contains(active)) return null;
      return active;
    };

    const revealFocusedField = () => {
      if (!focusedFieldInside()) return;
      window.clearTimeout(timer);
      // The web view is resized *after* focus, so measuring straight away
      // measures the box the keyboard is about to replace.
      timer = window.setTimeout(() => {
        // Re-read rather than trusting what was focused when this was
        // scheduled. Focus may have been given up in the meantime, and
        // scrolling to a field nobody is in is worse than doing nothing.
        const current = focusedFieldInside();
        if (!current) return;
        const field = current.getBoundingClientRect();
        const view = scroller.getBoundingClientRect();
        // Enough to clear the frosted strip, the field's own label, and to
        // leave the control looking deliberate rather than wedged.
        const margin = 72;
        const belowBy = field.bottom - (view.bottom - margin);
        const aboveBy = view.top + margin - field.top;
        const delta = belowBy > 0 ? belowBy : aboveBy > 0 ? -aboveBy : 0;
        if (delta === 0) return;
        const smooth = !window.matchMedia("(prefers-reduced-motion: reduce)")
          .matches;
        scroller.scrollBy({ top: delta, behavior: smooth ? "smooth" : "auto" });
      }, 320);
    };

    scroller.addEventListener("focusin", revealFocusedField);
    // Fires when the plugin shrinks the web view for the keyboard. It also
    // fires when the view grows back, but nothing is focused by then, so that
    // one returns early — which is the wanted behaviour: dismissing the
    // keyboard should leave the page where the person left it.
    window.addEventListener("resize", revealFocusedField);

    return () => {
      window.clearTimeout(timer);
      scroller.removeEventListener("focusin", revealFocusedField);
      window.removeEventListener("resize", revealFocusedField);
    };
  }, []);

  return (
    <main className="auth-shell bg-gradient-to-br from-purple-500 to-pink-500">
      <div className="auth-scroll" ref={scrollRef}>
        <div className="auth-card rounded-3xl bg-white p-6 shadow-2xl dark:bg-slate-900">
          <div className="mb-5 flex items-center justify-between gap-2">
            <Link
              to={browseExitTarget(location)}
              className="tap-target -ml-1 flex min-h-9 items-center gap-1 rounded-lg pr-2 text-sm font-medium text-slate-500 transition-colors hover:text-purple-600 dark:text-slate-400"
            >
              <ChevronLeft size={18} strokeWidth={2} aria-hidden="true" />
              {exitLabel}
            </Link>
            {topRight}
          </div>

          <div className="mb-6">
            <div className="flex items-center gap-2">
              <PawIcon size={24} />
              <span className="text-sm font-semibold tracking-tight text-slate-900 dark:text-white">
                PetNote
              </span>
            </div>
            <h1 className="mt-4 text-2xl font-semibold tracking-tight text-slate-900 dark:text-white">
              {title}
            </h1>
            {subtitle ? (
              <p className="mt-1.5 text-sm text-slate-500 dark:text-slate-300">
                {subtitle}
              </p>
            ) : null}
          </div>

          {children}
        </div>
      </div>
    </main>
  );
}
