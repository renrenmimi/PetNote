import { useCallback, useEffect, useState } from "react";
import { useAuth } from "./useAuth";
import {
  checkIfFollowingPet,
  followPet,
  unfollowPet,
} from "../services/follow";
import { getPetById } from "../services/pets";

type UseFollowResult = {
  isFollowing: boolean;
  followerCount: number;
  toggleFollow: () => Promise<void>;
  loading: boolean;
};

export function useFollowPet(petId: string): UseFollowResult {
  const { user } = useAuth();
  const [isFollowing, setIsFollowing] = useState(false);
  const [followerCount, setFollowerCount] = useState(0);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    let ignore = false;
    if (!petId) {
      setFollowerCount(0);
      return;
    }

    const load = async () => {
      const pet = await getPetById(petId);
      if (!ignore) {
        setFollowerCount(pet?.followerCount ?? 0);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [petId]);

  useEffect(() => {
    let ignore = false;
    if (!user || !petId) {
      setIsFollowing(false);
      return;
    }

    const load = async () => {
      try {
        const result = await checkIfFollowingPet(user.uid, petId);
        if (!ignore) setIsFollowing(result);
      } catch {
        if (!ignore) setIsFollowing(false);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [petId, user]);

  const toggleFollow = useCallback(async () => {
    if (!user || !petId || loading) return;
    setLoading(true);
    try {
      if (isFollowing) {
        await unfollowPet(user.uid, petId);
        setIsFollowing(false);
        setFollowerCount((prev) => Math.max(0, prev - 1));
      } else {
        await followPet(user.uid, petId);
        setIsFollowing(true);
        setFollowerCount((prev) => prev + 1);
      }
    } finally {
      setLoading(false);
    }
  }, [isFollowing, loading, petId, user]);

  return { isFollowing, followerCount, toggleFollow, loading };
}

export const useFollow = useFollowPet;
