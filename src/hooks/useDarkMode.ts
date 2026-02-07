import { useEffect, useMemo, useState } from "react";

export type ThemeMode = "light" | "dark" | "system";

export function useDarkMode() {
  const [mode, setMode] = useState<ThemeMode>(() => {
    if (typeof window === "undefined") return "system";
    const saved = localStorage.getItem("themeMode");
    if (saved === "light" || saved === "dark" || saved === "system") {
      return saved;
    }
    return "system";
  });
  const [prefersDark, setPrefersDark] = useState(() =>
    typeof window !== "undefined"
      ? window.matchMedia("(prefers-color-scheme: dark)").matches
      : false
  );

  useEffect(() => {
    if (typeof window === "undefined") return;
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const handler = (event: MediaQueryListEvent) => setPrefersDark(event.matches);
    media.addEventListener("change", handler);
    return () => media.removeEventListener("change", handler);
  }, []);

  const isDark = useMemo(() => {
    if (mode === "system") return prefersDark;
    return mode === "dark";
  }, [mode, prefersDark]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    if (isDark) {
      document.documentElement.classList.add("dark");
    } else {
      document.documentElement.classList.remove("dark");
    }
    localStorage.setItem("themeMode", mode);
  }, [isDark, mode]);

  return {
    isDark,
    mode,
    setMode,
    toggle: () => setMode((prev) => (prev === "dark" ? "light" : "dark")),
  };
}
