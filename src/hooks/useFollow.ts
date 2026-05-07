import { useCallback, useEffect, useRef, useState } from "react";
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

export function useFollowPet(
  petId: string,
  options: { initialFollowing?: boolean; fetchFollowerCount?: boolean } = {}
): UseFollowResult {
  const { user } = useAuth();
  const { initialFollowing, fetchFollowerCount = true } = options;
  const [isFollowing, setIsFollowing] = useState(initialFollowing ?? false);
  const [followerCount, setFollowerCount] = useState(0);
  const [loading, setLoading] = useState(false);
  const mountedRef = useRef(true);
  const userId = user?.uid ?? null;

  useEffect(() => {
    // Re-arm the flag on each mount; StrictMode's setup→cleanup→setup
    // would otherwise leave it false after the first dev-only cleanup.
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  useEffect(() => {
    let ignore = false;
    if (!petId || !fetchFollowerCount) {
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
  }, [petId, fetchFollowerCount]);

  useEffect(() => {
    if (initialFollowing !== undefined) {
      setIsFollowing(initialFollowing);
    }
  }, [initialFollowing]);

  useEffect(() => {
    let ignore = false;
    if (!userId || !petId) {
      setIsFollowing(false);
      return;
    }
    // When a batched initial state is supplied, skip the per-card lookup.
    if (initialFollowing !== undefined) {
      return;
    }

    const load = async () => {
      try {
        const result = await checkIfFollowingPet(userId, petId);
        if (!ignore) setIsFollowing(result);
      } catch {
        if (!ignore) setIsFollowing(false);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [petId, userId, initialFollowing]);

  const toggleFollow = useCallback(async () => {
    if (!userId || !petId || loading) return;
    setLoading(true);
    try {
      if (isFollowing) {
        await unfollowPet(userId, petId);
        if (!mountedRef.current) return;
        setIsFollowing(false);
        setFollowerCount((prev) => Math.max(0, prev - 1));
      } else {
        await followPet(userId, petId);
        if (!mountedRef.current) return;
        setIsFollowing(true);
        setFollowerCount((prev) => prev + 1);
      }
    } finally {
      if (mountedRef.current) {
        setLoading(false);
      }
    }
  }, [isFollowing, loading, petId, userId]);

  return { isFollowing, followerCount, toggleFollow, loading };
}

export const useFollow = useFollowPet;
