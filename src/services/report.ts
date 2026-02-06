import {
  addDoc,
  collection,
  getDocs,
  orderBy,
  query,
  serverTimestamp,
  where,
} from "firebase/firestore";
import { db } from "./firebase";

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
  const reportsRef = collection(db, "reports");
  await addDoc(reportsRef, {
    ...data,
    status: "pending",
    createdAt: serverTimestamp(),
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
