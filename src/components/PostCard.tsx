import { useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { useLike } from "../hooks/useLike";
import { type Post } from "../services/posts";
import { CommentSection } from "./CommentSection";

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
  const minutes = Math.floor(diff / 60000);
  if (minutes <= 0) return "Just now";
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days === 1) return "Yesterday";
  if (days < 7) return `${days}d ago`;
  return date.toLocaleDateString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
};

export function PostCard({ post, useMock = false }: PostCardProps) {
  const { user } = useAuth();
  const navigate = useNavigate();
  const [animating, setAnimating] = useState(false);
  const [showComments, setShowComments] = useState(false);
  const [localLiked, setLocalLiked] = useState(false);
  const [localLikeCount, setLocalLikeCount] = useState(post.likeCount ?? 0);
  const [localCommentCount, setLocalCommentCount] = useState(
    post.commentCount ?? 0
  );
  const [imageLoaded, setImageLoaded] = useState(false);
  const [showHeart, setShowHeart] = useState(false);

  const { isLiked, likeCount, toggleLike } = useLike(
    post.id,
    useMock ? null : user?.uid ?? null,
    post.likeCount ?? 0
  );

  const timeAgo = useMemo(() => formatTimeAgo(post.createdAt), [post.createdAt]);

  const handleLike = async () => {
    if (!user) {
      alert("Please login to like posts");
      navigate("/login");
      return;
    }

    setAnimating(true);
    setTimeout(() => setAnimating(false), 200);

    if (useMock) {
      setLocalLiked((prev) => {
        setLocalLikeCount((count) =>
          prev ? Math.max(0, count - 1) : count + 1
        );
        return !prev;
      });
      return;
    }

    try {
      await toggleLike();
    } catch {
      // noop for now
    }
  };

  const handleDoubleLike = async () => {
    setShowHeart(true);
    setTimeout(() => setShowHeart(false), 500);
    if (!likedState) {
      await handleLike();
    }
  };

  const likedState = useMock ? localLiked : isLiked;
  const likeTotal = useMock ? localLikeCount : likeCount;
  const commentTotal = localCommentCount;

  const HeartIcon = ({ filled }: { filled: boolean }) => {
    const gradientId = `heart-${post.id}`;
    return (
      <svg
        className={`h-6 w-6 ${
          filled ? "text-red-500" : "text-slate-500"
        }`}
        viewBox="0 0 24 24"
        fill={filled ? `url(#${gradientId})` : "none"}
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <defs>
          <linearGradient id={gradientId} x1="0" x2="1" y1="0" y2="1">
            <stop offset="0%" stopColor="#a855f7" />
            <stop offset="100%" stopColor="#ec4899" />
          </linearGradient>
        </defs>
        <path d="M20.8 6.6a5.5 5.5 0 0 0-7.8 0l-1 1-1-1a5.5 5.5 0 1 0-7.8 7.8l1 1L12 21l7.8-5.6 1-1a5.5 5.5 0 0 0 0-7.8Z" />
      </svg>
    );
  };

  return (
    <article className="overflow-hidden rounded-2xl bg-white shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 transition-all duration-200 hover:-translate-y-0.5 hover:shadow-[0_22px_45px_-28px_rgba(15,23,42,0.45)]">
      <header className="flex items-center gap-3 px-4 py-3">
        <button
          type="button"
          onClick={() => navigate(`/profile/${post.authorId}`)}
          className="transition-transform duration-200 hover:scale-105"
        >
          <img
            src={post.authorAvatar}
            alt={post.authorName}
            className="h-10 w-10 rounded-full object-cover"
          />
        </button>
        <div className="flex flex-1 items-center justify-between">
          <div>
            <button
              type="button"
              onClick={() => navigate(`/profile/${post.authorId}`)}
              className="text-sm font-semibold text-slate-900 transition-all duration-200 hover:text-purple-600"
            >
              {post.authorName}
            </button>
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

      <div
        className="relative aspect-video w-full bg-slate-100"
        onDoubleClick={handleDoubleLike}
      >
        {!imageLoaded ? (
          <div className="absolute inset-0 animate-pulse bg-slate-200" />
        ) : null}
        {showHeart ? (
          <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
            <span className="text-6xl text-red-500 animate-[pulse_0.6s_ease-out]">
              ❤️
            </span>
          </div>
        ) : null}
        {post.mediaType === "video" ? (
          <video
            src={post.mediaUrl}
            controls
            className="h-full w-full object-cover"
            onLoadedData={() => setImageLoaded(true)}
          />
        ) : (
          <img
            src={post.mediaUrl}
            alt={post.text}
            className={`h-full w-full object-cover transition-opacity duration-300 ${
              imageLoaded ? "opacity-100" : "opacity-0"
            }`}
            onLoad={() => setImageLoaded(true)}
          />
        )}
      </div>

      <div className="px-4 pb-4 pt-3">
        <div className="flex items-center gap-4 text-slate-600">
          <button
            type="button"
            onClick={handleLike}
            className={`text-2xl transition-all duration-200 ${
              animating ? "scale-110" : "scale-100"
            } ${likedState ? "text-red-500" : "text-slate-500"}`}
            aria-label="Like"
          >
            <HeartIcon filled={likedState} />
          </button>
          <button
            type="button"
            className="text-2xl text-slate-500 transition-all duration-200 hover:scale-105"
            aria-label="Comment"
            onClick={() => setShowComments((prev) => !prev)}
          >
            💬
          </button>
        </div>

        <p className="mt-2 text-sm font-semibold text-slate-900">
          {likeTotal} likes
        </p>
        <p className="mt-1 text-xs text-slate-400">
          {commentTotal} comments
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
              className="rounded-full bg-purple-50 px-2 py-1 font-semibold text-purple-600 transition-all duration-200 hover:scale-105 hover:bg-purple-100"
            >
              #{tag}
            </button>
          ))}
        </div>

        {showComments ? (
          <CommentSection
            postId={post.id}
            commentCount={commentTotal}
            onCommentAdded={() =>
              setLocalCommentCount((prev) => prev + 1)
            }
          />
        ) : null}
      </div>
    </article>
  );
}
