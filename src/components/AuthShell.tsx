import { useEffect, useRef, type ReactNode } from "react";

type AuthShellProps = {
  /** Tailwind gradient utilities for the page background. */
  gradient: string;
  children: ReactNode;
};

/**
 * Page frame for the three unauthenticated screens.
 *
 * The layout itself is in index.css (`.auth-shell` / `.auth-scroll` /
 * `.auth-card`); what lives here is the one behaviour CSS cannot express.
 *
 * WebKit scrolls a newly focused field into view by itself, but it parks it
 * flush against the bottom of the web view — which, with the keyboard plugin
 * resizing that view, is exactly the top of the keyboard. Measured in the
 * simulator: the focused password field sat half under the frosted edge with
 * its lower half cut off. `scroll-padding-bottom` on the scroller does not
 * change where WebKit puts it, so the field is moved here instead, after the
 * resize has settled.
 */
export function AuthShell({ gradient, children }: AuthShellProps) {
  const scrollRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    const scroller = scrollRef.current;
    if (!scroller) return;

    let timer = 0;

    const revealFocusedField = () => {
      const active = document.activeElement;
      if (!(active instanceof HTMLElement) || !scroller.contains(active)) {
        return;
      }
      window.clearTimeout(timer);
      // The web view is resized *after* focus, so measuring straight away
      // measures the box the keyboard is about to replace.
      timer = window.setTimeout(() => {
        const field = active.getBoundingClientRect();
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
    // Fires when the plugin shrinks the web view for the keyboard, and again
    // when it grows back — the second one re-centres a field that the
    // dismissal left stranded.
    window.addEventListener("resize", revealFocusedField);

    return () => {
      window.clearTimeout(timer);
      scroller.removeEventListener("focusin", revealFocusedField);
      window.removeEventListener("resize", revealFocusedField);
    };
  }, []);

  return (
    <main className={`auth-shell ${gradient}`}>
      <div className="auth-scroll" ref={scrollRef}>
        <div className="auth-card rounded-3xl bg-white p-8 shadow-2xl dark:bg-slate-900">
          {children}
        </div>
      </div>
    </main>
  );
}
