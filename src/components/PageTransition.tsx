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
      className={`transition-all duration-300 ease-out ${
        show ? "translate-x-0 opacity-100" : "translate-x-4 opacity-0"
      }`}
    >
      {children}
    </div>
  );
}
