import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import {
  checkIfLiked,
  likePost,
  type Post,
  unlikePost,
} from "../services/posts";

type PostCardProps = {
  post: Post;
  useMock?: boolean;
};

const formatTimeAgo = (value: unknown) => {
  const date =
    value instanceof Date
      ? value
      : typeof value === "object" &&
        value !== null &&
        "toDate" in value &&
        typeof (value as { toDate: () => Date }).toDate === "function"
      ? (value as { toDate: () => Date }).toDate()
      : new Date();

  const diff = Date.now() - date.getTime();
  const minutes = Math.max(1, Math.floor(diff / 60000));
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
};

export function PostCard({ post, useMock = false }: PostCardProps) {
  const { user } = useAuth();
  const navigate = useNavigate();
  const [liked, setLiked] = useState(false);
  const [likeCount, setLikeCount] = useState(post.likeCount ?? 0);
  const [animating, setAnimating] = useState(false);

  const timeAgo = useMemo(() => formatTimeAgo(post.createdAt), [post.createdAt]);

  useEffect(() => {
    let ignore = false;

    const loadLiked = async () => {
      if (!user || useMock) return;
      try {
        const result = await checkIfLiked(post.id, user.uid);
        if (!ignore) {
          setLiked(result);
        }
      } catch {
        if (!ignore) {
          setLiked(false);
        }
      }
    };

    void loadLiked();

    return () => {
      ignore = true;
    };
  }, [post.id, user, useMock]);

  const handleLike = async () => {
    if (!user) {
      alert("Please login to like posts");
      navigate("/login");
      return;
    }

    setAnimating(true);
    setTimeout(() => setAnimating(false), 200);

    if (useMock) {
      setLiked((prev) => !prev);
      setLikeCount((prev) => (liked ? Math.max(0, prev - 1) : prev + 1));
      return;
    }

    try {
      if (liked) {
        await unlikePost(post.id, user.uid);
        setLiked(false);
        setLikeCount((prev) => Math.max(0, prev - 1));
      } else {
        await likePost(post.id, user.uid);
        setLiked(true);
        setLikeCount((prev) => prev + 1);
      }
    } catch {
      // noop for now
    }
  };

  return (
    <article className="overflow-hidden rounded-2xl bg-white shadow-sm ring-1 ring-slate-100">
      <header className="flex items-center gap-3 px-4 py-3">
        <img
          src={post.authorAvatar}
          alt={post.authorName}
          className="h-10 w-10 rounded-full object-cover"
        />
        <div className="flex flex-1 items-center justify-between">
          <div>
            <p className="text-sm font-semibold text-slate-900">
              {post.authorName}
            </p>
            <p className="text-xs text-slate-500">{timeAgo}</p>
          </div>
          <button
            type="button"
            className="text-xl text-slate-400 hover:text-slate-600"
            aria-label="Post options"
          >
            ⋯
          </button>
        </div>
      </header>

      <div className="aspect-video w-full bg-slate-100">
        {post.mediaType === "video" ? (
          <video
            src={post.mediaUrl}
            controls
            className="h-full w-full object-cover"
          />
        ) : (
          <img
            src={post.mediaUrl}
            alt={post.text}
            className="h-full w-full object-cover"
          />
        )}
      </div>

      <div className="px-4 pb-4 pt-3">
        <div className="flex items-center gap-4 text-slate-600">
          <button
            type="button"
            onClick={handleLike}
            className={`text-2xl transition ${
              animating ? "scale-110" : "scale-100"
            } ${liked ? "text-red-500" : "text-slate-500"}`}
            aria-label="Like"
          >
            {liked ? "❤️" : "🤍"}
          </button>
          <button
            type="button"
            className="text-2xl text-slate-500"
            aria-label="Comment"
          >
            💬
          </button>
        </div>

        <p className="mt-2 text-sm font-semibold text-slate-900">
          {likeCount} likes
        </p>

        <p className="mt-2 text-sm text-slate-700">
          <span className="font-semibold text-slate-900">
            {post.authorName}
          </span>{" "}
          {post.text}
        </p>

        <div className="mt-3 flex flex-wrap gap-2 text-xs">
          {post.tags.map((tag) => (
            <button
              key={tag}
              type="button"
              className="rounded-full bg-purple-50 px-2 py-1 font-semibold text-purple-600 hover:bg-purple-100"
            >
              #{tag}
            </button>
          ))}
        </div>
      </div>
    </article>
  );
}
