import {
  addDoc,
  collection,
  doc,
  getCountFromServer,
  getDocs,
  orderBy,
  query,
  updateDoc,
  where,
  writeBatch,
  serverTimestamp,
} from "firebase/firestore";
import { db } from "./firebase";

export type NotificationType = "like" | "comment" | "follow" | "reply";

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

export async function createNotification(
  data: CreateNotificationInput
): Promise<string> {
  const notificationsRef = collection(db, "notifications");
  const payload = {
    ...data,
    read: data.read ?? false,
    createdAt: data.createdAt ?? serverTimestamp(),
  };
  const result = await addDoc(notificationsRef, payload);
  return result.id;
}

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

export async function markAllAsRead(userId: string): Promise<void> {
  const notificationsRef = collection(db, "notifications");
  const notificationsQuery = query(
    notificationsRef,
    where("userId", "==", userId),
    where("read", "==", false)
  );
  const snapshot = await getDocs(notificationsQuery);
  const batch = writeBatch(db);
  snapshot.docs.forEach((docSnap) => {
    batch.update(docSnap.ref, { read: true });
  });
  await batch.commit();
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
