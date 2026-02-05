import { Link, useLocation, useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";

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

  const requireAuth = (path: string) => {
    if (!user) {
      navigate("/login");
      return;
    }
    navigate(path);
  };

  const items: NavItem[] = [
    { label: "Home", icon: "🏠", path: "/" },
    { label: "Search", icon: "🔍", action: () => undefined },
    {
      label: "Create",
      icon: "+",
      action: () => requireAuth("/create"),
    },
    { label: "Alerts", icon: "🔔", action: () => undefined },
    {
      label: "Profile",
      icon: "👤",
      action: () => requireAuth("/profile"),
    },
  ];

  return (
    <nav className="fixed bottom-0 left-0 right-0 z-20 border-t border-slate-200 bg-white">
      <div className="mx-auto flex w-full max-w-md items-center justify-between px-4 py-2">
        {items.map((item) => {
          const isActive = item.path
            ? location.pathname === item.path
            : false;

          if (item.action) {
            return (
              <button
                key={item.label}
                type="button"
                onClick={item.action}
                className={`flex flex-1 flex-col items-center gap-1 text-xs ${
                  isActive ? "text-purple-600" : "text-slate-500"
                }`}
              >
                {item.label === "Create" ? (
                  <span className="flex h-10 w-10 items-center justify-center rounded-full bg-gradient-to-r from-purple-500 to-pink-500 text-xl font-semibold text-white shadow-md">
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
              className={`flex flex-1 flex-col items-center gap-1 text-xs ${
                isActive ? "text-purple-600" : "text-slate-500"
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
