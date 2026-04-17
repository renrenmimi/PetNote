import {
  createContext,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { useAuth } from "../hooks/useAuth";
import {
  type TranslationKey,
  type TranslationValues,
  formatMessage,
  messages,
} from "../i18n/messages";
import {
  getLanguageLocale,
  getPreferredLanguage,
  isAppLanguage,
  writeStoredLanguage,
  type AppLanguage,
} from "../i18n/config";
import { getSettings, updateSettings } from "../services/settings";

type LanguageContextValue = {
  language: AppLanguage;
  locale: string;
  setLanguage: (language: AppLanguage) => Promise<void>;
  t: (key: TranslationKey, values?: TranslationValues) => string;
};

// eslint-disable-next-line react-refresh/only-export-components
export const LanguageContext = createContext<LanguageContextValue | null>(null);

export function LanguageProvider({ children }: { children: ReactNode }) {
  const { user } = useAuth();
  const [language, setLanguageState] = useState<AppLanguage>(() =>
    getPreferredLanguage()
  );
  const languageRef = useRef(language);

  useEffect(() => {
    languageRef.current = language;
    document.documentElement.lang = getLanguageLocale(language);
  }, [language]);

  const persistLanguage = useCallback((nextLanguage: AppLanguage) => {
    setLanguageState(nextLanguage);
    writeStoredLanguage(nextLanguage);
  }, []);

  useEffect(() => {
    let cancelled = false;

    if (!user) {
      return;
    }

    const syncLanguage = async () => {
      try {
        const settings = await getSettings(user.uid);
        if (cancelled) return;

        if (isAppLanguage(settings.language)) {
          if (settings.language !== languageRef.current) {
            persistLanguage(settings.language);
          }
          return;
        }

        await updateSettings(user.uid, {
          language: languageRef.current,
        });
      } catch (error) {
        console.warn("Failed to sync language preference:", error);
      }
    };

    void syncLanguage();

    return () => {
      cancelled = true;
    };
  }, [persistLanguage, user]);

  const setLanguage = useCallback(
    async (nextLanguage: AppLanguage) => {
      if (nextLanguage === languageRef.current) {
        return;
      }

      const previousLanguage = languageRef.current;
      persistLanguage(nextLanguage);

      if (!user) {
        return;
      }

      try {
        await updateSettings(user.uid, { language: nextLanguage });
      } catch (error) {
        persistLanguage(previousLanguage);
        throw error;
      }
    },
    [persistLanguage, user]
  );

  const t = useCallback(
    (key: TranslationKey, values?: TranslationValues) => {
      const template = messages[language][key] ?? messages.en[key] ?? key;
      return formatMessage(template, values);
    },
    [language]
  );

  const value = useMemo(
    () => ({
      language,
      locale: getLanguageLocale(language),
      setLanguage,
      t,
    }),
    [language, setLanguage, t]
  );

  return (
    <LanguageContext.Provider value={value}>
      {children}
    </LanguageContext.Provider>
  );
}
