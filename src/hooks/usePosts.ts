import { useCallback, useEffect, useState } from "react";
import type { QueryDocumentSnapshot } from "firebase/firestore";
import { getPosts, type Post } from "../services/posts";

type UsePostsResult = {
  posts: Post[];
  loading: boolean;
  loadingMore: boolean;
  hasMore: boolean;
  error: string | null;
  loadMore: () => Promise<void>;
  refresh: () => Promise<void>;
};

export function usePosts(): UsePostsResult {
  const [posts, setPosts] = useState<Post[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [hasMore, setHasMore] = useState(true);
  const [lastDoc, setLastDoc] = useState<QueryDocumentSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);

  const loadPosts = useCallback(async () => {
    setLoading(true);
    setError(null);
    setPosts([]);
    setLastDoc(null);

    try {
      const { posts: data, lastDoc: lastVisible, hasMore: more } =
        await getPosts(10);
      setPosts(data);
      setLastDoc(lastVisible);
      setHasMore(more);
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to load posts";
      setError(message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadPosts();
  }, [loadPosts]);

  const loadMore = useCallback(async () => {
    if (loadingMore || loading || !hasMore || !lastDoc) return;
    setLoadingMore(true);
    setError(null);
    try {
      const { posts: data, lastDoc: lastVisible, hasMore: more } =
        await getPosts(10, lastDoc);
      setPosts((prev) => [...prev, ...data]);
      setLastDoc(lastVisible);
      setHasMore(more);
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to load more posts";
      setError(message);
    } finally {
      setLoadingMore(false);
    }
  }, [hasMore, lastDoc, loading, loadingMore]);

  return {
    posts,
    loading,
    loadingMore,
    hasMore,
    error,
    loadMore,
    refresh: loadPosts,
  };
}
