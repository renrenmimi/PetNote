import {
  collection,
  collectionGroup,
  deleteField,
  doc,
  documentId,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  serverTimestamp,
  updateDoc,
  where,
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

export async function getPendingReports(): Promise<ReportItem[]> {
  const reportsRef = collection(db, "reports");
  const reportsQuery = query(
    reportsRef,
    where("status", "==", "pending"),
    orderBy("createdAt", "desc")
  );
  const snapshot = await getDocs(reportsQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<ReportItem, "id">),
  }));
}

export async function getReviewedReports(): Promise<ReportItem[]> {
  const reportsRef = collection(db, "reports");
  const reportsQuery = query(
    reportsRef,
    where("status", "in", ["reviewed", "resolved"]),
    orderBy("createdAt", "desc")
  );
  const snapshot = await getDocs(reportsQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<ReportItem, "id">),
  }));
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
      if (report.postId) {
        const commentSnap = await getDoc(
          doc(db, "posts", report.postId, "comments", report.targetId)
        );
        if (commentSnap.exists()) {
          const commentData = commentSnap.data() as { authorId?: string };
          return commentData.authorId ?? null;
        }
      }

      const fallbackQuery = query(
        collectionGroup(db, "comments"),
        where(documentId(), "==", report.targetId),
        limit(1)
      );
      const fallbackSnapshot = await getDocs(fallbackQuery);
      if (fallbackSnapshot.empty) return null;
      const commentData = fallbackSnapshot.docs[0].data() as { authorId?: string };
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
  const message = safeDetails
    ? `Your content was removed for: ${safeReason}`
    : `Your content was removed for: ${safeReason}`;

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

export async function getBannedUsers() {
  const adminStateSnapshot = await getDocs(
    query(
      collectionGroup(db, "admin"),
      where(documentId(), "==", "state"),
      where("banned", "==", true)
    )
  );

  const adminStateEntries = (
    await Promise.all(
      adminStateSnapshot.docs.map(async (docSnap) => {
        const userId = docSnap.ref.parent.parent?.id;
        if (!userId) {
          return null;
        }
        const userSnap = await getDoc(doc(db, "users", userId));
        const userData = userSnap.exists()
          ? (userSnap.data() as Record<string, unknown>)
          : {};
        return {
          id: userId,
          ...userData,
          ...(docSnap.data() as Record<string, unknown>),
        };
      })
    )
  ).filter((entry): entry is { id: string } & Record<string, unknown> => !!entry);

  return adminStateEntries;
}

export async function unbanUser(userId: string): Promise<void> {
  await setAdminState(userId, {
    banned: false,
    bannedReason: deleteField(),
    bannedAt: deleteField(),
  });
}
