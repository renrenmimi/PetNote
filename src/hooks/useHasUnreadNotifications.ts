import { useEffect, useState } from "react";
import { collection, limit, onSnapshot, query, where } from "firebase/firestore";
import { db } from "../services/firebase";

type UseHasUnreadNotificationsResult = {
  hasUnread: boolean;
};

export function useHasUnreadNotifications(
  userId: string | null
): UseHasUnreadNotificationsResult {
  const [hasUnread, setHasUnread] = useState(false);

  useEffect(() => {
    if (!userId) {
      return;
    }

    const unreadQuery = query(
      collection(db, "notifications"),
      where("userId", "==", userId),
      where("read", "==", false),
      limit(1)
    );

    const unsubscribe = onSnapshot(
      unreadQuery,
      (snapshot) => {
        setHasUnread(!snapshot.empty);
      },
      (error) => {
        console.warn("Failed to subscribe to unread notifications:", error);
        setHasUnread(false);
      }
    );

    return () => unsubscribe();
  }, [userId]);

  return { hasUnread: userId ? hasUnread : false };
}
