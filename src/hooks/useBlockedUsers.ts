import { useCallback, useEffect, useMemo, useState } from "react";
import { collection, onSnapshot } from "firebase/firestore";
import { db } from "../services/firebase";

type UseBlockedUsersResult = {
  blockedUserIds: string[];
  isBlocked: (uid: string) => boolean;
  loading: boolean;
};

export function useBlockedUsers(userId: string | null): UseBlockedUsersResult {
  const [blockedUserIds, setBlockedUserIds] = useState<string[]>([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!userId) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setBlockedUserIds([]);
      return;
    }
    setLoading(true);
    const blockedRef = collection(db, "users", userId, "blockedUsers");
    const unsubscribe = onSnapshot(
      blockedRef,
      (snapshot) => {
        setBlockedUserIds(snapshot.docs.map((docSnap) => docSnap.id));
        setLoading(false);
      },
      (error) => {
        // A failed subscription must not leave `loading` stuck at true.
        console.warn("Failed to subscribe to blocked users:", error);
        setLoading(false);
      }
    );
    return () => unsubscribe();
  }, [userId]);

  // Build a Set once per ID change so isBlocked() is O(1). Without this
  // every consumer that called isBlocked in a render loop scanned the
  // whole array each time.
  const blockedSet = useMemo(
    () => new Set(blockedUserIds),
    [blockedUserIds]
  );
  const isBlocked = useCallback(
    (uid: string) => blockedSet.has(uid),
    [blockedSet]
  );

  return { blockedUserIds, isBlocked, loading };
}
