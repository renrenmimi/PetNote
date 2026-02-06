import { useCallback, useEffect, useMemo, useState } from "react";
import type { QueryDocumentSnapshot } from "firebase/firestore";
import { getFollowingPosts, getPosts, type Post } from "../services/posts";

type UsePostsResult = {
  posts: Post[];
  loading: boolean;
  loadingMore: boolean;
  hasMore: boolean;
  error: string | null;
  loadMore: () => Promise<void>;
  refresh: () => Promise<void>;
};

export type FeedMode = "all" | "following";

type FeedState = {
  posts: Post[];
  loading: boolean;
  loadingMore: boolean;
  hasMore: boolean;
  lastDoc: QueryDocumentSnapshot | null;
  error: string | null;
  initialized: boolean;
  ownerId?: string | null;
};

const createState = (): FeedState => ({
  posts: [],
  loading: false,
  loadingMore: false,
  hasMore: true,
  lastDoc: null,
  error: null,
  initialized: false,
  ownerId: null,
});

export function usePosts(mode: FeedMode = "all", userId?: string | null): UsePostsResult {
  const [feeds, setFeeds] = useState({
    all: createState(),
    following: createState(),
  });

  const activeFeed = useMemo(() => feeds[mode], [feeds, mode]);

  const fetchPosts = useCallback(
    async (targetMode: FeedMode, lastDoc?: QueryDocumentSnapshot | null) => {
      if (targetMode === "following") {
        if (!userId) {
          return { posts: [], lastDoc: null, hasMore: false };
        }
        return getFollowingPosts(userId, 10, lastDoc ?? undefined);
      }
      return getPosts(10, lastDoc ?? undefined);
    },
    [userId]
  );

  const loadPosts = useCallback(
    async (targetMode: FeedMode, reset = false) => {
      setFeeds((prev) => ({
        ...prev,
        [targetMode]: {
          ...prev[targetMode],
          posts: reset ? [] : prev[targetMode].posts,
          loading: true,
          loadingMore: false,
          error: null,
          hasMore: reset ? true : prev[targetMode].hasMore,
          lastDoc: reset ? null : prev[targetMode].lastDoc,
          initialized: true,
          ownerId: targetMode === "following" ? userId ?? null : null,
        },
      }));

      try {
        const { posts, lastDoc, hasMore } = await fetchPosts(targetMode, null);
        setFeeds((prev) => ({
          ...prev,
          [targetMode]: {
            ...prev[targetMode],
            posts,
            lastDoc,
            hasMore,
            loading: false,
          },
        }));
      } catch (err) {
        const message =
          err instanceof Error ? err.message : "Failed to load posts";
        setFeeds((prev) => ({
          ...prev,
          [targetMode]: {
            ...prev[targetMode],
            error: message,
            loading: false,
          },
        }));
      }
    },
    [fetchPosts, userId]
  );

  useEffect(() => {
    if (mode === "following" && !userId) {
      setFeeds((prev) => ({
        ...prev,
        following: {
          ...prev.following,
          posts: [],
          loading: false,
          loadingMore: false,
          hasMore: false,
          lastDoc: null,
          error: null,
          initialized: true,
          ownerId: null,
        },
      }));
      return;
    }

    if (!activeFeed.initialized) {
      void loadPosts(mode, true);
      return;
    }

    if (mode === "following" && activeFeed.ownerId !== userId) {
      void loadPosts(mode, true);
    }
  }, [activeFeed.initialized, activeFeed.ownerId, loadPosts, mode, userId]);

  const loadMore = useCallback(async () => {
    if (
      activeFeed.loading ||
      activeFeed.loadingMore ||
      !activeFeed.hasMore ||
      !activeFeed.lastDoc
    ) {
      return;
    }

    setFeeds((prev) => ({
      ...prev,
      [mode]: {
        ...prev[mode],
        loadingMore: true,
        error: null,
      },
    }));

    try {
      const { posts, lastDoc, hasMore } = await fetchPosts(
        mode,
        activeFeed.lastDoc
      );
      setFeeds((prev) => ({
        ...prev,
        [mode]: {
          ...prev[mode],
          posts: [...prev[mode].posts, ...posts],
          lastDoc,
          hasMore,
          loadingMore: false,
        },
      }));
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to load more posts";
      setFeeds((prev) => ({
        ...prev,
        [mode]: {
          ...prev[mode],
          error: message,
          loadingMore: false,
        },
      }));
    }
  }, [activeFeed.hasMore, activeFeed.lastDoc, activeFeed.loading, activeFeed.loadingMore, fetchPosts, mode]);

  const refresh = useCallback(async () => {
    await loadPosts(mode, true);
  }, [loadPosts, mode]);

  return {
    posts: activeFeed.posts,
    loading: activeFeed.loading,
    loadingMore: activeFeed.loadingMore,
    hasMore: activeFeed.hasMore,
    error: activeFeed.error,
    loadMore,
    refresh,
  };
}
