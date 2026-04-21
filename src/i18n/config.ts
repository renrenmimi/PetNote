export const SUPPORTED_LANGUAGES = ["en", "zh"] as const;

export type AppLanguage = (typeof SUPPORTED_LANGUAGES)[number];

export const DEFAULT_LANGUAGE: AppLanguage = "en";

const STORAGE_KEY = "petnote.language";

export function isAppLanguage(value: unknown): value is AppLanguage {
  return (
    typeof value === "string" &&
    SUPPORTED_LANGUAGES.includes(value as AppLanguage)
  );
}

export function getLanguageLocale(language: AppLanguage): string {
  return language === "zh" ? "zh-CN" : "en-US";
}

export function readStoredLanguage(): AppLanguage | null {
  if (typeof window === "undefined") return null;
  const value = window.localStorage.getItem(STORAGE_KEY);
  return isAppLanguage(value) ? value : null;
}

export function writeStoredLanguage(language: AppLanguage): void {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(STORAGE_KEY, language);
}

export function getPreferredLanguage(): AppLanguage {
  const stored = readStoredLanguage();
  if (stored) {
    return stored;
  }

  return DEFAULT_LANGUAGE;
}

export function getDocumentLanguage(): AppLanguage {
  if (
    typeof document !== "undefined" &&
    document.documentElement.lang.toLowerCase().startsWith("zh")
  ) {
    return "zh";
  }

  return DEFAULT_LANGUAGE;
}

export function isChineseLanguage(language: AppLanguage): boolean {
  return language === "zh";
}
