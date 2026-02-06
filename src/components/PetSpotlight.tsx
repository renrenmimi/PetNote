import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { getPopularPosts, type Post } from "../services/posts";

type PetSpotlightProps = {
  limitCount?: number;
};

const truncate = (value: string, max = 8) =>
  value.length > max ? `${value.slice(0, max)}…` : value;

export function PetSpotlight({ limitCount = 10 }: PetSpotlightProps) {
  const navigate = useNavigate();
  const [posts, setPosts] = useState<Post[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let ignore = false;

    const load = async () => {
      setLoading(true);
      const recent = await getPopularPosts(limitCount, 24);
      if (!ignore && recent.length < limitCount) {
        const fallback = await getPopularPosts(limitCount, 24 * 7);
        if (!ignore) setPosts(fallback);
      } else if (!ignore) {
        setPosts(recent);
      }
      if (!ignore) setLoading(false);
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [limitCount]);

  return (
    <section className="rounded-2xl bg-white px-4 py-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 transition-all duration-200">
      <h2 className="text-sm font-semibold text-slate-900">⭐ Popular Pets</h2>

      {loading ? (
        <div className="mt-4 flex gap-4 overflow-x-auto pb-1">
          {Array.from({ length: 5 }).map((_, index) => (
            <div key={index} className="flex flex-col items-center gap-2">
              <div className="h-16 w-16 animate-pulse rounded-full bg-slate-200" />
              <div className="h-3 w-12 animate-pulse rounded bg-slate-200" />
            </div>
          ))}
        </div>
      ) : posts.length === 0 ? (
        <p className="mt-4 text-sm text-slate-500">
          Share your pet to get featured!
        </p>
      ) : (
        <div className="mt-4 flex gap-4 overflow-x-auto pb-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
          {posts.slice(0, limitCount).map((post) => (
            <button
              key={post.id}
              type="button"
              onClick={() => navigate(`/post/${post.id}`)}
              className="flex flex-col items-center gap-2 transition-all duration-200 hover:scale-105"
            >
              <span className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 p-[2px]">
                <img
                  src={post.mediaUrl}
                  alt={post.authorName}
                  className="h-16 w-16 rounded-full border-2 border-white object-cover"
                />
              </span>
              <span className="text-xs text-slate-600">
                {truncate(post.authorName || "Pet")}
              </span>
            </button>
          ))}
        </div>
      )}
    </section>
  );
}
