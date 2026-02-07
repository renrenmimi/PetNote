import { Link, useLocation, useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { useNotifications } from "../hooks/useNotifications";

type NavItem = {
  label: string;
  icon: string;
  path?: string;
  action?: () => void;
};

export function BottomNav() {
  const { user } = useAuth();
  const location = useLocation();
  const navigate = useNavigate();
  const { unreadCount } = useNotifications(user?.uid ?? null);

  const requireAuth = (path: string) => {
    if (!user) {
      navigate("/login");
      return;
    }
    navigate(path);
  };

  const items: NavItem[] = [
    { label: "Home", icon: "🏠", path: "/" },
    { label: "Search", icon: "🔍", path: "/search" },
    {
      label: "Create",
      icon: "+",
      action: () => requireAuth("/create"),
    },
    { label: "Notifications", icon: "🔔", path: "/notifications" },
    {
      label: "Profile",
      icon: "👤",
      action: () => requireAuth("/profile"),
    },
  ];

  return (
    <nav className="fixed bottom-0 left-0 right-0 z-20 border-t border-slate-200 bg-white dark:border-slate-800 dark:bg-slate-900">
      <div className="mx-auto flex w-full max-w-md items-center justify-between px-4 py-2">
        {items.map((item) => {
          const isActive = item.path
            ? location.pathname === item.path ||
              (item.path === "/profile" &&
                location.pathname.startsWith("/profile")) ||
              (item.path === "/search" &&
                location.pathname.startsWith("/search")) ||
              (item.path === "/notifications" &&
                location.pathname.startsWith("/notifications"))
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
                {item.label === "Create" ? (
                  <span className="flex h-12 w-12 items-center justify-center rounded-full bg-gradient-to-r from-purple-500 to-pink-500 text-2xl font-semibold text-white shadow-[0_12px_25px_-15px_rgba(168,85,247,0.8)] transition-all duration-200 hover:scale-105">
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
              <span className="relative text-xl">
                {item.icon}
                {item.label === "Notifications" && unreadCount > 0 ? (
                  <span className="absolute -right-2 -top-1 flex h-4 min-w-[16px] items-center justify-center rounded-full bg-red-500 px-1 text-[10px] font-semibold text-white">
                    {unreadCount > 9 ? "9+" : unreadCount}
                  </span>
                ) : null}
              </span>
              {item.label}
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
