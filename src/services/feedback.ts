import {
  addDoc,
  collection,
  deleteDoc,
  doc,
  getDocs,
  orderBy,
  query,
  serverTimestamp,
  updateDoc,
  where,
  type QueryConstraint,
} from "firebase/firestore";
import { db } from "./firebase";

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
  const ref = collection(db, "feedback");
  await addDoc(ref, {
    ...data,
    status: "new",
    createdAt: serverTimestamp(),
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
