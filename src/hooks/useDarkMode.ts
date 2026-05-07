import { useCallback, useEffect, useMemo, useState } from "react";

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

  const toggle = useCallback(
    () => setMode((prev) => (prev === "dark" ? "light" : "dark")),
    []
  );

  // Stable reference so ThemeContext's value object only changes when one
  // of its actual fields changes — without this, every ThemeProvider
  // render created a new toggle/value pair and forced re-renders on every
  // useTheme() consumer (Settings page, etc.).
  return useMemo(
    () => ({
      isDark,
      mode,
      setMode,
      toggle,
    }),
    [isDark, mode, toggle]
  );
}
