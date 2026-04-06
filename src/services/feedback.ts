import {
  collection,
  deleteDoc,
  doc,
  getDocs,
  orderBy,
  query,
  updateDoc,
  where,
  type QueryConstraint,
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

export async function getAllFeedback(
  status?: FeedbackStatus
): Promise<Feedback[]> {
  const ref = collection(db, "feedback");
  const constraints: QueryConstraint[] = [orderBy("createdAt", "desc")];
  if (status) {
    constraints.unshift(where("status", "==", status));
  }
  const snapshot = await getDocs(query(ref, ...constraints));
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Feedback, "id">),
  }));
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
