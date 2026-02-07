import { useNavigate } from "react-router-dom";
import { BottomNav } from "../components/BottomNav";
import { Navbar } from "../components/Navbar";
import { EmptyState } from "../components/EmptyState";
import Avatar from "../components/Avatar";
import { useAuth } from "../hooks/useAuth";
import { useNotifications } from "../hooks/useNotifications";
import { timeAgo } from "../utils/timeAgo";

export function Notifications() {
  const navigate = useNavigate();
  const { user } = useAuth();
  const { notifications, unreadCount, loading, markAsRead, markAllAsRead } =
    useNotifications(user?.uid ?? null);

  return (
    <div className="min-h-screen bg-slate-50 pb-20 dark:bg-slate-900">
      <Navbar />

      <main className="mx-auto w-full max-w-md space-y-4 px-4 py-4">
        <div className="flex items-center justify-between">
          <h1 className="text-base font-semibold text-slate-900 dark:text-white">
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
          <div className="rounded-2xl bg-white p-6 text-center text-sm text-slate-400 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] dark:bg-slate-800 dark:text-slate-500">
            Loading notifications...
          </div>
        ) : null}

        {!loading && notifications.length === 0 ? (
          <EmptyState
            icon="🔔"
            title="No notifications"
            description="When someone likes or comments, you'll see it here"
          />
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
                  ? "border-slate-100 bg-white dark:border-slate-700 dark:bg-slate-800"
                  : "border-purple-100 bg-purple-50 dark:border-purple-500/40 dark:bg-purple-500/10"
              }`}
            >
              <Avatar
                src={item.fromUserAvatar}
                alt={item.fromUserName}
                userId={item.fromUserId}
                size={48}
                className="h-12 w-12"
              />
              <div className="flex-1">
                <p className="text-sm text-slate-700 dark:text-slate-200">
                  <span className="font-semibold text-slate-900 dark:text-white">
                    {item.fromUserName}
                  </span>{" "}
                  {item.message}
                </p>
                <p className="mt-1 text-xs text-slate-400 dark:text-slate-500">
                  {timeAgo(item.createdAt as Date)}
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
          <p className="text-center text-xs text-slate-400 dark:text-slate-500">
            {unreadCount} unread
          </p>
        ) : null}
      </main>

      <BottomNav />
    </div>
  );
}
