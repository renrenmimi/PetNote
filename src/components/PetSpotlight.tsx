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

const pawVariants = ["paw-shape-4"];
const getPawClipId = (index: number) => pawVariants[index % pawVariants.length];

const PawAvatar = ({
  src,
  seen,
  variant,
}: {
  src?: string | null;
  seen: boolean;
  variant: number;
}) => {
  const clipId = getPawClipId(variant);

  return (
    <div className="relative h-16 w-16">
      {!seen ? (
        <div
          className="absolute inset-0"
          style={{
            clipPath: `url(#${clipId})`,
            background: "linear-gradient(135deg, #8B5CF6, #EC4899, #F59E0B)",
          }}
        />
      ) : null}
      {!seen ? (
        <div
          className="absolute"
          style={{
            inset: 3,
            clipPath: `url(#${clipId})`,
            background: "white",
          }}
        />
      ) : null}
      {src ? (
        <img
          src={src}
          alt=""
          className={`absolute object-cover ${seen ? "opacity-60" : ""}`}
          style={{
            top: seen ? 0 : 5,
            left: seen ? 0 : 5,
            right: seen ? 0 : 5,
            bottom: seen ? 0 : 5,
            width: seen ? 64 : 54,
            height: seen ? 64 : 54,
            clipPath: `url(#${clipId})`,
          }}
        />
      ) : (
        <div
          className="absolute flex items-center justify-center text-white"
          style={{
            top: seen ? 0 : 5,
            left: seen ? 0 : 5,
            right: seen ? 0 : 5,
            bottom: seen ? 0 : 5,
            clipPath: `url(#${clipId})`,
            background: "linear-gradient(135deg, #8B5CF6, #EC4899)",
          }}
        >
          🐾
        </div>
      )}
      {seen ? (
        <div
          className="absolute inset-0 border border-slate-200 dark:border-slate-700"
          style={{ clipPath: `url(#${clipId})` }}
        />
      ) : null}
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
          <clipPath id="paw-shape-4" clipPathUnits="objectBoundingBox">
            <ellipse cx="0.5" cy="0.67" rx="0.39" ry="0.33" />
            <ellipse cx="0.16" cy="0.31" rx="0.14" ry="0.18" />
            <ellipse cx="0.38" cy="0.21" rx="0.13" ry="0.2" />
            <ellipse cx="0.62" cy="0.21" rx="0.13" ry="0.2" />
            <ellipse cx="0.84" cy="0.31" rx="0.14" ry="0.18" />
            <ellipse cx="0.25" cy="0.44" rx="0.16" ry="0.12" />
            <ellipse cx="0.5" cy="0.39" rx="0.22" ry="0.12" />
            <ellipse cx="0.75" cy="0.44" rx="0.16" ry="0.12" />
          </clipPath>
        </defs>
      </svg>

      {loading ? (
        <div className="mt-4 flex gap-4 overflow-x-auto pb-1">
          {Array.from({ length: 5 }).map((_, index) => (
            <div key={index} className="flex flex-col items-center gap-2">
              <div className="h-16 w-16 animate-pulse rounded-full bg-slate-200 dark:bg-slate-700" />
              <div className="h-3 w-12 animate-pulse rounded bg-slate-200 dark:bg-slate-700" />
            </div>
          ))}
        </div>
      ) : posts.length === 0 ? (
        <p className="mt-4 text-sm text-slate-500 dark:text-slate-300">
          Share your pet to get featured! 🐾
        </p>
      ) : (
        <div className="mt-4 flex gap-3 overflow-x-auto pb-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
          {sortedPosts.map((post, index) => {
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
                setSeenPosts((prev) => (prev.includes(post.id) ? prev : [...prev, post.id]));
                navigate(`/post/${post.id}`);
              }}
              className="flex w-[72px] flex-col items-center gap-2 transition-transform duration-150 active:scale-95"
            >
              <PawAvatar src={mediaUrl} seen={isSeen} variant={index} />
              <span className="text-xs text-slate-600 dark:text-slate-300">
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
