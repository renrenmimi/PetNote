import { Link, useLocation, useNavigate } from "react-router-dom";
import {
  Handshake,
  Home,
  MapPin,
  Plus,
  User,
  type LucideIcon,
} from "lucide-react";
import { useAuth } from "../hooks/useAuth";
import { useLanguage } from "../hooks/useLanguage";

type NavItem = {
  label: string;
  Icon: LucideIcon;
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

  /*
   * Line icons rather than emoji.
   *
   * Emoji are full-colour bitmaps: they cannot take the tint that marks the
   * selected tab, so the only thing distinguishing "Home" from the rest was
   * the colour of the *label* underneath. They also sit on their own
   * baselines and render at different optical weights, which is most of why
   * the chrome read as a web page rather than an app.
   *
   * Emoji stay where they are content — a caption, a tag, somebody's post.
   */
  const items: NavItem[] = [
    { label: t("nav.home"), Icon: Home, path: "/" },
    { label: t("nav.places"), Icon: MapPin, path: "/places" },
    {
      label: t("nav.create"),
      Icon: Plus,
      action: () => requireAuth("/create"),
    },
    { label: t("nav.meetups"), Icon: Handshake, path: "/meetups" },
    {
      label: t("nav.profile"),
      Icon: User,
      path: "/profile",
      action: () => requireAuth("/profile"),
    },
  ];

  return (
    <nav
      className="fixed bottom-0 left-0 right-0 z-50 border-t border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-900"
      // The home indicator's inset when there is one; a floor of 6px when
      // there is not. The raised Create button makes its column exactly as
      // tall as the 56px row, so on an SE-class screen (inset 0) the label
      // sat on the last pixel line of the display and its descenders were
      // cut by the bezel. Measured: Create bottom 667.0 in a 667pt viewport,
      // against 660.0 for every other column.
      style={{
        paddingBottom: "max(env(safe-area-inset-bottom, 0px), 0.375rem)",
      }}
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
                  <span className="flex h-9 w-9 items-center justify-center rounded-full bg-gradient-to-r from-purple-500 to-pink-500 text-white shadow-[0_10px_20px_-12px_rgba(168,85,247,0.9)] transition-transform duration-200 active:scale-95">
                    <item.Icon size={20} strokeWidth={2.5} aria-hidden="true" />
                  </span>
                ) : (
                  <item.Icon
                    size={22}
                    strokeWidth={isActive ? 2.4 : 1.9}
                    aria-hidden="true"
                  />
                )}
                {item.label}
              </button>
            );
          }

          return (
            <Link
              key={item.label}
              to={item.path || "/"}
              aria-current={isActive ? "page" : undefined}
              className={`flex flex-1 flex-col items-center gap-1 text-xs transition-all duration-200 active:scale-95 ${
                isActive ? "text-purple-600" : "text-slate-500 dark:text-slate-400"
              }`}
            >
              {/* Weight as well as colour marks the selection, so it survives
                  greyscale and does not rely on hue alone. */}
              <item.Icon
                size={22}
                strokeWidth={isActive ? 2.4 : 1.9}
                aria-hidden="true"
              />
              {item.label}
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
