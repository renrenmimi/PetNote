import { useNavigate } from "react-router-dom";
import { Navbar } from "../components/Navbar";
import { EmptyState } from "../components/EmptyState";
import Avatar from "../components/Avatar";
import PawIcon from "../components/PawIcon";
import { useAuth } from "../hooks/useAuth";
import { useLanguage } from "../hooks/useLanguage";
import { useNotifications } from "../hooks/useNotifications";
import { optimizeCloudinaryUrl } from "../utils/cloudinaryUrl";
import { timeAgo } from "../utils/timeAgo";

export function Notifications() {
  const navigate = useNavigate();
  const { user } = useAuth();
  const { t } = useLanguage();
  const {
    notifications,
    unreadCount,
    loading,
    hasMore,
    loadingMore,
    loadMore,
    markAsRead,
    markAllAsRead,
  } = useNotifications(user?.uid ?? null);

  return (
    <div className="min-h-screen bg-slate-50 pb-20 dark:bg-slate-900">
      <Navbar />

      <main className="mx-auto w-full max-w-md space-y-4 px-4 py-4">
        <div className="flex items-center justify-between">
          <h1 className="text-base font-semibold text-slate-900 dark:text-white">
            {t("notifications.title")}
          </h1>
          <button
            type="button"
            onClick={() => {
              // The hook rolls the optimistic update back on failure; swallow
              // the re-thrown error so it doesn't become an unhandled
              // rejection.
              void markAllAsRead().catch(() => undefined);
            }}
            className="text-xs font-semibold text-purple-600 transition-all duration-200 hover:scale-105"
          >
            {t("notifications.markAllRead")}
          </button>
        </div>

        {loading ? (
          <div className="rounded-2xl bg-white p-6 text-center text-sm text-slate-400 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] dark:bg-slate-800 dark:text-slate-500">
            {t("notifications.loading")}
          </div>
        ) : null}

        {!loading && notifications.length === 0 ? (
          <EmptyState
            icon="🔔"
            title={t("notifications.emptyTitle")}
            description={t("notifications.emptyDescription")}
          />
        ) : null}

        <div className="space-y-3">
          {notifications.map((item) => {
            const isWarning = item.type === "warning";
            const cardClass = isWarning
              ? "border-red-100 bg-red-50 dark:border-red-900/40 dark:bg-red-900/10"
              : item.read
              ? "border-slate-100 bg-white dark:border-slate-700 dark:bg-slate-800"
              : "border-purple-100 bg-purple-50 dark:border-purple-500/40 dark:bg-purple-500/10";

            if (isWarning) {
              return (
                <button
                  key={item.id}
                  type="button"
                  onClick={() => {
                    if (!item.read) {
                      void markAsRead(item.id).catch(() => undefined);
                    }
                  }}
                  className={`flex w-full items-center gap-3 rounded-2xl border px-4 py-3 text-left ${cardClass}`}
                >
                  <div className="flex h-12 w-12 items-center justify-center rounded-full bg-white dark:bg-slate-800">
                    <PawIcon size={18} />
                  </div>
                  <div className="flex-1">
                    <p className="text-sm text-slate-700 dark:text-slate-200">
                      <span className="font-semibold text-slate-900 dark:text-white">
                        ⚠️ {t("notifications.petnoteTeam")}
                      </span>{" "}
                      {item.message}
                    </p>
                    {item.warningDetails ? (
                      <p className="mt-1 text-xs text-slate-600 dark:text-slate-300">
                        {t("notifications.details")}: {item.warningDetails}
                      </p>
                    ) : null}
                    <p className="mt-1 text-xs text-slate-400 dark:text-slate-500">
                      {timeAgo(item.createdAt as Date)}
                    </p>
                  </div>
                </button>
              );
            }

            return (
              <button
                key={item.id}
                type="button"
                onClick={() => {
                  // Skip already-read items (pointless updateDoc per click)
                  // and swallow failures — the hook rolls back optimistics.
                  if (!item.read) {
                    void markAsRead(item.id).catch(() => undefined);
                  }
                  if (item.type === "pet_follow" || item.type === "follow") {
                    // Prefer the pet page (backend now stamps petId); fall back
                    // to the follower's profile for legacy notifications.
                    navigate(
                      item.petId
                        ? `/pet/${item.petId}`
                        : `/profile/${item.fromUserId}`
                    );
                  } else if (item.postId) {
                    navigate(`/post/${item.postId}`);
                  } else {
                    navigate("/");
                  }
                }}
                className={`flex w-full items-center gap-3 rounded-2xl border px-4 py-3 text-left transition-all duration-200 hover:scale-[1.01] ${cardClass}`}
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
                    src={optimizeCloudinaryUrl(item.postImage, "thumbnail")}
                    alt={t("notifications.postImageAlt")}
                    className="h-12 w-12 rounded-xl object-cover"
                  />
                ) : null}
              </button>
            );
          })}
        </div>

        {unreadCount > 0 ? (
          <p className="text-center text-xs text-slate-400 dark:text-slate-500">
            {t("notifications.unreadCount", { count: unreadCount })}
          </p>
        ) : null}

        {hasMore ? (
          <div className="flex justify-center">
            <button
              type="button"
              onClick={() => void loadMore()}
              disabled={loadingMore}
              className="rounded-full border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-700 transition hover:border-purple-300 hover:text-purple-600 disabled:cursor-not-allowed disabled:opacity-60 dark:border-slate-700 dark:text-slate-300"
            >
              {loadingMore
                ? t("notifications.loadingMore")
                : t("notifications.loadMore")}
            </button>
          </div>
        ) : null}
      </main>

    </div>
  );
}
