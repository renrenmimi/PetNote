import {
  collection,
  deleteDoc,
  doc,
  getDocs,
  limit,
  orderBy,
  query,
  startAfter,
  updateDoc,
  where,
  type QueryConstraint,
  type QueryDocumentSnapshot,
} from "firebase/firestore";
import { httpsCallable } from "firebase/functions";
import { db, functions } from "./firebase";

export type FeedbackType = "bug" | "feature" | "complaint" | "other";
export type FeedbackStatus = "new" | "read" | "resolved";

export type Feedback = {
  id: string;
  userId: string;
  userName: string;
  userEmail: string;
  type: FeedbackType;
  subject: string;
  message: string;
  status: FeedbackStatus;
  createdAt?: unknown;
};

export async function submitFeedback(data: {
  userId: string;
  userName: string;
  userEmail: string;
  type: FeedbackType;
  subject: string;
  message: string;
}): Promise<void> {
  await httpsCallable<
    { type: FeedbackType; subject: string; message: string },
    { id: string }
  >(functions, "submitFeedbackCallable")({
    type: data.type,
    subject: data.subject,
    message: data.message,
  });
}

// Admin-only feedback query. Defaults to 100 per page so the AdminPanel
// doesn't pull every feedback document on mount when the queue grows.
// Callers can paginate via lastDoc; the existing AdminPanel currently
// only consumes the first page, which is the common moderator workflow.
export async function getAllFeedback(
  options?: {
    status?: FeedbackStatus;
    limitCount?: number;
    lastDoc?: QueryDocumentSnapshot;
  }
): Promise<{
  entries: Feedback[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  const limitCount = options?.limitCount ?? 100;
  const ref = collection(db, "feedback");
  const constraints: QueryConstraint[] = [
    orderBy("createdAt", "desc"),
    limit(limitCount),
  ];
  if (options?.status) {
    constraints.unshift(where("status", "==", options.status));
  }
  if (options?.lastDoc) {
    constraints.push(startAfter(options.lastDoc));
  }
  const snapshot = await getDocs(query(ref, ...constraints));
  const entries = snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Feedback, "id">),
  }));
  const nextLast =
    (snapshot.docs[snapshot.docs.length - 1] as
      | QueryDocumentSnapshot
      | undefined) ?? null;
  return {
    entries,
    lastDoc: nextLast,
    hasMore: snapshot.docs.length === limitCount,
  };
}

export async function updateFeedbackStatus(
  feedbackId: string,
  status: FeedbackStatus
): Promise<void> {
  const ref = doc(db, "feedback", feedbackId);
  await updateDoc(ref, { status });
}

export async function deleteFeedback(feedbackId: string): Promise<void> {
  const ref = doc(db, "feedback", feedbackId);
  await deleteDoc(ref);
}
