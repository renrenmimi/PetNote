import { useAuth } from "../hooks/useAuth";
import { useLanguage } from "../hooks/useLanguage";

export function SuspendedBanner() {
  const { isBanned } = useAuth();
  const { t } = useLanguage();

  if (!isBanned) return null;

  return (
    <div className="fixed inset-x-0 top-0 z-50 bg-red-500 px-4 py-2 text-center text-xs font-semibold text-white shadow-lg">
      {t("suspended.banner")}
    </div>
  );
}
