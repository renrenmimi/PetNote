import { useCallback, useEffect, useState } from "react";
import { checkIfLiked, likePost, unlikePost } from "../services/posts";

type UseLikeResult = {
  isLiked: boolean;
  likeCount: number;
  toggleLike: () => Promise<void>;
  loading: boolean;
};

export function useLike(
  postId: string,
  userId: string | null,
  initialCount = 0
): UseLikeResult {
  const [isLiked, setIsLiked] = useState(false);
  const [likeCount, setLikeCount] = useState(initialCount);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    setLikeCount(initialCount);
  }, [initialCount]);

  useEffect(() => {
    let ignore = false;
    if (!userId) {
      setIsLiked(false);
      return;
    }

    const load = async () => {
      try {
        const liked = await checkIfLiked(postId, userId);
        if (!ignore) setIsLiked(liked);
      } catch {
        if (!ignore) setIsLiked(false);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [postId, userId]);

  const toggleLike = useCallback(async () => {
    if (!userId || loading) return;
    setLoading(true);

    try {
      if (isLiked) {
        await unlikePost(postId, userId);
        setIsLiked(false);
        setLikeCount((prev) => Math.max(0, prev - 1));
      } else {
        await likePost(postId, userId);
        setIsLiked(true);
        setLikeCount((prev) => prev + 1);
      }
    } finally {
      setLoading(false);
    }
  }, [isLiked, loading, postId, userId]);

  return { isLiked, likeCount, toggleLike, loading };
}
