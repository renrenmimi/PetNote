import { useEffect, useMemo, useState, useRef } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { CommentSection } from "../components/CommentSection";
import { MediaCarousel } from "../components/MediaCarousel";
import { ShareMenu } from "../components/ShareMenu";
import { useAuth } from "../hooks/useAuth";
import { useBookmark } from "../hooks/useBookmark";
import { useFollow } from "../hooks/useFollow";
import { useLike } from "../hooks/useLike";
import { deletePost, getPostById, type Post } from "../services/posts";
import { getUserProfile } from "../services/users";

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

export function PostDetail() {
  const navigate = useNavigate();
  const { postId = "" } = useParams();
  const { user, isBanned } = useAuth();
  const [post, setPost] = useState<Post | null>(null);
  const [loading, setLoading] = useState(true);
  const [menuOpen, setMenuOpen] = useState(false);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [authorName, setAuthorName] = useState<string | null>(null);
  const [authorAvatar, setAuthorAvatar] = useState<string | null>(null);
  const [commentCount, setCommentCount] = useState(0);
  const [shareOpen, setShareOpen] = useState(false);
  const commentsRef = useRef<HTMLDivElement | null>(null);

  const { isLiked, likeCount, toggleLike } = useLike(
    postId,
    user?.uid ?? null,
    post?.likeCount ?? 0
  );
  const { isBookmarked, toggleBookmark } = useBookmark(
    postId,
    user?.uid ?? null
  );
  const { isFollowing, toggleFollow } = useFollow(post?.authorId ?? "");

  useEffect(() => {
    let ignore = false;
    if (!postId) return;

    const load = async () => {
      setLoading(true);
      const data = await getPostById(postId);
      if (!ignore) {
        setPost(data);
        setCommentCount(data?.commentCount ?? 0);
        setLoading(false);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [postId]);

  useEffect(() => {
    let ignore = false;
    if (!post?.authorId) return;
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
  }, [post?.authorId, post?.authorAvatar, post?.authorName]);

  const timeAgo = useMemo(
    () => formatTimeAgo(post?.createdAt),
    [post?.createdAt]
  );
  const mediaItems =
    post?.media && post.media.length > 0
      ? post.media
      : post?.mediaUrl
      ? [{ url: post.mediaUrl, type: post.mediaType || "image" }]
      : [];

  const canEdit = !!user && post?.authorId === user.uid;

  const handleDelete = async () => {
    if (!post || deleting) return;
    setDeleting(true);
    try {
      await deletePost(post.id);
      navigate("/", { replace: true });
    } finally {
      setDeleting(false);
      setConfirmOpen(false);
    }
  };

  const handleLike = async () => {
    if (!user) {
      navigate("/login");
      return;
    }
    if (isBanned) {
      return;
    }
    await toggleLike();
  };

  const handleBookmark = async () => {
    if (!user) {
      navigate("/login");
      return;
    }
    await toggleBookmark();
  };

  const HeartIcon = ({ filled }: { filled: boolean }) => {
    const gradientId = `heart-detail-${post?.id ?? "post"}`;
    return (
      <svg
        className={`h-6 w-6 ${filled ? "text-red-500" : "text-slate-500"}`}
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
        className={`h-6 w-6 ${filled ? "text-purple-500" : "text-slate-500"}`}
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
      className="h-6 w-6 text-slate-500"
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
    <div className="min-h-screen bg-slate-50 pb-20">
      <header className="sticky top-0 z-10 border-b border-slate-200 bg-white/80 backdrop-blur">
        <div className="mx-auto flex w-full max-w-md items-center justify-between px-4 py-3">
          <button
            type="button"
            onClick={() => navigate(-1)}
            className="text-xl text-slate-500 hover:text-slate-700"
            aria-label="Go back"
          >
            ←
          </button>
          <h1 className="text-base font-semibold text-slate-900">Post</h1>
          {canEdit ? (
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
                      navigate(`/edit-post/${post?.id}`);
                    }}
                    className="w-full rounded-lg px-3 py-2 text-left text-slate-600 transition-all duration-200 hover:bg-slate-100"
                  >
                    Edit Post
                  </button>
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
                </div>
              ) : null}
            </div>
          ) : (
            <div className="w-6" />
          )}
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-4 px-4 py-4 pb-24">
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
        {post ? (
          <div className="space-y-4 rounded-2xl bg-white p-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-3">
                <img
                  src={authorAvatar || post.authorAvatar}
                  alt={authorName || post.authorName}
                  className="h-10 w-10 rounded-full object-cover"
                />
                <div>
                  <div className="flex items-center gap-2">
                    <button
                      type="button"
                      onClick={() => navigate(`/profile/${post.authorId}`)}
                      className="text-sm font-semibold text-slate-900 transition-all duration-200 hover:text-purple-600"
                    >
                      {authorName || post.authorName}
                    </button>
                    {post.petId && post.petName ? (
                      <button
                        type="button"
                        onClick={() => navigate(`/pet/${post.petId}`)}
                        className="text-xs font-semibold text-purple-600"
                      >
                        · with {post.petName}
                      </button>
                    ) : null}
                  </div>
                  <p className="text-xs text-slate-500">{timeAgo}</p>
                </div>
              </div>
              {user && post.authorId !== user.uid ? (
                <button
                  type="button"
                  onClick={toggleFollow}
                  className={`rounded-full px-4 py-1.5 text-xs font-semibold transition-all duration-200 ${
                    isFollowing
                      ? "border border-slate-200 text-slate-500"
                      : "bg-gradient-to-r from-purple-500 to-pink-500 text-white shadow-[0_10px_25px_-15px_rgba(168,85,247,0.7)]"
                  }`}
                >
                  {isFollowing ? "Following" : "Follow"}
                </button>
              ) : null}
            </div>

            <MediaCarousel media={mediaItems} />

            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4 text-slate-600">
                <button
                  type="button"
                  onClick={handleLike}
                  className="text-2xl transition-all duration-200"
                  aria-label="Like"
                >
                  <HeartIcon filled={isLiked} />
                </button>
                <button
                  type="button"
                  onClick={() =>
                    commentsRef.current?.scrollIntoView({
                      behavior: "smooth",
                      block: "start",
                    })
                  }
                  className="text-2xl text-slate-500 transition-all duration-200 hover:scale-105"
                  aria-label="Comment"
                >
                  💬
                </button>
                <button
                  type="button"
                  onClick={() => setShareOpen(true)}
                  className="text-2xl transition-all duration-200 hover:scale-105"
                  aria-label="Share"
                >
                  <ShareIcon />
                </button>
              </div>
              <button
                type="button"
                onClick={handleBookmark}
                className="text-2xl text-slate-500 transition-all duration-200 hover:scale-105"
                aria-label="Save"
              >
                <BookmarkIcon filled={isBookmarked} />
              </button>
            </div>

            <div>
              <p className="text-sm font-semibold text-slate-900">
                {likeCount} likes
              </p>
              <button
                type="button"
                onClick={() =>
                  commentsRef.current?.scrollIntoView({
                    behavior: "smooth",
                    block: "start",
                  })
                }
                className="text-xs text-slate-400 hover:text-purple-500"
              >
                {commentCount} comments
              </button>
            </div>

            <p className="text-sm text-slate-700">
              <span className="font-semibold text-slate-900">
                {authorName || post.authorName}
              </span>{" "}
              {post.text}
            </p>

            {post.tags.length > 0 ? (
              <div className="flex flex-wrap gap-2 text-xs">
                {post.tags.map((tag) => (
                  <button
                    key={tag}
                    type="button"
                    onClick={() =>
                      navigate(`/search?tag=${encodeURIComponent(tag)}`)
                    }
                    className="rounded-full bg-purple-50 px-2 py-1 font-semibold text-purple-600 transition-all duration-200 hover:scale-105 hover:bg-purple-100"
                  >
                    #{tag}
                  </button>
                ))}
              </div>
            ) : null}
          </div>
        ) : null}

        {post ? (
          <div ref={commentsRef}>
            <CommentSection
              postId={post.id}
              postAuthorId={post.authorId}
              commentCount={commentCount}
              maxVisible={Number.POSITIVE_INFINITY}
              stickyInput
              onCommentAdded={() =>
                setCommentCount((prev) => prev + 1)
              }
              onCommentDeleted={() =>
                setCommentCount((prev) => Math.max(0, prev - 1))
              }
            />
          </div>
        ) : null}
      </main>

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

      {post ? (
        <ShareMenu
          open={shareOpen}
          onClose={() => setShareOpen(false)}
          postId={post.id}
          text={post.text}
        />
      ) : null}
    </div>
  );
}
