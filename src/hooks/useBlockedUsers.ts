import { useEffect, useMemo, useState } from "react";
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
      setBlockedUserIds([]);
      return;
    }
    setLoading(true);
    const blockedRef = collection(db, "users", userId, "blockedUsers");
    const unsubscribe = onSnapshot(blockedRef, (snapshot) => {
      setBlockedUserIds(snapshot.docs.map((docSnap) => docSnap.id));
      setLoading(false);
    });
    return () => unsubscribe();
  }, [userId]);

  const isBlocked = useMemo(
    () => (uid: string) => blockedUserIds.includes(uid),
    [blockedUserIds]
  );

  return { blockedUserIds, isBlocked, loading };
}
