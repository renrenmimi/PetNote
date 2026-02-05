import { useCallback, useEffect, useState } from "react";
import { useAuth } from "./useAuth";
import {
  checkIfFollowing,
  followUser,
  unfollowUser,
} from "../services/follow";
import { getUserProfile } from "../services/users";

type UseFollowResult = {
  isFollowing: boolean;
  followerCount: number;
  toggleFollow: () => Promise<void>;
  loading: boolean;
};

export function useFollow(targetUid: string): UseFollowResult {
  const { user } = useAuth();
  const [isFollowing, setIsFollowing] = useState(false);
  const [followerCount, setFollowerCount] = useState(0);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    let ignore = false;

    const load = async () => {
      if (!targetUid) return;
      const profile = await getUserProfile(targetUid);
      if (!ignore) {
        setFollowerCount(profile?.followerCount ?? 0);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [targetUid]);

  useEffect(() => {
    let ignore = false;
    if (!user || !targetUid || user.uid === targetUid) {
      setIsFollowing(false);
      return;
    }

    const load = async () => {
      try {
        const result = await checkIfFollowing(user.uid, targetUid);
        if (!ignore) setIsFollowing(result);
      } catch {
        if (!ignore) setIsFollowing(false);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [targetUid, user]);

  const toggleFollow = useCallback(async () => {
    if (!user || !targetUid || user.uid === targetUid || loading) return;
    setLoading(true);
    try {
      if (isFollowing) {
        await unfollowUser(user.uid, targetUid);
        setIsFollowing(false);
        setFollowerCount((prev) => Math.max(0, prev - 1));
      } else {
        await followUser(user.uid, targetUid);
        setIsFollowing(true);
        setFollowerCount((prev) => prev + 1);
      }
    } finally {
      setLoading(false);
    }
  }, [user, targetUid, isFollowing, loading]);

  return { isFollowing, followerCount, toggleFollow, loading };
}
