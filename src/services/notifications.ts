import {
  collection,
  doc,
  getCountFromServer,
  getDocs,
  orderBy,
  query,
  updateDoc,
  where,
} from "firebase/firestore";
import { httpsCallable } from "firebase/functions";
import { db, functions } from "./firebase";

export type NotificationType =
  | "like"
  | "comment"
  | "follow"
  | "pet_follow"
  | "reply"
  | "meetup_join"
  | "meetup_cancelled"
  | "warning";

export type NotificationItem = {
  id: string;
  userId: string;
  type: NotificationType;
  fromUserId: string;
  fromUserName: string;
  fromUserAvatar: string;
  postId?: string;
  commentId?: string;
  postImage?: string;
  message: string;
  warningReason?: string;
  warningDetails?: string;
  read: boolean;
  createdAt: unknown;
};

export type CreateNotificationInput = Omit<
  NotificationItem,
  "id" | "createdAt" | "read"
> & {
  read?: boolean;
  createdAt?: unknown;
};

export async function getNotifications(
  userId: string
): Promise<NotificationItem[]> {
  const notificationsRef = collection(db, "notifications");
  const notificationsQuery = query(
    notificationsRef,
    where("userId", "==", userId),
    orderBy("createdAt", "desc")
  );
  const snapshot = await getDocs(notificationsQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<NotificationItem, "id">),
  }));
}

export async function markAsRead(notificationId: string): Promise<void> {
  const notificationRef = doc(db, "notifications", notificationId);
  await updateDoc(notificationRef, { read: true });
}

// Server-side cursor-paged batch update via callable. The previous
// version pulled every unread notification doc to the client first; for
// users with a large unread backlog that's hundreds of unnecessary reads
// on a single button tap. The callable derives the user from auth, so
// callers no longer need to pass a userId.
export async function markAllAsRead(): Promise<void> {
  await httpsCallable<unknown, { updated: number }>(
    functions,
    "markAllNotificationsAsReadCallable"
  )({});
}

export async function getUnreadCount(userId: string): Promise<number> {
  const notificationsRef = collection(db, "notifications");
  const notificationsQuery = query(
    notificationsRef,
    where("userId", "==", userId),
    where("read", "==", false)
  );
  const snapshot = await getCountFromServer(notificationsQuery);
  return snapshot.data().count;
}
