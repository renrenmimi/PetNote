import { useCallback, useEffect, useState } from "react";
import {
  collection,
  onSnapshot,
  orderBy,
  query,
  where,
} from "firebase/firestore";
import { db } from "../services/firebase";
import {
  markAllAsRead as markAll,
  markAsRead as markOne,
  type NotificationItem,
} from "../services/notifications";

type UseNotificationsResult = {
  notifications: NotificationItem[];
  unreadCount: number;
  loading: boolean;
  markAsRead: (id: string) => Promise<void>;
  markAllAsRead: () => Promise<void>;
};

export function useNotifications(
  userId: string | null
): UseNotificationsResult {
  const [notifications, setNotifications] = useState<NotificationItem[]>([]);
  const [unreadCount, setUnreadCount] = useState(0);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!userId) {
      setNotifications([]);
      setUnreadCount(0);
      setLoading(false);
      return;
    }

    const notificationsRef = collection(db, "notifications");
    const notificationsQuery = query(
      notificationsRef,
      where("userId", "==", userId),
      orderBy("createdAt", "desc")
    );

    const unsubscribe = onSnapshot(notificationsQuery, (snapshot) => {
      const list = snapshot.docs.map((docSnap) => ({
        id: docSnap.id,
        ...(docSnap.data() as Omit<NotificationItem, "id">),
      }));
      setNotifications(list);
      setUnreadCount(list.filter((item) => !item.read).length);
      setLoading(false);
    });

    return () => unsubscribe();
  }, [userId]);

  const markAsRead = useCallback(
    async (id: string) => {
      let shouldDecrement = false;
      setNotifications((prev) =>
        prev.map((item) => {
          if (item.id === id && !item.read) {
            shouldDecrement = true;
            return { ...item, read: true };
          }
          return item;
        })
      );
      if (shouldDecrement) {
        setUnreadCount((prev) => Math.max(0, prev - 1));
      }
      await markOne(id);
    },
    [setNotifications]
  );

  const markAllAsRead = useCallback(async () => {
    if (!userId) return;
    await markAll(userId);
    setNotifications((prev) =>
      prev.map((item) => ({ ...item, read: true }))
    );
    setUnreadCount(0);
  }, [userId]);

  return { notifications, unreadCount, loading, markAsRead, markAllAsRead };
}
