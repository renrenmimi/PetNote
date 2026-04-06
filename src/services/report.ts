import {
  collection,
  getDocs,
  orderBy,
  query,
  where,
} from "firebase/firestore";
import { httpsCallable } from "firebase/functions";
import { db, functions } from "./firebase";

export type ReportTargetType = "post" | "comment" | "user";

export type ReportInput = {
  reporterId: string;
  reporterName: string;
  reporterAvatar?: string;
  targetType: ReportTargetType;
  targetId: string;
  reason: string;
  description?: string;
};

export type ReportItem = ReportInput & {
  id: string;
  status: "pending" | "reviewed" | "resolved";
  createdAt?: unknown;
  postId?: string;
};

export async function reportContent(data: ReportInput): Promise<void> {
  await httpsCallable<
    {
      targetType: ReportTargetType;
      targetId: string;
      reason: string;
      description?: string;
    },
    { id: string }
  >(functions, "reportContentCallable")({
    targetType: data.targetType,
    targetId: data.targetId,
    reason: data.reason,
    description: data.description,
  });
}

export async function getReportsByUser(userId: string) {
  const reportsRef = collection(db, "reports");
  const reportsQuery = query(
    reportsRef,
    where("reporterId", "==", userId),
    orderBy("createdAt", "desc")
  );
  const snapshot = await getDocs(reportsQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Record<string, unknown>),
  }));
}
