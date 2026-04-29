import { useCallback, useEffect, useRef, useState } from "react";
import {
  collection,
  getDocs,
  limit,
  onSnapshot,
  orderBy,
  query,
  startAfter,
  type DocumentData,
  type QueryDocumentSnapshot,
  where,
} from "firebase/firestore";
import { db } from "../services/firebase";
import {
  getUnreadCount as getUnreadTotal,
  markAllAsRead as markAll,
  markAsRead as markOne,
  type NotificationItem,
} from "../services/notifications";

const PAGE_SIZE = 50;

type UseNotificationsResult = {
  notifications: NotificationItem[];
  unreadCount: number;
  loading: boolean;
  hasMore: boolean;
  loadingMore: boolean;
  loadMore: () => Promise<void>;
  markAsRead: (id: string) => Promise<void>;
  markAllAsRead: () => Promise<void>;
};

export function useNotifications(
  userId: string | null
): UseNotificationsResult {
  const [notifications, setNotifications] = useState<NotificationItem[]>([]);
  const [unreadCount, setUnreadCount] = useState(0);
  const [loading, setLoading] = useState(true);
  const [hasMore, setHasMore] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const lastDocRef = useRef<QueryDocumentSnapshot<DocumentData> | null>(null);
  const mountedRef = useRef(true);

  useEffect(() => {
    return () => {
      mountedRef.current = false;
    };
  }, []);

  useEffect(() => {
    if (!userId) {
      setNotifications([]);
      setUnreadCount(0);
      setHasMore(false);
      setLoadingMore(false);
      lastDocRef.current = null;
      setLoading(false);
      return;
    }

    let active = true;
    setLoading(true);
    setLoadingMore(false);

    const notificationsRef = collection(db, "notifications");
    const notificationsQuery = query(
      notificationsRef,
      where("userId", "==", userId),
      orderBy("createdAt", "desc"),
      limit(PAGE_SIZE)
    );

    const refreshUnreadCount = async () => {
      try {
        const total = await getUnreadTotal(userId);
        if (active) {
          setUnreadCount(total);
        }
      } catch (error) {
        console.warn("Failed to refresh unread notification count:", error);
      }
    };

    const unsubscribe = onSnapshot(
      notificationsQuery,
      (snapshot) => {
        if (!active) {
          return;
        }
        const list = snapshot.docs.map((docSnap) => ({
          id: docSnap.id,
          ...(docSnap.data() as Omit<NotificationItem, "id">),
        }));
        const firstPageIds = new Set(list.map((item) => item.id));
        setNotifications((prev) => [
          ...list,
          ...prev.filter((item) => !firstPageIds.has(item.id)),
        ]);
        setHasMore(snapshot.docs.length === PAGE_SIZE);
        lastDocRef.current = snapshot.docs[snapshot.docs.length - 1] ?? null;
        setLoading(false);
        void refreshUnreadCount();
      },
      (error) => {
        console.warn("Failed to subscribe to notifications:", error);
        if (active) {
          setLoading(false);
        }
      }
    );

    return () => {
      active = false;
      unsubscribe();
    };
  }, [userId]);

  const loadMore = useCallback(async () => {
    if (!userId || !hasMore || !lastDocRef.current || loadingMore) {
      return;
    }

    setLoadingMore(true);
    try {
      const notificationsRef = collection(db, "notifications");
      const notificationsQuery = query(
        notificationsRef,
        where("userId", "==", userId),
        orderBy("createdAt", "desc"),
        startAfter(lastDocRef.current),
        limit(PAGE_SIZE)
      );
      const snapshot = await getDocs(notificationsQuery);
      if (!mountedRef.current) return;
      const more = snapshot.docs.map((docSnap) => ({
        id: docSnap.id,
        ...(docSnap.data() as Omit<NotificationItem, "id">),
      }));
      setNotifications((prev) => {
        const seenIds = new Set(prev.map((item) => item.id));
        return [
          ...prev,
          ...more.filter((item) => !seenIds.has(item.id)),
        ];
      });
      setHasMore(snapshot.docs.length === PAGE_SIZE);
      lastDocRef.current = snapshot.docs[snapshot.docs.length - 1] ?? lastDocRef.current;
    } finally {
      if (mountedRef.current) {
        setLoadingMore(false);
      }
    }
  }, [hasMore, loadingMore, userId]);

  const markAsRead = useCallback(
    async (id: string) => {
      let shouldDecrement = false;
      let previousUnreadCount = 0;
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
        setUnreadCount((prev) => {
          previousUnreadCount = prev;
          return Math.max(0, prev - 1);
        });
      }
      try {
        await markOne(id);
      } catch (error) {
        if (!mountedRef.current) {
          throw error;
        }
        if (shouldDecrement) {
          setNotifications((prev) =>
            prev.map((item) =>
              item.id === id ? { ...item, read: false } : item
            )
          );
          setUnreadCount(previousUnreadCount);
        }
        throw error;
      }
    },
    [setNotifications]
  );

  const markAllAsRead = useCallback(async () => {
    if (!userId) return;
    let previousNotifications: NotificationItem[] = [];
    let previousUnreadCount = 0;
    setNotifications((prev) => {
      previousNotifications = prev;
      return prev.map((item) => ({ ...item, read: true }));
    });
    setUnreadCount((prev) => {
      previousUnreadCount = prev;
      return 0;
    });
    try {
      await markAll(userId);
    } catch (error) {
      if (mountedRef.current) {
        setNotifications(previousNotifications);
        setUnreadCount(previousUnreadCount);
      }
      throw error;
    }
  }, [userId]);

  return {
    notifications,
    unreadCount,
    loading,
    hasMore,
    loadingMore,
    loadMore,
    markAsRead,
    markAllAsRead,
  };
}
