import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { getPopularPosts, type Post } from "../services/posts";

type PetSpotlightProps = {
  limitCount?: number;
};

const truncate = (value: string, max = 8) =>
  value.length > max ? `${value.slice(0, max)}…` : value;

const SEEN_KEY = "petnote_seen_spotlights";

const getSeenPosts = (): string[] => {
  try {
    return JSON.parse(localStorage.getItem(SEEN_KEY) || "[]");
  } catch {
    return [];
  }
};

const markAsSeen = (postId: string) => {
  const seen = getSeenPosts();
  if (!seen.includes(postId)) {
    seen.push(postId);
    if (seen.length > 100) seen.shift();
    localStorage.setItem(SEEN_KEY, JSON.stringify(seen));
  }
};

const PawAvatar = ({
  src,
  name,
  seen,
}: {
  src?: string | null;
  name: string;
  seen: boolean;
}) => {
  return (
    <div
      className="relative h-[62px] w-[62px] active:scale-95 transition-transform"
      style={{ clipPath: "url(#chubbyHeartClip)" }}
    >
      <div
        className={`absolute inset-0 ${
          seen
            ? "bg-gray-200 dark:bg-gray-700"
            : "bg-gradient-to-br from-purple-500 via-pink-500 to-orange-400"
        }`}
      />
      <div className="absolute inset-[2.5px] bg-white dark:bg-gray-900" />
      <div className="absolute inset-[4px]">
        {src ? (
          <img
            src={src}
            alt={name}
            className={`h-full w-full object-cover ${
              seen ? "opacity-70" : ""
            }`}
          />
        ) : (
          <div
            className={`h-full w-full bg-gradient-to-br from-purple-500 to-pink-500 ${
              seen ? "opacity-70" : ""
            }`}
          />
        )}
      </div>
    </div>
  );
};

export function PetSpotlight({ limitCount = 10 }: PetSpotlightProps) {
  const navigate = useNavigate();
  const [posts, setPosts] = useState<Post[]>([]);
  const [loading, setLoading] = useState(true);
  const [seenPosts, setSeenPosts] = useState<string[]>([]);

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

  useEffect(() => {
    setSeenPosts(getSeenPosts());
  }, []);

  const sortedPosts = useMemo(() => {
    const list = posts.slice(0, limitCount);
    return list.sort((a, b) => {
      const aSeen = seenPosts.includes(a.id);
      const bSeen = seenPosts.includes(b.id);
      if (aSeen && !bSeen) return 1;
      if (!aSeen && bSeen) return -1;
      return 0;
    });
  }, [posts, limitCount, seenPosts]);

  return (
    <section className="rounded-2xl bg-white px-4 py-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 transition-all duration-200 dark:bg-slate-800 dark:ring-slate-700">
      <h2 className="text-sm font-semibold text-slate-900 dark:text-white">
        ⭐ Popular Pets
      </h2>
      <svg width="0" height="0" className="absolute">
        <defs>
          <clipPath id="chubbyHeartClip" clipPathUnits="objectBoundingBox">
            <path d="M0.5,0.93 C0.1,0.7 0,0.45 0,0.3 C0,0.12 0.15,0 0.35,0 C0.48,0 0.5,0.15 0.5,0.25 C0.5,0.15 0.52,0 0.65,0 C0.85,0 1,0.12 1,0.3 C1,0.45 0.9,0.7 0.5,0.93 Z" />
          </clipPath>
        </defs>
      </svg>

      {loading ? (
        <div className="mt-4 flex gap-3 overflow-x-auto overflow-y-visible pb-2 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
          {Array.from({ length: 5 }).map((_, index) => (
            <div key={index} className="flex w-[72px] flex-col items-center gap-1.5">
              <div className="h-16 w-16 animate-pulse rounded-2xl bg-slate-200 dark:bg-slate-700" />
              <div className="h-3 w-12 animate-pulse rounded bg-slate-200 dark:bg-slate-700" />
            </div>
          ))}
        </div>
      ) : posts.length === 0 ? (
        <p className="mt-4 text-sm text-slate-500 dark:text-slate-300">
          Share your pet to get featured! 🐾
        </p>
      ) : (
        <div className="mt-4 flex gap-3 overflow-x-auto overflow-y-visible pb-2 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
          {sortedPosts.map((post) => {
            const isSeen = seenPosts.includes(post.id);
            const mediaUrl =
              post.media && post.media.length > 0
                ? post.media[0].thumbUrl || post.media[0].url
                : post.mediaUrl;

            return (
              <button
                key={post.id}
                type="button"
                onClick={() => {
                  markAsSeen(post.id);
                  setSeenPosts((prev) =>
                    prev.includes(post.id) ? prev : [...prev, post.id]
                  );
                  navigate(`/post/${post.id}`);
                }}
                className="flex flex-shrink-0 flex-col items-center"
                style={{ width: 72 }}
              >
                <PawAvatar
                  src={mediaUrl}
                  name={post.authorName || "Pet"}
                  seen={isSeen}
                />
                <span
                  className={`mt-1.5 w-full truncate text-center text-[11px] font-medium ${
                    isSeen
                      ? "text-gray-400"
                      : "text-gray-700 dark:text-gray-300"
                  }`}
                >
                  {truncate(post.authorName || "Pet")}
                </span>
              </button>
            );
          })}
        </div>
      )}
    </section>
  );
}
