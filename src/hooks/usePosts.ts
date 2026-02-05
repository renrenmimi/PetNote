import { useCallback, useEffect, useState } from "react";
import { getPosts, type Post } from "../services/posts";

type UsePostsResult = {
  posts: Post[];
  loading: boolean;
  error: string | null;
  refresh: () => Promise<void>;
};

export function usePosts(): UsePostsResult {
  const [posts, setPosts] = useState<Post[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const loadPosts = useCallback(async () => {
    setLoading(true);
    setError(null);

    try {
      const data = await getPosts();
      setPosts(data);
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

  return {
    posts,
    loading,
    error,
    refresh: loadPosts,
  };
}
