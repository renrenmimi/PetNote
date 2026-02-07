import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { useLike } from "../hooks/useLike";
import { useBookmark } from "../hooks/useBookmark";
import { blockUser } from "../services/block";
import { deletePost, type Post } from "../services/posts";
import { getUserProfile } from "../services/users";
import { MediaCarousel } from "./MediaCarousel";
import { ReportModal } from "./ReportModal";
import { ShareMenu } from "./ShareMenu";

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
  const { user, isBanned } = useAuth();
  const navigate = useNavigate();
  const [animating, setAnimating] = useState(false);
  const [localLiked, setLocalLiked] = useState(false);
  const [localLikeCount, setLocalLikeCount] = useState(post.likeCount ?? 0);
  const [showHeart, setShowHeart] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [toast, setToast] = useState<{ message: string; tone: "success" | "error" } | null>(null);
  const [hidden, setHidden] = useState(false);
  const [authorName, setAuthorName] = useState(post.authorName);
  const [authorAvatar, setAuthorAvatar] = useState(post.authorAvatar);
  const [bookmarkAnimating, setBookmarkAnimating] = useState(false);
  const [shareOpen, setShareOpen] = useState(false);
  const [reportOpen, setReportOpen] = useState(false);
  const [blockConfirmOpen, setBlockConfirmOpen] = useState(false);
  const [blocking, setBlocking] = useState(false);

  const { isLiked, likeCount, toggleLike } = useLike(
    post.id,
    useMock ? null : user?.uid ?? null,
    post.likeCount ?? 0
  );

  const { isBookmarked, toggleBookmark } = useBookmark(
    post.id,
    useMock ? null : user?.uid ?? null
  );

  const timeAgo = useMemo(() => formatTimeAgo(post.createdAt), [post.createdAt]);
  const mediaItems = useMemo(() => {
    if (post.media && post.media.length > 0) {
      return post.media;
    }
    if (post.mediaUrl) {
      return [
        {
          url: post.mediaUrl,
          type: post.mediaType || "image",
        },
      ];
    }
    return [];
  }, [post.media, post.mediaType, post.mediaUrl]);

  const likedState = useMock ? localLiked : isLiked;
  const likeTotal = useMock ? localLikeCount : likeCount;
  const commentTotal = post.commentCount ?? 0;
  const isOwner = user?.uid === post.authorId;

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
    if (isBanned) {
      setToast({ message: "Your account has been suspended", tone: "error" });
      setTimeout(() => setToast(null), 2000);
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

  const handleBlock = async () => {
    if (!user || blocking) return;
    setBlocking(true);
    try {
      await blockUser(user.uid, post.authorId);
      setToast({ message: "User blocked", tone: "success" });
      setBlockConfirmOpen(false);
    } catch {
      setToast({ message: "Failed to block user", tone: "error" });
    } finally {
      setBlocking(false);
      setTimeout(() => setToast(null), 2000);
    }
  };

  const handleBookmark = async () => {
    if (!user) {
      alert("Please login to save posts");
      navigate("/login");
      return;
    }
    setBookmarkAnimating(true);
    setTimeout(() => setBookmarkAnimating(false), 200);
    try {
      await toggleBookmark();
    } catch {
      // ignore
    }
  };

  if (hidden) return null;

  const HeartIcon = ({ filled }: { filled: boolean }) => {
    const gradientId = `heart-${post.id}`;
    return (
      <svg
        className={`h-6 w-6 ${
          filled ? "text-red-500" : "text-slate-500 dark:text-slate-400"
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

  const BookmarkIcon = ({ filled }: { filled: boolean }) => {
    return (
      <svg
        className={`h-6 w-6 ${
          filled ? "text-purple-500" : "text-slate-500 dark:text-slate-400"
        }`}
        viewBox="0 0 24 24"
        fill={filled ? "currentColor" : "none"}
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <path d="M6 3h12a1 1 0 0 1 1 1v17l-7-4-7 4V4a1 1 0 0 1 1-1z" />
      </svg>
    );
  };

  const ShareIcon = () => (
    <svg
      className="h-6 w-6 text-slate-500 dark:text-slate-400"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M22 2L11 13" />
      <path d="M22 2L15 22l-4-9-9-4Z" />
    </svg>
  );

  return (
    <article className="relative overflow-hidden rounded-2xl bg-white shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 transition-all duration-200 hover:-translate-y-0.5 hover:shadow-[0_22px_45px_-28px_rgba(15,23,42,0.45)] dark:bg-slate-800 dark:ring-slate-700">
      <header className="flex items-center gap-3 px-4 py-3">
        <button
          type="button"
          onClick={() => navigate(`/profile/${post.authorId}`)}
          className="transition-transform duration-200 hover:scale-105"
        >
          <div className="relative">
            <img
              src={authorAvatar}
              alt={authorName}
              className="h-10 w-10 rounded-full object-cover"
            />
            {post.petId ? (
              <div className="absolute -bottom-1 -right-1 rounded-full bg-white p-0.5 dark:bg-slate-800">
                {post.petAvatarUrl ? (
                  <img
                    src={post.petAvatarUrl}
                    alt={post.petName || "Pet"}
                    className="h-4 w-4 rounded-full object-cover"
                  />
                ) : (
                  <span className="flex h-4 w-4 items-center justify-center rounded-full bg-purple-100 text-[10px] text-purple-600 dark:bg-purple-500/20 dark:text-purple-300">
                    🐾
                  </span>
                )}
              </div>
            ) : null}
          </div>
        </button>
        <div className="flex flex-1 items-center justify-between">
          <div>
            <div className="flex flex-wrap items-center gap-1">
              <button
                type="button"
                onClick={() => navigate(`/profile/${post.authorId}`)}
                className="text-sm font-semibold text-slate-900 transition-all duration-200 hover:text-purple-600 dark:text-white"
              >
                {authorName}
              </button>
              {post.petId && post.petName ? (
                <>
                  <span className="text-xs text-slate-400 dark:text-slate-500">
                    ·
                  </span>
                  <button
                    type="button"
                    onClick={() => navigate(`/pet/${post.petId}`)}
                    className="text-xs font-semibold text-purple-600 transition-all duration-200 hover:text-purple-500"
                  >
                    with {post.petName}
                  </button>
                </>
              ) : null}
            </div>
            <p className="text-xs text-slate-500 dark:text-slate-400">
              {timeAgo}
            </p>
          </div>
          <div className="relative">
            <button
              type="button"
              onClick={() => setMenuOpen((prev) => !prev)}
              className="text-xl text-slate-400 transition-all duration-200 hover:text-slate-600 dark:text-slate-300 dark:hover:text-slate-100"
              aria-label="Post options"
            >
              ⋯
            </button>
            {menuOpen ? (
              <div className="absolute right-0 top-8 z-10 w-40 rounded-xl bg-white p-2 text-sm shadow-[0_12px_30px_-20px_rgba(15,23,42,0.5)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
                {isOwner ? (
                  <>
                    <button
                      type="button"
                      onClick={() => {
                        setMenuOpen(false);
                        navigate(`/edit-post/${post.id}`);
                      }}
                      className="w-full rounded-lg px-3 py-2 text-left text-slate-600 transition-all duration-200 hover:bg-slate-100 dark:text-slate-200 dark:hover:bg-slate-700"
                    >
                      Edit Post
                    </button>
                    <button
                      type="button"
                      onClick={() => {
                        setMenuOpen(false);
                        setConfirmOpen(true);
                      }}
                      className="w-full rounded-lg px-3 py-2 text-left text-red-500 transition-all duration-200 hover:bg-red-50 dark:hover:bg-red-500/10"
                    >
                      Delete Post
                    </button>
                  </>
                ) : (
                  <>
                    <button
                      type="button"
                      onClick={() => {
                        if (!user) {
                          navigate("/login");
                          return;
                        }
                        setMenuOpen(false);
                        setReportOpen(true);
                      }}
                      className="w-full rounded-lg px-3 py-2 text-left text-orange-500 transition-all duration-200 hover:bg-orange-50 dark:hover:bg-orange-500/10"
                    >
                      Report Post
                    </button>
                    <button
                      type="button"
                      onClick={() => {
                        if (!user) {
                          navigate("/login");
                          return;
                        }
                        setMenuOpen(false);
                        setBlockConfirmOpen(true);
                      }}
                      className="w-full rounded-lg px-3 py-2 text-left text-red-500 transition-all duration-200 hover:bg-red-50 dark:hover:bg-red-500/10"
                    >
                      Block User
                    </button>
                  </>
                )}
                <button
                  type="button"
                  onClick={() => setMenuOpen(false)}
                  className="mt-1 w-full rounded-lg px-3 py-2 text-left text-slate-600 transition-all duration-200 hover:bg-slate-100 dark:text-slate-200 dark:hover:bg-slate-700"
                >
                  Cancel
                </button>
              </div>
            ) : null}
          </div>
        </div>
      </header>

      <div className="relative">
        <MediaCarousel media={mediaItems} onDoubleTap={handleDoubleLike} />
        {showHeart ? (
          <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
            <span className="text-6xl text-red-500 animate-[pulse_0.6s_ease-out]">
              ❤️
            </span>
          </div>
        ) : null}
      </div>

      <div className="px-4 pb-4 pt-3">
        <div className="flex items-center justify-between text-slate-600 dark:text-slate-300">
          <div className="flex items-center gap-4">
            <button
              type="button"
              onClick={handleLike}
              className={`text-2xl transition-all duration-200 ${
                animating ? "scale-110" : "scale-100"
              } ${likedState ? "text-red-500" : "text-slate-500 dark:text-slate-400"}`}
              aria-label="Like"
            >
              <HeartIcon filled={likedState} />
            </button>
            <button
              type="button"
              className="text-2xl text-slate-500 transition-all duration-200 hover:scale-105 dark:text-slate-400"
              aria-label="Comment"
              onClick={() => navigate(`/post/${post.id}`)}
            >
              💬
            </button>
            <button
              type="button"
              className="text-2xl transition-all duration-200 hover:scale-105"
              aria-label="Share"
              onClick={() => setShareOpen(true)}
            >
              <ShareIcon />
            </button>
          </div>
          <button
            type="button"
            onClick={handleBookmark}
            className={`transition-all duration-200 ${
              bookmarkAnimating ? "scale-110" : "scale-100"
            }`}
            aria-label="Save"
          >
            <BookmarkIcon filled={isBookmarked} />
          </button>
        </div>

        <p className="mt-2 text-sm font-semibold text-slate-900 dark:text-white">
          {likeTotal} likes
        </p>
        <button
          type="button"
          onClick={() => navigate(`/post/${post.id}`)}
          className="mt-1 text-xs text-slate-400 transition-all duration-200 hover:text-purple-500 dark:text-slate-500"
        >
          {commentTotal} comments
        </button>

        <p className="mt-2 text-sm text-slate-700 dark:text-slate-200">
          <span className="font-semibold text-slate-900 dark:text-white">
            {authorName}
          </span>{" "}
          {post.text}
        </p>

        <div className="mt-3 flex flex-wrap gap-2 text-xs">
          {post.tags.map((tag) => (
            <button
              key={tag}
              type="button"
              onClick={() => navigate(`/search?tag=${encodeURIComponent(tag)}`)}
              className="rounded-full bg-purple-50 px-2 py-1 font-semibold text-purple-600 transition-all duration-200 hover:scale-105 hover:bg-purple-100 dark:bg-purple-500/10 dark:text-purple-300"
            >
              #{tag}
            </button>
          ))}
        </div>

      </div>

      {confirmOpen ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-sm rounded-2xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)] dark:bg-slate-800">
            <h3 className="text-base font-semibold text-slate-900 dark:text-white">
              Delete Post
            </h3>
            <p className="mt-2 text-sm text-slate-600 dark:text-slate-300">
              Are you sure you want to delete this post? This action cannot be
              undone.
            </p>
            <div className="mt-5 flex items-center justify-end gap-3">
              <button
                type="button"
                onClick={() => setConfirmOpen(false)}
                className="rounded-full px-4 py-2 text-sm font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
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

      {blockConfirmOpen ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-sm rounded-2xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)] dark:bg-slate-800">
            <h3 className="text-base font-semibold text-slate-900 dark:text-white">
              Block @{authorName}?
            </h3>
            <p className="mt-2 text-sm text-slate-600 dark:text-slate-300">
              They won&apos;t be able to see your posts, and you won&apos;t see
              theirs.
            </p>
            <div className="mt-5 flex items-center justify-end gap-3">
              <button
                type="button"
                onClick={() => setBlockConfirmOpen(false)}
                className="rounded-full px-4 py-2 text-sm font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={handleBlock}
                disabled={blocking}
                className="rounded-full bg-red-500 px-4 py-2 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
              >
                {blocking ? "Blocking..." : "Block"}
              </button>
            </div>
          </div>
        </div>
      ) : null}

      <ShareMenu
        open={shareOpen}
        onClose={() => setShareOpen(false)}
        postId={post.id}
        text={post.text}
      />

      <ReportModal
        open={reportOpen}
        onClose={() => setReportOpen(false)}
        targetType="post"
        targetId={post.id}
      />
    </article>
  );
}
