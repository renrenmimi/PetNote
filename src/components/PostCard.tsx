import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { useLike } from "../hooks/useLike";
import { deletePost, type Post } from "../services/posts";
import { getUserProfile } from "../services/users";
import { CommentSection } from "./CommentSection";

type PostCardProps = {
  post: Post;
  useMock?: boolean;
  onDeleted?: (postId: string) => void;
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

export function PostCard({ post, useMock = false, onDeleted }: PostCardProps) {
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
  const [menuOpen, setMenuOpen] = useState(false);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [toast, setToast] = useState<{ message: string; tone: "success" | "error" } | null>(null);
  const [hidden, setHidden] = useState(false);
  const [authorName, setAuthorName] = useState(post.authorName);
  const [authorAvatar, setAuthorAvatar] = useState(post.authorAvatar);

  const { isLiked, likeCount, toggleLike } = useLike(
    post.id,
    useMock ? null : user?.uid ?? null,
    post.likeCount ?? 0
  );

  const timeAgo = useMemo(() => formatTimeAgo(post.createdAt), [post.createdAt]);

  useEffect(() => {
    let ignore = false;
    const loadProfile = async () => {
      const profile = await getUserProfile(post.authorId);
      if (!ignore && profile) {
        setAuthorName(profile.displayName || post.authorName);
        setAuthorAvatar(profile.avatarUrl || post.authorAvatar);
      }
    };
    void loadProfile();
    return () => {
      ignore = true;
    };
  }, [post.authorId, post.authorName, post.authorAvatar]);

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

  const handleDelete = async () => {
    if (deleting) return;
    setDeleting(true);
    try {
      await deletePost(post.id);
      setToast({ message: "Post deleted", tone: "success" });
      setConfirmOpen(false);
      setMenuOpen(false);
      onDeleted?.(post.id);
      if (!onDeleted) {
        setHidden(true);
      }
    } catch (err) {
      setToast({ message: "Failed to delete post", tone: "error" });
    } finally {
      setDeleting(false);
      setTimeout(() => setToast(null), 2000);
    }
  };

  if (hidden) return null;

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
    <article className="relative overflow-hidden rounded-2xl bg-white shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 transition-all duration-200 hover:-translate-y-0.5 hover:shadow-[0_22px_45px_-28px_rgba(15,23,42,0.45)]">
      <header className="flex items-center gap-3 px-4 py-3">
        <button
          type="button"
            onClick={() => navigate(`/profile/${post.authorId}`)}
            className="transition-transform duration-200 hover:scale-105"
          >
            <img
              src={authorAvatar}
              alt={authorName}
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
              {authorName}
            </button>
            <p className="text-xs text-slate-500">{timeAgo}</p>
          </div>
          {user?.uid === post.authorId ? (
            <div className="relative">
              <button
                type="button"
                onClick={() => setMenuOpen((prev) => !prev)}
                className="text-xl text-slate-400 transition-all duration-200 hover:text-slate-600"
                aria-label="Post options"
              >
                ⋯
              </button>
              {menuOpen ? (
                <div className="absolute right-0 top-8 z-10 w-36 rounded-xl bg-white p-2 text-sm shadow-[0_12px_30px_-20px_rgba(15,23,42,0.5)] ring-1 ring-slate-100">
                  <button
                    type="button"
                    onClick={() => {
                      setMenuOpen(false);
                      setConfirmOpen(true);
                    }}
                    className="w-full rounded-lg px-3 py-2 text-left text-red-500 transition-all duration-200 hover:bg-red-50"
                  >
                    Delete Post
                  </button>
                  <button
                    type="button"
                    onClick={() => setMenuOpen(false)}
                    className="mt-1 w-full rounded-lg px-3 py-2 text-left text-slate-600 transition-all duration-200 hover:bg-slate-100"
                  >
                    Cancel
                  </button>
                </div>
              ) : null}
            </div>
          ) : null}
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
          <span className="font-semibold text-slate-900">{authorName}</span>{" "}
          {post.text}
        </p>

        <div className="mt-3 flex flex-wrap gap-2 text-xs">
          {post.tags.map((tag) => (
            <button
              key={tag}
              type="button"
              onClick={() => navigate(`/search?tag=${encodeURIComponent(tag)}`)}
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

      {confirmOpen ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-sm rounded-2xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)]">
            <h3 className="text-base font-semibold text-slate-900">
              Delete Post
            </h3>
            <p className="mt-2 text-sm text-slate-600">
              Are you sure you want to delete this post? This action cannot be
              undone.
            </p>
            <div className="mt-5 flex items-center justify-end gap-3">
              <button
                type="button"
                onClick={() => setConfirmOpen(false)}
                className="rounded-full px-4 py-2 text-sm font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-100"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={handleDelete}
                disabled={deleting}
                className="rounded-full bg-red-500 px-4 py-2 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
              >
                {deleting ? "Deleting..." : "Delete"}
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {toast ? (
        <div className="fixed bottom-6 left-1/2 z-50 -translate-x-1/2">
          <div
            className={`rounded-full px-4 py-2 text-sm font-semibold shadow-lg ${
              toast.tone === "success"
                ? "bg-emerald-500 text-white"
                : "bg-red-500 text-white"
            }`}
          >
            {toast.message}
          </div>
        </div>
      ) : null}
    </article>
  );
}
