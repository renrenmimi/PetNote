import { useCallback, useEffect, useState } from "react";
import {
  bookmarkPost,
  checkIfBookmarked,
  unbookmarkPost,
} from "../services/bookmarks";

type UseBookmarkResult = {
  isBookmarked: boolean;
  toggleBookmark: () => Promise<void>;
  loading: boolean;
};

export function useBookmark(
  postId: string,
  userId: string | null
): UseBookmarkResult {
  const [isBookmarked, setIsBookmarked] = useState(false);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    let ignore = false;
    if (!userId) {
      setIsBookmarked(false);
      return;
    }

    const load = async () => {
      try {
        const bookmarked = await checkIfBookmarked(userId, postId);
        if (!ignore) setIsBookmarked(bookmarked);
      } catch {
        if (!ignore) setIsBookmarked(false);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [postId, userId]);

  const toggleBookmark = useCallback(async () => {
    if (!userId || loading) return;
    setLoading(true);

    try {
      if (isBookmarked) {
        await unbookmarkPost(userId, postId);
        setIsBookmarked(false);
      } else {
        await bookmarkPost(userId, postId);
        setIsBookmarked(true);
      }
    } finally {
      setLoading(false);
    }
  }, [isBookmarked, loading, postId, userId]);

  return { isBookmarked, toggleBookmark, loading };
}
