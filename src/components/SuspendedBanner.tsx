import { useAuth } from "../hooks/useAuth";
import { useLanguage } from "../hooks/useLanguage";

export function SuspendedBanner() {
  const { isBanned } = useAuth();
  const { t } = useLanguage();

  if (!isBanned) return null;

  return (
    // sticky (in-flow) instead of fixed: the fixed banner sat on top of every
    // page's sticky header and hid its top bar for banned users.
    <div className="sticky inset-x-0 top-0 z-50 bg-red-500 px-4 py-2 text-center text-xs font-semibold text-white shadow-lg">
      {t("suspended.banner")}
    </div>
  );
}
