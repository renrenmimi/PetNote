import { Link, useLocation, useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { useLanguage } from "../hooks/useLanguage";

type NavItem = {
  label: string;
  icon: string;
  path?: string;
  action?: () => void;
};

export function BottomNav() {
  const { user } = useAuth();
  const { t } = useLanguage();
  const location = useLocation();
  const navigate = useNavigate();

  const requireAuth = (path: string) => {
    if (!user) {
      // Pass the intended destination so Login can return the user there
      // (matches RequireAuth's state contract).
      navigate("/login", { state: { from: { pathname: path } } });
      return;
    }
    navigate(path);
  };

  const items: NavItem[] = [
    { label: t("nav.home"), icon: "🏠", path: "/" },
    { label: t("nav.places"), icon: "📍", path: "/places" },
    {
      label: t("nav.create"),
      icon: "+",
      action: () => requireAuth("/create"),
    },
    { label: t("nav.meetups"), icon: "🤝", path: "/meetups" },
    {
      label: t("nav.profile"),
      icon: "👤",
      path: "/profile",
      action: () => requireAuth("/profile"),
    },
  ];

  return (
    <nav
      className="fixed bottom-0 left-0 right-0 z-50 border-t border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-900"
      style={{ paddingBottom: "env(safe-area-inset-bottom, 0px)" }}
    >
      <div className="mx-auto flex h-14 w-full max-w-md items-center justify-around px-3">
        {items.map((item) => {
          const isActive = item.path
            ? location.pathname === item.path ||
              (item.path === "/profile" &&
                location.pathname.startsWith("/profile")) ||
              (item.path === "/meetups" &&
                location.pathname.startsWith("/meetups")) ||
              (item.path === "/places" &&
                location.pathname.startsWith("/places"))
            : false;

          if (item.action) {
            return (
              <button
                key={item.label}
                type="button"
                onClick={item.action}
                className={`flex flex-1 flex-col items-center gap-1 text-xs transition-all duration-200 active:scale-95 ${
                  isActive ? "text-purple-600" : "text-slate-500 dark:text-slate-400"
                }`}
              >
                {item.label === t("nav.create") ? (
                  <span className="flex h-10 w-10 items-center justify-center rounded-full bg-gradient-to-r from-purple-500 to-pink-500 text-xl font-semibold text-white shadow-[0_12px_25px_-15px_rgba(168,85,247,0.8)] transition-all duration-200 hover:scale-105">
                    {item.icon}
                  </span>
                ) : (
                  <span className="text-xl">{item.icon}</span>
                )}
                {item.label}
              </button>
            );
          }

          return (
            <Link
              key={item.label}
              to={item.path || "/"}
              className={`flex flex-1 flex-col items-center gap-1 text-xs transition-all duration-200 active:scale-95 ${
                isActive ? "text-purple-600" : "text-slate-500 dark:text-slate-400"
              }`}
            >
              <span className="text-xl">{item.icon}</span>
              {item.label}
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
