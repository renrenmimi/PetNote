import { useCallback, useEffect, useState } from "react";
import {
  getNotifications,
  getUnreadCount,
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

  const refresh = useCallback(async () => {
    if (!userId) {
      setNotifications([]);
      setUnreadCount(0);
      setLoading(false);
      return;
    }

    setLoading(true);
    const [list, count] = await Promise.all([
      getNotifications(userId),
      getUnreadCount(userId),
    ]);
    setNotifications(list);
    setUnreadCount(count);
    setLoading(false);
  }, [userId]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

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
