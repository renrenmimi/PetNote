import { useNavigate } from "react-router-dom";
import { BottomNav } from "../components/BottomNav";
import { Navbar } from "../components/Navbar";
import { useAuth } from "../hooks/useAuth";
import { useNotifications } from "../hooks/useNotifications";

const formatTime = (value: unknown) => {
  const date =
    value instanceof Date
      ? value
      : typeof value === "object" &&
        value !== null &&
        "toDate" in value &&
        typeof (value as { toDate: () => Date }).toDate === "function"
      ? (value as { toDate: () => Date }).toDate()
      : new Date();

  const diff = Date.now() - date.getTime();
  const minutes = Math.floor(diff / 60000);
  if (minutes <= 0) return "Just now";
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days === 1) return "Yesterday";
  return date.toLocaleDateString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
};

export function Notifications() {
  const navigate = useNavigate();
  const { user } = useAuth();
  const { notifications, unreadCount, loading, markAsRead, markAllAsRead } =
    useNotifications(user?.uid ?? null);

  return (
    <div className="min-h-screen bg-slate-50 pb-20">
      <Navbar />

      <main className="mx-auto w-full max-w-md space-y-4 px-4 py-4">
        <div className="flex items-center justify-between">
          <h1 className="text-base font-semibold text-slate-900">
            Notifications
          </h1>
          <button
            type="button"
            onClick={markAllAsRead}
            className="text-xs font-semibold text-purple-600 transition-all duration-200 hover:scale-105"
          >
            Mark all as read
          </button>
        </div>

        {loading ? (
          <div className="rounded-2xl bg-white p-6 text-center text-sm text-slate-400 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)]">
            Loading notifications...
          </div>
        ) : null}

        {!loading && notifications.length === 0 ? (
          <div className="rounded-2xl bg-white p-8 text-center text-sm text-slate-500 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)]">
            No notifications yet 🔔
          </div>
        ) : null}

        <div className="space-y-3">
          {notifications.map((item) => (
            <button
              key={item.id}
              type="button"
              onClick={() => {
                void markAsRead(item.id);
                if (item.type === "follow") {
                  navigate(`/profile/${item.fromUserId}`);
                } else if (item.postId) {
                  navigate(`/post/${item.postId}`);
                } else {
                  navigate("/");
                }
              }}
              className={`flex w-full items-center gap-3 rounded-2xl border px-4 py-3 text-left transition-all duration-200 hover:scale-[1.01] ${
                item.read
                  ? "border-slate-100 bg-white"
                  : "border-purple-100 bg-purple-50"
              }`}
            >
              <img
                src={item.fromUserAvatar}
                alt={item.fromUserName}
                className="h-12 w-12 rounded-full object-cover"
              />
              <div className="flex-1">
                <p className="text-sm text-slate-700">
                  <span className="font-semibold text-slate-900">
                    {item.fromUserName}
                  </span>{" "}
                  {item.message}
                </p>
                <p className="mt-1 text-xs text-slate-400">
                  {formatTime(item.createdAt)}
                </p>
              </div>
              {item.postImage ? (
                <img
                  src={item.postImage}
                  alt="post"
                  className="h-12 w-12 rounded-xl object-cover"
                />
              ) : null}
            </button>
          ))}
        </div>

        {unreadCount > 0 ? (
          <p className="text-center text-xs text-slate-400">
            {unreadCount} unread
          </p>
        ) : null}
      </main>

      <BottomNav />
    </div>
  );
}
