import {
  collectionGroup,
  doc,
  documentId,
  getDoc,
  getDocs,
  limit,
  query,
  where,
} from "firebase/firestore";
import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import Avatar from "../components/Avatar";
import {
  blockUserByAdmin,
  deleteContentAndWarn,
  getPendingReports,
  getReportTargetUser,
  getReviewedReports,
  resolveReport,
  type ReportTargetUser,
} from "../services/admin";
import {
  deleteFeedback,
  getAllFeedback,
  updateFeedbackStatus,
  type Feedback,
} from "../services/feedback";
import { db } from "../services/firebase";
import { type ReportItem } from "../services/report";
import { optimizeCloudinaryUrl } from "../utils/cloudinaryUrl";
import { timeAgo } from "../utils/timeAgo";

type AdminTab = "reports" | "feedback";
type FeedbackDeleteTarget = Feedback | null;

type PostPreviewData = {
  id: string;
  authorName?: string;
  petName?: string;
  petAvatarUrl?: string;
  text?: string;
  mediaUrl?: string;
  media?: Array<{ url?: string; thumbUrl?: string }>;
};

type UserPreviewData = {
  id: string;
  displayName?: string;
  avatarUrl?: string;
};

type CommentPreviewData = {
  id: string;
  text?: string;
};

type ReportContentState =
  | { kind: "post"; data: PostPreviewData }
  | { kind: "user"; data: UserPreviewData }
  | { kind: "comment"; data: CommentPreviewData }
  | { kind: "deleted" }
  | { kind: "unavailable" };

type WarningModalState = {
  report: ReportItem;
  targetUser: ReportTargetUser | null;
  selectedReason: string;
  additionalDetails: string;
  loadingTarget: boolean;
};

type BlockModalState = {
  report: ReportItem;
  targetUser: ReportTargetUser | null;
  reason: string;
  loadingTarget: boolean;
};

const quickWarningReasons = [
  "Inappropriate content",
  "Spam or misleading",
  "Harassment or bullying",
  "Animal abuse content",
  "Violates community guidelines",
];

function toMillis(value: unknown): number {
  if (!value) return 0;
  if (value instanceof Date) return value.getTime();
  if (typeof value === "object" && value !== null) {
    const maybeTimestamp = value as {
      toDate?: () => Date;
      seconds?: number;
    };
    if (typeof maybeTimestamp.toDate === "function") {
      return maybeTimestamp.toDate().getTime();
    }
    if (typeof maybeTimestamp.seconds === "number") {
      return maybeTimestamp.seconds * 1000;
    }
  }
  return 0;
}

function formatReportType(type: ReportItem["targetType"]): string {
  if (type === "post") return "Post reported";
  if (type === "comment") return "Comment reported";
  return "User reported";
}

function formatFeedbackType(type: Feedback["type"]): string {
  if (type === "bug") return "Bug Report";
  if (type === "feature") return "Feature Request";
  if (type === "complaint") return "Complaint";
  return "Other";
}

function formatReportStatus(status: ReportItem["status"]): string {
  if (status === "pending") return "NEW";
  if (status === "reviewed") return "Reviewed";
  return "Resolved";
}

function formatFeedbackStatus(status: Feedback["status"]): string {
  if (status === "new") return "NEW";
  if (status === "read") return "Reviewed";
  return "Resolved";
}

function getPostImageUrl(post: PostPreviewData): string | undefined {
  if (Array.isArray(post.media) && post.media.length > 0) {
    return post.media[0].thumbUrl || post.media[0].url;
  }
  return post.mediaUrl;
}

function clipText(text?: string, maxLength = 200): string {
  if (!text) return "";
  if (text.length <= maxLength) return text;
  return `${text.slice(0, maxLength)}...`;
}

export function AdminPanel() {
  const navigate = useNavigate();
  const [activeTab, setActiveTab] = useState<AdminTab>("reports");
  const [reportsLoading, setReportsLoading] = useState(true);
  const [feedbackLoading, setFeedbackLoading] = useState(true);
  const [reports, setReports] = useState<ReportItem[]>([]);
  const [feedback, setFeedback] = useState<Feedback[]>([]);
  const [reportActionLoadingId, setReportActionLoadingId] = useState<
    string | null
  >(null);
  const [feedbackActionLoadingId, setFeedbackActionLoadingId] = useState<
    string | null
  >(null);
  const [expandedFeedbackId, setExpandedFeedbackId] = useState<string | null>(
    null
  );
  const [expandedReportId, setExpandedReportId] = useState<string | null>(null);
  const [reportContentMap, setReportContentMap] = useState<
    Record<string, ReportContentState>
  >({});
  const [reportContentLoading, setReportContentLoading] = useState<
    Record<string, boolean>
  >({});
  const [warningModal, setWarningModal] = useState<WarningModalState | null>(
    null
  );
  const [blockModal, setBlockModal] = useState<BlockModalState | null>(null);
  const [feedbackDeleteTarget, setFeedbackDeleteTarget] =
    useState<FeedbackDeleteTarget>(null);

  useEffect(() => {
    let active = true;
    const loadReports = async () => {
      setReportsLoading(true);
      try {
        const [pending, reviewed] = await Promise.all([
          getPendingReports(),
          getReviewedReports(),
        ]);
        if (!active) return;
        const merged = [...pending.reports, ...reviewed.reports].sort(
          (a, b) => toMillis(b.createdAt) - toMillis(a.createdAt)
        );
        setReports(merged);
      } finally {
        if (active) setReportsLoading(false);
      }
    };
    void loadReports();
    return () => {
      active = false;
    };
  }, []);

  useEffect(() => {
    let active = true;
    const loadFeedback = async () => {
      setFeedbackLoading(true);
      try {
        const entries = await getAllFeedback();
        if (active) {
          setFeedback(entries);
        }
      } finally {
        if (active) setFeedbackLoading(false);
      }
    };
    void loadFeedback();
    return () => {
      active = false;
    };
  }, []);

  const pendingCount = useMemo(
    () => reports.filter((item) => item.status === "pending").length,
    [reports]
  );
  const newFeedbackCount = useMemo(
    () => feedback.filter((item) => item.status === "new").length,
    [feedback]
  );

  const markReportResolvedLocally = (reportId: string) => {
    setReports((prev) =>
      prev.map((item) =>
        item.id === reportId ? { ...item, status: "resolved" } : item
      )
    );
  };

  const loadReportedContent = async (report: ReportItem) => {
    if (reportContentMap[report.id] || reportContentLoading[report.id]) {
      return;
    }

    setReportContentLoading((prev) => ({ ...prev, [report.id]: true }));
    try {
      if (report.targetType === "post") {
        const postDoc = await getDoc(doc(db, "posts", report.targetId));
        if (!postDoc.exists()) {
          setReportContentMap((prev) => ({
            ...prev,
            [report.id]: { kind: "deleted" },
          }));
          return;
        }
        const postData = postDoc.data() as Omit<PostPreviewData, "id">;
        setReportContentMap((prev) => ({
          ...prev,
          [report.id]: { kind: "post", data: { id: postDoc.id, ...postData } },
        }));
        return;
      }

      if (report.targetType === "user") {
        const userDoc = await getDoc(doc(db, "users", report.targetId));
        if (!userDoc.exists()) {
          setReportContentMap((prev) => ({
            ...prev,
            [report.id]: { kind: "deleted" },
          }));
          return;
        }
        const userData = userDoc.data() as Omit<UserPreviewData, "id">;
        setReportContentMap((prev) => ({
          ...prev,
          [report.id]: { kind: "user", data: { id: userDoc.id, ...userData } },
        }));
        return;
      }

      if (report.targetType === "comment") {
        if (report.postId) {
          const commentDoc = await getDoc(
            doc(db, "posts", report.postId, "comments", report.targetId)
          );
          if (commentDoc.exists()) {
            const commentData = commentDoc.data() as Omit<CommentPreviewData, "id">;
            setReportContentMap((prev) => ({
              ...prev,
              [report.id]: {
                kind: "comment",
                data: { id: commentDoc.id, ...commentData },
              },
            }));
            return;
          }
        }

        const commentQuery = query(
          collectionGroup(db, "comments"),
          where(documentId(), "==", report.targetId),
          limit(1)
        );
        const commentSnapshot = await getDocs(commentQuery);
        if (commentSnapshot.empty) {
          setReportContentMap((prev) => ({
            ...prev,
            [report.id]: { kind: "deleted" },
          }));
          return;
        }

        const commentDoc = commentSnapshot.docs[0];
        const commentData = commentDoc.data() as Omit<CommentPreviewData, "id">;
        setReportContentMap((prev) => ({
          ...prev,
          [report.id]: {
            kind: "comment",
            data: { id: commentDoc.id, ...commentData },
          },
        }));
        return;
      }
    } catch (error) {
      console.warn("Failed to load reported content:", error);
      setReportContentMap((prev) => ({
        ...prev,
        [report.id]: { kind: "unavailable" },
      }));
    } finally {
      setReportContentLoading((prev) => ({ ...prev, [report.id]: false }));
    }
  };

  const openWarningModal = async (report: ReportItem) => {
    setWarningModal({
      report,
      targetUser: null,
      selectedReason: "",
      additionalDetails: "",
      loadingTarget: true,
    });
    try {
      const targetUser = await getReportTargetUser(report);
      setWarningModal((prev) =>
        prev && prev.report.id === report.id
          ? { ...prev, targetUser, loadingTarget: false }
          : prev
      );
    } catch (error) {
      console.warn("Failed to resolve warning target user:", error);
      setWarningModal((prev) =>
        prev && prev.report.id === report.id
          ? { ...prev, targetUser: null, loadingTarget: false }
          : prev
      );
    }
  };

  const openBlockModal = async (report: ReportItem) => {
    setBlockModal({
      report,
      targetUser: null,
      reason: "",
      loadingTarget: true,
    });
    try {
      const targetUser = await getReportTargetUser(report);
      setBlockModal((prev) =>
        prev && prev.report.id === report.id
          ? { ...prev, targetUser, loadingTarget: false }
          : prev
      );
    } catch (error) {
      console.warn("Failed to resolve block target user:", error);
      setBlockModal((prev) =>
        prev && prev.report.id === report.id
          ? { ...prev, targetUser: null, loadingTarget: false }
          : prev
      );
    }
  };

  const handleToggleReport = (report: ReportItem) => {
    const expanded = expandedReportId === report.id;
    if (expanded) {
      setExpandedReportId(null);
      return;
    }
    setExpandedReportId(report.id);
    void loadReportedContent(report);
  };

  const handleDismissReport = async (report: ReportItem) => {
    setReportActionLoadingId(`dismiss-${report.id}`);
    try {
      await resolveReport(report.id, "dismiss", report);
      markReportResolvedLocally(report.id);
    } finally {
      setReportActionLoadingId(null);
    }
  };

  const handleSendWarning = async () => {
    if (!warningModal || !warningModal.targetUser) return;
    const reason = warningModal.selectedReason.trim();
    if (!reason) return;

    const { report, targetUser } = warningModal;
    setReportActionLoadingId(`warn-${report.id}`);
    try {
      await deleteContentAndWarn({
        report,
        targetUserId: targetUser.userId,
        warningReason: reason,
        additionalDetails: warningModal.additionalDetails,
      });
      markReportResolvedLocally(report.id);
      setReportContentMap((prev) => ({
        ...prev,
        [report.id]: { kind: "deleted" },
      }));
      setWarningModal(null);
    } finally {
      setReportActionLoadingId(null);
    }
  };

  const handleConfirmBlock = async () => {
    if (!blockModal || !blockModal.targetUser) return;
    const { report, targetUser } = blockModal;
    setReportActionLoadingId(`block-${report.id}`);
    try {
      await blockUserByAdmin(targetUser.userId, blockModal.reason.trim());
      await resolveReport(report.id, "dismiss", report);
      markReportResolvedLocally(report.id);
      setBlockModal(null);
    } finally {
      setReportActionLoadingId(null);
    }
  };

  const handleResolveFeedback = async (entry: Feedback) => {
    setFeedbackActionLoadingId(`resolve-${entry.id}`);
    try {
      await updateFeedbackStatus(entry.id, "resolved");
      setFeedback((prev) =>
        prev.map((item) =>
          item.id === entry.id ? { ...item, status: "resolved" } : item
        )
      );
    } finally {
      setFeedbackActionLoadingId(null);
    }
  };

  const handleDeleteFeedback = async (entry: Feedback) => {
    setFeedbackActionLoadingId(`delete-${entry.id}`);
    try {
      await deleteFeedback(entry.id);
      setFeedback((prev) => prev.filter((item) => item.id !== entry.id));
      if (expandedFeedbackId === entry.id) {
        setExpandedFeedbackId(null);
      }
      setFeedbackDeleteTarget(null);
    } finally {
      setFeedbackActionLoadingId(null);
    }
  };

  const renderReportedContent = (report: ReportItem) => {
    const loading = !!reportContentLoading[report.id];
    const content = reportContentMap[report.id];

    if (loading) {
      return (
        <div className="flex items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
          <span className="h-4 w-4 animate-spin rounded-full border-2 border-gray-300 border-t-gray-500 dark:border-gray-600 dark:border-t-gray-300" />
          Loading reported content...
        </div>
      );
    }

    if (!content) {
      return (
        <p className="text-xs italic text-gray-500 dark:text-gray-400">
          No preview available.
        </p>
      );
    }

    if (content.kind === "deleted") {
      return (
        <p className="text-xs italic text-gray-500 dark:text-gray-400">
          This content has been deleted.
        </p>
      );
    }

    if (content.kind === "unavailable") {
      return (
        <p className="text-xs italic text-gray-500 dark:text-gray-400">
          Unable to load this content.
        </p>
      );
    }

    if (content.kind === "post") {
      const imageUrl = getPostImageUrl(content.data);
      const petName = content.data.petName || "Pet";
      const authorName = content.data.authorName || "Unknown";
      return (
        <div className="space-y-2">
          <div className="flex items-start gap-3">
            <Avatar
              src={content.data.petAvatarUrl}
              alt={petName}
              userId={content.data.id}
              size={28}
              className="h-7 w-7"
            />
            <div className="min-w-0 flex-1">
              <p className="truncate text-sm font-medium text-gray-900 dark:text-white">
                {petName}
                <span className="ml-1 text-xs font-normal text-gray-500 dark:text-gray-400">
                  by {authorName}
                </span>
              </p>
              {content.data.text ? (
                <p className="mt-1 text-xs text-gray-600 dark:text-gray-300">
                  {clipText(content.data.text)}
                </p>
              ) : null}
            </div>
            {imageUrl ? (
              <img
                src={optimizeCloudinaryUrl(imageUrl, "thumbnail")}
                alt={petName}
                className="h-20 w-20 rounded-lg object-cover"
              />
            ) : null}
          </div>
          <button
            type="button"
            onClick={(event) => {
              event.stopPropagation();
              navigate(`/post/${content.data.id}`);
            }}
            className="text-xs font-medium text-purple-600 hover:text-purple-700 dark:text-purple-400 dark:hover:text-purple-300"
          >
            View Full Post {"->"}
          </button>
        </div>
      );
    }

    if (content.kind === "user") {
      const name = content.data.displayName || "User";
      return (
        <div className="space-y-2">
          <div className="flex items-center gap-3">
            <Avatar
              src={content.data.avatarUrl}
              alt={name}
              userId={content.data.id}
              size={32}
              className="h-8 w-8"
            />
            <p className="text-sm text-gray-900 dark:text-white">{name}</p>
          </div>
          <button
            type="button"
            onClick={(event) => {
              event.stopPropagation();
              navigate(`/profile/${content.data.id}`);
            }}
            className="text-xs font-medium text-purple-600 hover:text-purple-700 dark:text-purple-400 dark:hover:text-purple-300"
          >
            View Profile {"->"}
          </button>
        </div>
      );
    }

    return (
      <div className="space-y-2">
        <p className="text-xs text-gray-600 dark:text-gray-300">
          {content.data.text
            ? clipText(content.data.text)
            : "Comment content not available."}
        </p>
        {report.postId ? (
          <button
            type="button"
            onClick={(event) => {
              event.stopPropagation();
              navigate(`/post/${report.postId}`);
            }}
            className="text-xs font-medium text-purple-600 hover:text-purple-700 dark:text-purple-400 dark:hover:text-purple-300"
          >
            View Related Post {"->"}
          </button>
        ) : null}
      </div>
    );
  };

  const renderReports = () => {
    if (reportsLoading) {
      return (
        <div className="rounded-lg border border-gray-200 bg-white p-4 text-left text-sm text-gray-500 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-400">
          Loading reports...
        </div>
      );
    }

    if (reports.length === 0) {
      return (
        <div className="py-10 text-center text-sm text-gray-500 dark:text-gray-400">
          No pending reports
        </div>
      );
    }

    return (
      <div className="space-y-2">
        {reports.map((report) => {
          const dismissLoading =
            reportActionLoadingId === `dismiss-${report.id}`;
          const warnLoading = reportActionLoadingId === `warn-${report.id}`;
          const blockLoading = reportActionLoadingId === `block-${report.id}`;
          const isResolved = report.status === "resolved";
          const expanded = expandedReportId === report.id;
          return (
            <div
              key={report.id}
              className="rounded-lg border border-gray-200 bg-white p-4 text-left dark:border-gray-700 dark:bg-gray-800"
            >
              <button
                type="button"
                onClick={() => handleToggleReport(report)}
                className="w-full text-left"
              >
                <div className="flex items-start justify-between gap-3">
                  <p className="text-sm text-gray-600 dark:text-gray-300">
                    {formatReportType(report.targetType)} ·{" "}
                    {timeAgo(report.createdAt as Date)}
                  </p>
                  <span
                    className={`text-xs font-semibold ${
                      report.status === "pending"
                        ? "text-purple-500"
                        : "text-gray-500 dark:text-gray-400"
                    }`}
                  >
                    {formatReportStatus(report.status)}
                  </span>
                </div>

                <p className="mt-3 text-sm text-gray-900 dark:text-white">
                  <span className="font-medium">Reason:</span> {report.reason}
                </p>

                {report.description ? (
                  <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
                    {report.description}
                  </p>
                ) : null}

                <p className="mt-2 text-xs text-gray-500 dark:text-gray-400">
                  Reported by: {report.reporterName}
                </p>
              </button>

              {expanded ? (
                <div className="mt-3 border-t border-gray-200 pt-3 dark:border-gray-700">
                  <p className="text-[11px] font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">
                    Reported Content
                  </p>
                  <div className="mt-2 rounded-lg bg-gray-50 p-3 dark:bg-gray-800">
                    {renderReportedContent(report)}
                  </div>
                </div>
              ) : null}

              <div className="mt-4 flex justify-end gap-4">
                <button
                  type="button"
                  onClick={() => void handleDismissReport(report)}
                  disabled={dismissLoading || isResolved}
                  className="text-xs font-medium text-gray-500 transition-colors hover:text-gray-700 disabled:cursor-not-allowed disabled:opacity-50 dark:text-gray-400 dark:hover:text-gray-200"
                >
                  {dismissLoading ? "Dismissing..." : "Dismiss"}
                </button>
                <button
                  type="button"
                  onClick={() => void openWarningModal(report)}
                  disabled={warnLoading || isResolved}
                  className="text-xs font-medium text-red-500 transition-colors hover:text-red-600 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  {warnLoading ? "Working..." : "Delete & Warn"}
                </button>
                <button
                  type="button"
                  onClick={() => void openBlockModal(report)}
                  disabled={blockLoading || isResolved}
                  className="text-xs font-medium text-red-500 transition-colors hover:text-red-600 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  {blockLoading ? "Blocking..." : "Block User"}
                </button>
              </div>
            </div>
          );
        })}
      </div>
    );
  };

  const renderFeedback = () => {
    if (feedbackLoading) {
      return (
        <div className="rounded-lg border border-gray-200 bg-white p-4 text-left text-sm text-gray-500 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-400">
          Loading feedback...
        </div>
      );
    }

    if (feedback.length === 0) {
      return (
        <div className="py-10 text-center text-sm text-gray-500 dark:text-gray-400">
          No new feedback
        </div>
      );
    }

    return (
      <div className="space-y-2">
        {feedback.map((entry) => {
          const expanded = expandedFeedbackId === entry.id;
          const resolveLoading =
            feedbackActionLoadingId === `resolve-${entry.id}`;
          const deleteLoading = feedbackActionLoadingId === `delete-${entry.id}`;
          const isResolved = entry.status === "resolved";

          return (
            <div
              key={entry.id}
              className="rounded-lg border border-gray-200 bg-white p-4 text-left dark:border-gray-700 dark:bg-gray-800"
            >
              <button
                type="button"
                onClick={() =>
                  setExpandedFeedbackId(expanded ? null : entry.id)
                }
                className="w-full text-left"
              >
                <div className="flex items-start justify-between gap-3">
                  <p className="text-sm text-gray-600 dark:text-gray-300">
                    {formatFeedbackType(entry.type)} ·{" "}
                    {timeAgo(entry.createdAt as Date)}
                  </p>
                  <span
                    className={`text-xs font-semibold ${
                      entry.status === "new"
                        ? "text-purple-500"
                        : "text-gray-500 dark:text-gray-400"
                    }`}
                  >
                    {formatFeedbackStatus(entry.status)}
                  </span>
                </div>

                <p className="mt-3 text-sm font-medium text-gray-900 dark:text-white">
                  Subject: {entry.subject}
                </p>
                <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
                  From: {entry.userEmail}
                </p>

                <div
                  className={`mt-3 overflow-hidden transition-[max-height] duration-300 ${
                    expanded ? "max-h-96" : "max-h-16"
                  }`}
                >
                  <p
                    className="text-sm text-gray-500 dark:text-gray-400"
                    style={
                      expanded
                        ? undefined
                        : {
                            display: "-webkit-box",
                            WebkitLineClamp: 3,
                            WebkitBoxOrient: "vertical",
                            overflow: "hidden",
                          }
                    }
                  >
                    Message: {entry.message}
                  </p>
                </div>
              </button>

              <div className="mt-4 flex justify-end gap-4">
                <button
                  type="button"
                  onClick={(event) => {
                    event.stopPropagation();
                    void handleResolveFeedback(entry);
                  }}
                  disabled={resolveLoading || isResolved}
                  className="text-xs font-medium text-gray-500 transition-colors hover:text-gray-700 disabled:cursor-not-allowed disabled:opacity-50 dark:text-gray-400 dark:hover:text-gray-200"
                >
                  {resolveLoading ? "Resolving..." : "Resolve"}
                </button>
                <button
                  type="button"
                  onClick={(event) => {
                    event.stopPropagation();
                    setFeedbackDeleteTarget(entry);
                  }}
                  disabled={deleteLoading}
                  className="text-xs font-medium text-red-500 transition-colors hover:text-red-600 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  {deleteLoading ? "Deleting..." : "Delete"}
                </button>
              </div>
            </div>
          );
        })}
      </div>
    );
  };

  return (
    <div className="min-h-screen bg-gray-50 p-4 dark:bg-gray-900">
      <div className="mx-auto w-full max-w-md">
        <button
          type="button"
          onClick={() => navigate(-1)}
          className="mb-3 text-xl text-gray-500 transition-colors hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
          aria-label="Go back"
        >
          ←
        </button>

        <h1 className="text-left text-lg font-semibold text-gray-900 dark:text-white">
          Admin Panel
        </h1>
        <p className="mt-1 text-left text-xs text-gray-500 dark:text-gray-400">
          {pendingCount} pending reports · {newFeedbackCount} new feedback
        </p>

        <div className="mt-4 border-b border-gray-200 dark:border-gray-700">
          <div className="flex gap-6">
            <button
              type="button"
              onClick={() => setActiveTab("reports")}
              className={`border-b-2 pb-2 text-sm font-medium transition-colors ${
                activeTab === "reports"
                  ? "border-gray-900 text-gray-900 dark:border-white dark:text-white"
                  : "border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
              }`}
            >
              Reports{" "}
              <span className="text-xs text-gray-500 dark:text-gray-400">
                ({pendingCount})
              </span>
            </button>

            <button
              type="button"
              onClick={() => setActiveTab("feedback")}
              className={`border-b-2 pb-2 text-sm font-medium transition-colors ${
                activeTab === "feedback"
                  ? "border-gray-900 text-gray-900 dark:border-white dark:text-white"
                  : "border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
              }`}
            >
              Feedback{" "}
              <span className="text-xs text-gray-500 dark:text-gray-400">
                ({newFeedbackCount})
              </span>
            </button>
          </div>
        </div>

        <div className="mt-4">
          {activeTab === "reports" ? renderReports() : renderFeedback()}
        </div>
      </div>

      {warningModal ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div className="w-full max-w-md rounded-lg border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-800">
            <h3 className="text-sm font-semibold text-gray-900 dark:text-white">
              Delete content and warn user
            </h3>
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
              {warningModal.loadingTarget
                ? "Loading user..."
                : warningModal.targetUser
                ? `User: ${warningModal.targetUser.userName}`
                : "Unable to resolve target user"}
            </p>
            <label className="mt-4 block text-xs font-medium text-gray-600 dark:text-gray-300">
              Reason
            </label>
            <div className="mt-2 flex flex-wrap gap-2">
              {quickWarningReasons.map((item) => (
                <button
                  key={item}
                  type="button"
                  onClick={() =>
                    setWarningModal((prev) =>
                      prev
                        ? {
                            ...prev,
                            selectedReason:
                              prev.selectedReason === item ? "" : item,
                          }
                        : prev
                    )
                  }
                  className={`rounded-full px-3 py-1.5 text-xs transition-colors ${
                    warningModal.selectedReason === item
                      ? "bg-gradient-to-r from-purple-500 to-pink-500 text-white"
                      : "border border-gray-200 bg-gray-100 text-gray-600 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300"
                  }`}
                >
                  {item}
                </button>
              ))}
            </div>
            <label className="mt-4 block text-xs font-medium text-gray-600 dark:text-gray-300">
              Additional details (optional)
            </label>
            <textarea
              value={warningModal.additionalDetails}
              onChange={(event) =>
                setWarningModal((prev) =>
                  prev
                    ? {
                        ...prev,
                        additionalDetails: event.target.value.slice(0, 300),
                      }
                    : prev
                )
              }
              placeholder="Add more context if needed..."
              maxLength={300}
              rows={4}
              className="mt-1 w-full rounded-lg border border-gray-200 bg-white px-3 py-2 text-sm text-gray-900 outline-none transition-colors focus:border-purple-400 dark:border-gray-700 dark:bg-gray-900 dark:text-white"
            />
            <p className="mt-1 text-right text-[11px] text-gray-500 dark:text-gray-400">
              {warningModal.additionalDetails.length}/300
            </p>
            <div className="mt-4 flex justify-end gap-3">
              <button
                type="button"
                onClick={() => setWarningModal(null)}
                className="text-xs font-medium text-gray-500 transition-colors hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={() => void handleSendWarning()}
                disabled={
                  warningModal.loadingTarget ||
                  !warningModal.targetUser ||
                  !warningModal.selectedReason.trim()
                }
                className="text-xs font-medium text-red-500 transition-colors hover:text-red-600 disabled:cursor-not-allowed disabled:opacity-50"
              >
                Send Warning
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {blockModal ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div className="w-full max-w-md rounded-lg border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-800">
            <h3 className="text-sm font-semibold text-gray-900 dark:text-white">
              Block this user?
            </h3>
            {blockModal.loadingTarget ? (
              <p className="mt-2 text-xs text-gray-500 dark:text-gray-400">
                Loading user...
              </p>
            ) : blockModal.targetUser ? (
              <>
                <p className="mt-2 text-sm text-gray-900 dark:text-white">
                  {blockModal.targetUser.userName}
                </p>
                {blockModal.targetUser.userEmail ? (
                  <p className="text-xs text-gray-500 dark:text-gray-400">
                    {blockModal.targetUser.userEmail}
                  </p>
                ) : null}
              </>
            ) : (
              <p className="mt-2 text-xs text-gray-500 dark:text-gray-400">
                Unable to resolve user.
              </p>
            )}
            <p className="mt-3 text-xs text-gray-500 dark:text-gray-400">
              This user will not be able to post, comment, or interact. They can
              still browse content.
            </p>
            <label className="mt-4 block text-xs font-medium text-gray-600 dark:text-gray-300">
              Ban reason (optional)
            </label>
            <textarea
              value={blockModal.reason}
              onChange={(event) =>
                setBlockModal((prev) =>
                  prev ? { ...prev, reason: event.target.value.slice(0, 300) } : prev
                )
              }
              placeholder="Optional reason..."
              maxLength={300}
              rows={3}
              className="mt-1 w-full rounded-lg border border-gray-200 bg-white px-3 py-2 text-sm text-gray-900 outline-none transition-colors focus:border-purple-400 dark:border-gray-700 dark:bg-gray-900 dark:text-white"
            />
            <div className="mt-4 flex justify-end gap-3">
              <button
                type="button"
                onClick={() => setBlockModal(null)}
                className="text-xs font-medium text-gray-500 transition-colors hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={() => void handleConfirmBlock()}
                disabled={blockModal.loadingTarget || !blockModal.targetUser}
                className="text-xs font-medium text-red-500 transition-colors hover:text-red-600 disabled:cursor-not-allowed disabled:opacity-50"
              >
                Block User
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {feedbackDeleteTarget ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div className="w-full max-w-sm rounded-lg border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-800">
            <p className="text-sm font-medium text-gray-900 dark:text-white">
              Delete this feedback?
            </p>
            <div className="mt-4 flex justify-end gap-3">
              <button
                type="button"
                onClick={() => setFeedbackDeleteTarget(null)}
                className="text-xs font-medium text-gray-500 transition-colors hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={() => void handleDeleteFeedback(feedbackDeleteTarget)}
                className="text-xs font-medium text-red-500 transition-colors hover:text-red-600"
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
