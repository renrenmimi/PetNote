import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  getPendingReports,
  getReviewedReports,
  resolveReport,
  type ResolveAction,
} from "../services/admin";
import { type ReportItem } from "../services/report";
import { getPostById } from "../services/posts";
import { getUserProfile } from "../services/users";
import { timeAgo } from "../utils/timeAgo";
import Avatar from "../components/Avatar";

type ReportPreview = {
  imageUrl?: string;
  text?: string;
  userName?: string;
  userAvatar?: string;
};

export function AdminPanel() {
  const navigate = useNavigate();
  const [activeTab, setActiveTab] = useState<"pending" | "reviewed">("pending");
  const [pending, setPending] = useState<ReportItem[]>([]);
  const [reviewed, setReviewed] = useState<ReportItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [previews, setPreviews] = useState<Record<string, ReportPreview>>({});
  const [actionLoading, setActionLoading] = useState<string | null>(null);

  useEffect(() => {
    let ignore = false;
    const load = async () => {
      setLoading(true);
      const [pendingReports, reviewedReports] = await Promise.all([
        getPendingReports(),
        getReviewedReports(),
      ]);
      if (!ignore) {
        setPending(pendingReports);
        setReviewed(reviewedReports);
        setLoading(false);
      }
    };
    void load();
    return () => {
      ignore = true;
    };
  }, []);

  useEffect(() => {
    let ignore = false;
    const list = activeTab === "pending" ? pending : reviewed;

    const loadPreviews = async () => {
      const next: Record<string, ReportPreview> = {};
      for (const report of list) {
        if (report.targetType === "post") {
          const post = await getPostById(report.targetId);
          next[report.id] = {
            imageUrl:
              post?.media && post.media.length > 0
                ? post.media[0].thumbUrl || post.media[0].url
                : post?.mediaUrl,
            text: post?.text,
          };
        }
        if (report.targetType === "user") {
          const profile = await getUserProfile(report.targetId);
          next[report.id] = {
            userName: profile?.displayName || "User",
            userAvatar: profile?.avatarUrl,
          };
        }
      }
      if (!ignore) {
        setPreviews((prev) => ({ ...prev, ...next }));
      }
    };

    void loadPreviews();
    return () => {
      ignore = true;
    };
  }, [activeTab, pending, reviewed]);

  const activeReports = activeTab === "pending" ? pending : reviewed;
  const pendingCount = pending.length;

  const handleAction = async (report: ReportItem, action: ResolveAction) => {
    setActionLoading(report.id + action);
    await resolveReport(report.id, action, report);
    const nextStatus = action === "dismiss" ? "resolved" : "reviewed";
    setPending((prev) => prev.filter((item) => item.id !== report.id));
    setReviewed((prev) => [
      { ...report, status: nextStatus },
      ...prev,
    ]);
    setActionLoading(null);
  };

  const getStatusColor = (status?: string) =>
    status === "pending" ? "bg-orange-400" : "bg-emerald-400";

  return (
    <div className="min-h-screen bg-slate-50 pb-20 dark:bg-slate-900">
      <header className="sticky top-0 z-10 bg-slate-900 text-white">
        <div className="mx-auto flex w-full max-w-md items-center justify-between px-4 py-3">
          <button
            type="button"
            onClick={() => navigate(-1)}
            className="text-xl text-white/80 hover:text-white"
            aria-label="Go back"
          >
            ←
          </button>
          <div className="flex items-center gap-2">
            <h1 className="text-base font-semibold">Admin Panel</h1>
            <span className="rounded-full bg-red-500 px-2 py-0.5 text-xs font-semibold">
              {pendingCount}
            </span>
          </div>
          <div className="w-6" />
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-4 px-4 py-4">
        <div className="relative grid grid-cols-2 border-b border-slate-200 dark:border-slate-700">
          <button
            type="button"
            onClick={() => setActiveTab("pending")}
            className={`pb-2 text-sm font-semibold transition-all duration-200 ${
              activeTab === "pending"
                ? "text-slate-900 dark:text-white"
                : "text-slate-400 hover:text-slate-600 dark:text-slate-500 dark:hover:text-slate-200"
            }`}
          >
            Pending
          </button>
          <button
            type="button"
            onClick={() => setActiveTab("reviewed")}
            className={`pb-2 text-sm font-semibold transition-all duration-200 ${
              activeTab === "reviewed"
                ? "text-slate-900 dark:text-white"
                : "text-slate-400 hover:text-slate-600 dark:text-slate-500 dark:hover:text-slate-200"
            }`}
          >
            Reviewed
          </button>
          <span
            className={`absolute bottom-0 h-0.5 w-1/2 rounded-full bg-gradient-to-r from-purple-500 to-pink-500 transition-all duration-300 ${
              activeTab === "reviewed" ? "translate-x-full" : "translate-x-0"
            }`}
          />
        </div>

        {loading ? (
          <div className="rounded-2xl bg-white p-6 text-center text-sm text-slate-400 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] dark:bg-slate-800 dark:text-slate-500">
            Loading reports...
          </div>
        ) : activeReports.length === 0 ? (
          <div className="rounded-2xl bg-white p-8 text-center text-sm text-slate-500 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] dark:bg-slate-800 dark:text-slate-300">
            No reports here.
          </div>
        ) : (
          <div className="space-y-4">
            {activeReports.map((report) => {
              const preview = previews[report.id];
              const isPending = report.status === "pending";
              const actionKey = report.id;
              return (
                <div
                  key={report.id}
                  className="relative overflow-hidden rounded-2xl bg-white p-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700"
                >
                  <span
                    className={`absolute left-0 top-0 h-full w-1 ${getStatusColor(
                      report.status
                    )}`}
                  />
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <p className="text-xs text-slate-500 dark:text-slate-400">
                        {report.targetType.toUpperCase()}
                      </p>
                      <p className="text-sm font-semibold text-slate-900 dark:text-white">
                        {report.reason}
                      </p>
                      {report.description ? (
                        <p className="mt-1 text-xs text-slate-500 dark:text-slate-400">
                          {report.description}
                        </p>
                      ) : null}
                    </div>
                    <span className="text-xs text-slate-400 dark:text-slate-500">
                      {timeAgo(report.createdAt as Date)}
                    </span>
                  </div>

                  <div className="mt-3 flex items-center gap-3">
                    <Avatar
                      src={report.reporterAvatar}
                      alt={report.reporterName}
                      userId={report.reporterId}
                      size={32}
                      className="h-8 w-8"
                    />
                    <span className="text-xs font-semibold text-slate-700 dark:text-slate-200">
                      {report.reporterName}
                    </span>
                  </div>

                  <div className="mt-3 flex items-center justify-between gap-3 rounded-xl border border-slate-100 bg-slate-50 p-3 dark:border-slate-700 dark:bg-slate-900/40">
                    {report.targetType === "post" ? (
                      <div className="flex items-center gap-3">
                        {preview?.imageUrl ? (
                          <img
                            src={preview.imageUrl}
                            alt="post"
                            className="h-12 w-12 rounded-lg object-cover"
                          />
                        ) : null}
                        <p className="text-xs text-slate-600 dark:text-slate-300">
                          {preview?.text
                            ? `${preview.text.slice(0, 50)}...`
                            : "Post preview"}
                        </p>
                      </div>
                    ) : report.targetType === "user" ? (
                      <div className="flex items-center gap-3">
                        <Avatar
                          src={preview?.userAvatar}
                          alt={preview?.userName || "User"}
                          userId={report.targetId}
                          size={48}
                          className="h-12 w-12"
                        />
                        <p className="text-sm font-semibold text-slate-700 dark:text-slate-200">
                          {preview?.userName || "User"}
                        </p>
                      </div>
                    ) : (
                      <p className="text-xs text-slate-500 dark:text-slate-300">
                        Comment reported
                      </p>
                    )}
                    <button
                      type="button"
                      onClick={() => {
                        if (report.targetType === "post") {
                          navigate(`/post/${report.targetId}`);
                        } else if (report.targetType === "user") {
                          navigate(`/profile/${report.targetId}`);
                        }
                      }}
                      className="text-xs font-semibold text-blue-500 hover:text-blue-600"
                    >
                      View
                    </button>
                  </div>

                  <div className="mt-4 flex flex-wrap items-center gap-2">
                    <button
                      type="button"
                      disabled={!isPending}
                      onClick={() => handleAction(report, "delete")}
                      className="rounded-full bg-red-500 px-3 py-1.5 text-xs font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
                    >
                      {actionLoading === actionKey + "delete"
                        ? "Deleting..."
                        : "Delete Content"}
                    </button>
                    <button
                      type="button"
                      disabled={!isPending}
                      onClick={() => handleAction(report, "ban")}
                      className="rounded-full bg-red-600 px-3 py-1.5 text-xs font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
                    >
                      {actionLoading === actionKey + "ban"
                        ? "Banning..."
                        : "Ban User"}
                    </button>
                    <button
                      type="button"
                      disabled={!isPending}
                      onClick={() => handleAction(report, "dismiss")}
                      className="rounded-full border border-slate-200 px-3 py-1.5 text-xs font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-60 dark:border-slate-700 dark:text-slate-300 dark:hover:bg-slate-700"
                    >
                      {actionLoading === actionKey + "dismiss"
                        ? "Dismissing..."
                        : "Dismiss"}
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </main>
    </div>
  );
}
