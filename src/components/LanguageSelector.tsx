import type { AppLanguage } from "../i18n/config";
import { useLanguage } from "../hooks/useLanguage";

type LanguageSelectorProps = {
  compact?: boolean;
  onChanged?: (language: AppLanguage) => void;
  onError?: (error: unknown) => void;
};

const options: AppLanguage[] = ["en", "zh"];

export function LanguageSelector({
  compact = false,
  onChanged,
  onError,
}: LanguageSelectorProps) {
  const { language, setLanguage, t } = useLanguage();

  return (
    <div
      className={`inline-flex items-center rounded-full border border-slate-200 bg-white p-1 shadow-sm dark:border-slate-700 dark:bg-slate-900 ${
        compact ? "gap-1" : "gap-1.5"
      }`}
    >
      {options.map((option) => {
        const isActive = language === option;
        const label =
          option === "zh" ? t("language.chinese") : t("language.english");

        return (
          <button
            key={option}
            type="button"
            onClick={() => {
              void setLanguage(option)
                .then(() => {
                  onChanged?.(option);
                })
                .catch((error) => {
                  onError?.(error);
                });
            }}
            className={`rounded-full px-3 py-1.5 font-semibold transition-all duration-200 ${
              compact ? "text-xs" : "text-sm"
            } ${
              isActive
                ? "bg-gradient-to-r from-purple-500 to-pink-500 text-white shadow-[0_10px_20px_-12px_rgba(168,85,247,0.8)]"
                : "text-slate-500 hover:bg-slate-100 hover:text-slate-700 dark:text-slate-300 dark:hover:bg-slate-800 dark:hover:text-white"
            }`}
          >
            {label}
          </button>
        );
      })}
    </div>
  );
}
