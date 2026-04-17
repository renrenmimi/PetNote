import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { useHasUnreadNotifications } from "../hooks/useHasUnreadNotifications";
import { useLanguage } from "../hooks/useLanguage";
import PawIcon from "./PawIcon";
import Avatar from "./Avatar";

export function Navbar() {
  const { user } = useAuth();
  const { t } = useLanguage();
  const { hasUnread } = useHasUnreadNotifications(user?.uid ?? null);
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const handleScroll = () => {
      setScrolled(window.scrollY > 4);
    };
    handleScroll();
    window.addEventListener("scroll", handleScroll, { passive: true });
    return () => window.removeEventListener("scroll", handleScroll);
  }, []);

  return (
    <header
      className={`sticky top-0 z-20 border-b border-slate-200 bg-white/80 backdrop-blur transition-all duration-200 dark:border-slate-800 dark:bg-slate-900/80 ${
        scrolled
          ? "shadow-[0_10px_30px_-20px_rgba(15,23,42,0.35)]"
          : "shadow-none"
      }`}
    >
      <div className="mx-auto flex w-full max-w-md items-center justify-between px-4 py-3">
        <Link
          to="/"
          className="flex items-center gap-2 text-lg font-semibold text-slate-900 transition-transform duration-200 hover:scale-[1.03] dark:text-white"
        >
          <PawIcon size={28} />
          PetNote
        </Link>

        <div className="flex items-center gap-3">
          <Link
            to="/search"
            className="text-xl text-slate-500 transition-all duration-200 hover:scale-105 hover:text-purple-500 dark:text-slate-300"
            aria-label={t("nav.search")}
          >
            🔍
          </Link>
          <Link
            to="/notifications"
            className="relative text-xl text-slate-500 transition-all duration-200 hover:scale-105 hover:text-purple-500 dark:text-slate-300"
            aria-label={t("nav.notifications")}
          >
            🔔
            {hasUnread ? (
              <span className="absolute -right-1 -top-1 h-2.5 w-2.5 rounded-full bg-red-500" />
            ) : null}
          </Link>
          {!user ? (
            <Link
              to="/login"
              className="rounded-full border border-purple-200 px-3 py-1.5 text-sm font-semibold text-purple-600 transition-all duration-200 hover:scale-105 hover:border-purple-300 hover:bg-purple-50"
            >
              {t("nav.login")}
            </Link>
          ) : (
            <Link to="/profile" aria-label={t("nav.profile")}>
              <Avatar
                src={user.photoURL || undefined}
                alt={user.displayName || t("common.user")}
                userId={user.uid}
                size={36}
                className="h-9 w-9"
              />
            </Link>
          )}
        </div>
      </div>
    </header>
  );
}
