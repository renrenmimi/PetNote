import { useCallback, useEffect, useRef, useState } from "react";
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
  userId: string | null,
  initialBookmarked?: boolean
): UseBookmarkResult {
  const [isBookmarked, setIsBookmarked] = useState(initialBookmarked ?? false);
  const [loading, setLoading] = useState(false);
  const mountedRef = useRef(true);

  useEffect(() => {
    // Set the flag back to true on every mount so React 18 StrictMode's
    // setup → cleanup → setup cycle leaves the ref pointing at the live
    // component, not the dev-only first cleanup.
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  useEffect(() => {
    if (initialBookmarked !== undefined) {
      setIsBookmarked(initialBookmarked);
    }
  }, [initialBookmarked]);

  useEffect(() => {
    let ignore = false;
    if (!userId) {
      setIsBookmarked(false);
      return;
    }
    if (initialBookmarked !== undefined) {
      return () => {
        ignore = true;
      };
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
  }, [postId, userId, initialBookmarked]);

  const toggleBookmark = useCallback(async () => {
    if (!userId || loading) return;
    setLoading(true);

    try {
      if (isBookmarked) {
        await unbookmarkPost(userId, postId);
        if (!mountedRef.current) return;
        setIsBookmarked(false);
      } else {
        await bookmarkPost(userId, postId);
        if (!mountedRef.current) return;
        setIsBookmarked(true);
      }
    } finally {
      if (mountedRef.current) {
        setLoading(false);
      }
    }
  }, [isBookmarked, loading, postId, userId]);

  return { isBookmarked, toggleBookmark, loading };
}
