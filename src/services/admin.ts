import {
  collection,
  doc,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  serverTimestamp,
  startAfter,
  updateDoc,
  where,
  type QueryConstraint,
  type QueryDocumentSnapshot,
} from "firebase/firestore";
import { httpsCallable } from "firebase/functions";
import { setAdminState } from "./adminState";
import { auth, db, functions } from "./firebase";
import { deleteComment, deletePost } from "./posts";
import { type ReportItem } from "./report";

export type ResolveAction = "delete" | "ban" | "dismiss";
export type ReportTargetUser = {
  userId: string;
  userName: string;
  userEmail: string;
};

const DEFAULT_WARNING_REASON = "Violated community guidelines";

async function sendWarningNotification(params: {
  userId: string;
  message: string;
  warningReason: string;
  warningDetails?: string;
}): Promise<void> {
  if (!auth.currentUser?.uid) {
    throw new Error("Admin must be logged in.");
  }

  await httpsCallable<
    {
      userId: string;
      type: "warning";
      message: string;
      warningReason: string;
      warningDetails?: string;
      read?: boolean;
    },
    { id: string }
  >(functions, "sendNotification")({
    userId: params.userId,
    type: "warning",
    message: params.message,
    warningReason: params.warningReason,
    warningDetails: params.warningDetails,
    read: false,
  });
}

async function pagedReportsQuery(
  statusFilter: QueryConstraint,
  options?: { limitCount?: number; lastDoc?: QueryDocumentSnapshot }
): Promise<{
  reports: ReportItem[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  const limitCount = options?.limitCount ?? 50;
  const reportsRef = collection(db, "reports");
  const constraints: QueryConstraint[] = [
    statusFilter,
    orderBy("createdAt", "desc"),
    limit(limitCount),
  ];
  if (options?.lastDoc) {
    constraints.push(startAfter(options.lastDoc));
  }
  const snapshot = await getDocs(query(reportsRef, ...constraints));
  const reports = snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<ReportItem, "id">),
  }));
  const nextLast =
    (snapshot.docs[snapshot.docs.length - 1] as
      | QueryDocumentSnapshot
      | undefined) ?? null;
  return {
    reports,
    lastDoc: nextLast,
    hasMore: snapshot.docs.length === limitCount,
  };
}

export async function getPendingReports(options?: {
  limitCount?: number;
  lastDoc?: QueryDocumentSnapshot;
}): Promise<{
  reports: ReportItem[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  return pagedReportsQuery(where("status", "==", "pending"), options);
}

export async function getReviewedReports(options?: {
  limitCount?: number;
  lastDoc?: QueryDocumentSnapshot;
}): Promise<{
  reports: ReportItem[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  return pagedReportsQuery(
    where("status", "in", ["reviewed", "resolved"]),
    options
  );
}

export async function resolveReport(
  reportId: string,
  action: ResolveAction,
  report?: ReportItem
): Promise<void> {
  const reportRef = doc(db, "reports", reportId);
  const snapshot = report
    ? { data: () => report, exists: () => true }
    : await getDoc(reportRef);
  if (!snapshot.exists()) return;
  const data = snapshot.data() as ReportItem;

  if (action === "delete") {
    if (data.targetType === "post") {
      await deletePost(data.targetId);
    }
    if (data.targetType === "comment" && data.postId) {
      await deleteComment(data.postId, data.targetId);
    }
  }

  if (action === "ban") {
    const targetUser = await getReportTargetUser(data);
    if (targetUser) {
      await blockUserByAdmin(targetUser.userId);
    }
  }

  const status =
    action === "dismiss" || action === "delete" ? "resolved" : "reviewed";
  await updateDoc(reportRef, { status, updatedAt: serverTimestamp() });
}

export async function getReportTargetUser(
  report: ReportItem
): Promise<ReportTargetUser | null> {
  const resolveUserId = async (): Promise<string | null> => {
    if (report.targetType === "user") {
      return report.targetId;
    }

    if (report.targetType === "post") {
      const postSnap = await getDoc(doc(db, "posts", report.targetId));
      if (!postSnap.exists()) return null;
      const postData = postSnap.data() as { authorId?: string };
      return postData.authorId ?? null;
    }

    if (report.targetType === "comment") {
      // Without a postId the comment can't be located. (The old fallback —
      // collectionGroup("comments") filtered by a bare documentId() — is an
      // invalid Firestore query and always threw: collection-group
      // documentId() filters require a full document path.)
      if (!report.postId) return null;
      const commentSnap = await getDoc(
        doc(db, "posts", report.postId, "comments", report.targetId)
      );
      if (!commentSnap.exists()) return null;
      const commentData = commentSnap.data() as { authorId?: string };
      return commentData.authorId ?? null;
    }

    return null;
  };

  const userId = await resolveUserId();
  if (!userId) return null;

  const userSnap = await getDoc(doc(db, "users", userId));
  const userData = userSnap.exists()
    ? (userSnap.data() as { displayName?: string; email?: string })
    : null;

  return {
    userId,
    userName: userData?.displayName || "Unknown User",
    userEmail: "",
  };
}

export async function deleteContentAndWarn(params: {
  report: ReportItem;
  targetUserId: string;
  warningReason: string;
  additionalDetails?: string;
}): Promise<void> {
  const { report, targetUserId, warningReason, additionalDetails } = params;
  const safeReason = warningReason.trim() || DEFAULT_WARNING_REASON;
  const safeDetails = additionalDetails?.trim() || "";
  const message = `Your content was removed for: ${safeReason}`;

  if (report.targetType === "post") {
    await deletePost(report.targetId);
  } else if (report.targetType === "comment" && report.postId) {
    await deleteComment(report.postId, report.targetId);
  }

  await sendWarningNotification({
    userId: targetUserId,
    message,
    warningReason: safeReason,
    ...(safeDetails ? { warningDetails: safeDetails } : {}),
  });

  await updateDoc(doc(db, "reports", report.id), {
    status: "resolved",
    updatedAt: serverTimestamp(),
  });
}

export async function blockUserByAdmin(
  userId: string,
  reason?: string
): Promise<void> {
  const safeReason = reason?.trim() || DEFAULT_WARNING_REASON;
  await setAdminState(userId, {
    banned: true,
    bannedReason: safeReason,
    bannedAt: serverTimestamp(),
  });

  await sendWarningNotification({
    userId,
    message: `Your account has been suspended: ${safeReason}`,
    warningReason: safeReason,
  });
}

// `getBannedUsers`/`unbanUser` were removed — they had no callers, and
// getBannedUsers was doubly broken: a collection-group query can't filter by
// a bare documentId() ("state" is not a full doc path, the SDK throws), and
// firestore.rules exposes no collection-group read on `admin` anyway. If a
// ban-management surface is ever added, build it through an admin callable.
