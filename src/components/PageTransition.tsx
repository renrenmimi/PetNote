import { useEffect, useState } from "react";

type PageTransitionProps = {
  children: React.ReactNode;
};

export default function PageTransition({ children }: PageTransitionProps) {
  const [show, setShow] = useState(false);

  useEffect(() => {
    const timer = window.setTimeout(() => setShow(true), 10);
    return () => window.clearTimeout(timer);
  }, []);

  return (
    <div
      // Steady state must carry NO translate utility: Tailwind v4 compiles
      // translate-x-0 to the standalone `translate: 0px 0px` property, and
      // any non-none translate makes this div the containing block for every
      // position:fixed modal rendered inside the page (CSS Transforms L2) —
      // dialogs then center against the document instead of the viewport.
      className={`transition-all duration-300 ease-out ${
        show ? "opacity-100" : "translate-x-4 opacity-0"
      }`}
    >
      {children}
    </div>
  );
}
