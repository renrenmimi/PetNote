import { useEffect, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { PostCard } from "../components/PostCard";
import { getPostById, type Post } from "../services/posts";

export function PostDetail() {
  const navigate = useNavigate();
  const { postId } = useParams();
  const [post, setPost] = useState<Post | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let ignore = false;
    if (!postId) return;

    const load = async () => {
      setLoading(true);
      const data = await getPostById(postId);
      if (!ignore) {
        setPost(data);
        setLoading(false);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [postId]);

  return (
    <div className="min-h-screen bg-slate-50 pb-20">
      <header className="sticky top-0 z-10 border-b border-slate-200 bg-white/80 backdrop-blur">
        <div className="mx-auto flex w-full max-w-md items-center gap-3 px-4 py-3">
          <button
            type="button"
            onClick={() => navigate(-1)}
            className="text-xl text-slate-500 hover:text-slate-700"
            aria-label="Go back"
          >
            ←
          </button>
          <h1 className="text-base font-semibold text-slate-900">Post</h1>
        </div>
      </header>

      <main className="mx-auto w-full max-w-md px-4 py-4">
        {loading ? (
          <div className="rounded-2xl bg-white p-6 text-center text-sm text-slate-400 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)]">
            Loading post...
          </div>
        ) : null}
        {!loading && !post ? (
          <div className="rounded-2xl bg-white p-6 text-center text-sm text-slate-500 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)]">
            Post not found.
          </div>
        ) : null}
        {post ? <PostCard post={post} /> : null}
      </main>
    </div>
  );
}
