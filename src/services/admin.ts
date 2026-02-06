import {
  collection,
  doc,
  getDoc,
  getDocs,
  orderBy,
  query,
  serverTimestamp,
  updateDoc,
  where,
} from "firebase/firestore";
import { db } from "./firebase";
import { deleteComment, deletePost } from "./posts";
import { type ReportItem } from "./report";

export type ResolveAction = "delete" | "ban" | "dismiss";

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
    let targetUserId: string | null = null;
    if (data.targetType === "user") {
      targetUserId = data.targetId;
    }
    if (data.targetType === "post") {
      const postRef = doc(db, "posts", data.targetId);
      const postSnap = await getDoc(postRef);
      if (postSnap.exists()) {
        const postData = postSnap.data() as { authorId?: string };
        targetUserId = postData.authorId ?? null;
      }
    }
    if (data.targetType === "comment" && data.postId) {
      const commentRef = doc(db, "posts", data.postId, "comments", data.targetId);
      const commentSnap = await getDoc(commentRef);
      if (commentSnap.exists()) {
        const commentData = commentSnap.data() as { authorId?: string };
        targetUserId = commentData.authorId ?? null;
      }
    }
    if (targetUserId) {
      const userRef = doc(db, "users", targetUserId);
      await updateDoc(userRef, { banned: true, bannedAt: serverTimestamp() });
    }
  }

  const status = action === "dismiss" ? "resolved" : "reviewed";
  await updateDoc(reportRef, { status, updatedAt: serverTimestamp() });
}

export async function getBannedUsers() {
  const usersRef = collection(db, "users");
  const usersQuery = query(usersRef, where("banned", "==", true));
  const snapshot = await getDocs(usersQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Record<string, unknown>),
  }));
}

export async function unbanUser(userId: string): Promise<void> {
  const userRef = doc(db, "users", userId);
  await updateDoc(userRef, { banned: false });
}
