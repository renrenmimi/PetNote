import { useEffect, useMemo, useState, useRef } from "react";
import { MoreHorizontal } from "lucide-react";
import { useNavigate, useParams } from "react-router-dom";
import { CommentSection } from "../components/CommentSection";
import { MediaCarousel } from "../components/MediaCarousel";
import { ShareMenu } from "../components/ShareMenu";
import { SkeletonPostCard } from "../components/SkeletonPostCard";
import { LoadFailedState } from "../components/LoadFailedState";
import { PostActions } from "../components/post/PostActions";
import { PostIdentity } from "../components/post/PostIdentity";
import { useAuth } from "../hooks/useAuth";
import { useBookmark } from "../hooks/useBookmark";
import { useFollowPet } from "../hooks/useFollow";
import { useLike } from "../hooks/useLike";
import { deletePost, getPostById, type Post } from "../services/posts";
import { getCachedUser } from "../hooks/useUserCache";
import { timeAgo } from "../utils/timeAgo";
import { useToast } from "../contexts/ToastContext";

// Module-scoped icon components. Defining them inside PostDetail tripped
// react-hooks/static-components and reset the SVG defs on every render —
// even though the visual output looked the same, React was throwing away
// and recreating the components every render cycle.

export function PostDetail() {
  const navigate = useNavigate();
  const { postId = "" } = useParams();
  const { user, isBanned } = useAuth();
  const { showToast } = useToast();
  const [post, setPost] = useState<Post | null>(null);
  const [loading, setLoading] = useState(true);
  const [menuOpen, setMenuOpen] = useState(false);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [authorName, setAuthorName] = useState<string | null>(null);
  const [authorAvatar, setAuthorAvatar] = useState<string | null>(null);
  const [commentCount, setCommentCount] = useState(0);
  const [loadFailure, setLoadFailure] = useState<
    "failed" | "denied" | null
  >(null);
  const [reloadToken, setReloadToken] = useState(0);
  const [shareOpen, setShareOpen] = useState(false);
  const commentsRef = useRef<HTMLDivElement | null>(null);

  const { isLiked, likeCount, toggleLike } = useLike(
    postId,
    user?.uid ?? null,
    post?.likeCount ?? 0,
    undefined,
    {
      onFailure: (reason) =>
        showToast(
          reason === "post-missing"
            ? "This post is no longer available"
            : "Could not update like. Please try again.",
          "error"
        ),
    }
  );
  const { isBookmarked, toggleBookmark } = useBookmark(
    postId,
    user?.uid ?? null
  );
  const { isFollowing, toggleFollow } = useFollowPet(post?.petId ?? "", {
    // The detail page never renders the follower count — skip the extra
    // getPetById read the hook would otherwise issue per view.
    fetchFollowerCount: false,
  });

  useEffect(() => {
    let ignore = false;
    if (!postId) return;

    const load = async () => {
      setLoading(true);
      setLoadFailure(null);
      try {
        const data = await getPostById(postId);
        if (!ignore) {
          setPost(data);
          setCommentCount(data?.commentCount ?? 0);
        }
      } catch (error) {
        // Catching this stopped the skeleton spinning forever, but leaving
        // `post` null then rendered "Post not found." — so a dropped
        // connection, or a rule that refused the read, told the person the
        // post did not exist. Verified against the emulator: a readable post
        // whose fetch failed showed exactly that.
        console.error("Failed to load post:", error);
        if (!ignore) {
          const code =
            error && typeof error === "object" && "code" in error
              ? String((error as { code?: unknown }).code ?? "")
              : "";
          setLoadFailure(
            code.includes("permission-denied") ? "denied" : "failed"
          );
        }
      } finally {
        if (!ignore) setLoading(false);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
    // reloadToken is the retry button.
  }, [postId, reloadToken]);

  useEffect(() => {
    let ignore = false;
    if (!post?.authorId) return;
    const loadProfile = async () => {
      const profile = await getCachedUser(post.authorId);
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

  const timeLabel = useMemo(
    () => (post?.createdAt ? timeAgo(post.createdAt) : ""),
    // The compiler infers `post` since createdAt is read off of it; align
    // the manual deps to keep the rule happy.
    [post]
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
      // Navigate without resetting the loading state in finally — the
      // component is unmounting and setting state on an unmounted
      // component triggers a React warning. We only need to reset on
      // failure so the dialog button can recover.
      navigate("/", { replace: true });
    } catch {
      setDeleting(false);
      setConfirmOpen(false);
      // Closing the dialog with zero feedback looked like a silent success.
      showToast("Failed to delete post", "error");
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
    toggleLike();
  };

  const handleBookmark = async () => {
    if (!user) {
      navigate("/login");
      return;
    }
    try {
      await toggleBookmark();
    } catch {
      showToast("Failed to update bookmark", "error");
    }
  };


  return (
    <div className="min-h-screen bg-slate-50 pb-20 dark:bg-slate-900">
      <header className="sticky top-0 z-10 border-b border-slate-200 bg-white/80 backdrop-blur dark:border-slate-800 dark:bg-slate-900/80">
        <div className="mx-auto flex w-full max-w-md items-center justify-between px-4 py-3">
          <button
            type="button"
            onClick={() => navigate(-1)}
            className="text-xl text-slate-500 hover:text-slate-700 dark:text-slate-300"
            aria-label="Go back"
          >
            ←
          </button>
          <h1 className="text-base font-semibold text-slate-900 dark:text-white">Post</h1>
          {canEdit ? (
            <div className="relative">
              <button
                type="button"
                onClick={() => setMenuOpen((prev) => !prev)}
                className="tap-target flex h-9 w-9 items-center justify-center text-slate-400 transition-colors duration-200 hover:text-slate-600 dark:text-slate-300 dark:hover:text-slate-100"
                aria-label="Post options"
              >
              <MoreHorizontal size={20} strokeWidth={2} aria-hidden="true" />
              </button>
              {menuOpen ? (
                <div className="absolute right-0 top-8 z-10 w-36 rounded-xl bg-white p-2 text-sm shadow-[0_12px_30px_-20px_rgba(15,23,42,0.5)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
                  <button
                    type="button"
                    onClick={() => {
                      setMenuOpen(false);
                      navigate(`/edit-post/${post?.id}`);
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
                </div>
              ) : null}
            </div>
          ) : (
            <div className="w-6" />
          )}
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-4 px-4 py-4 pb-24">
        {loading ? <SkeletonPostCard /> : null}
        {/* Three outcomes, three answers. "Not found" is only said when the
            read succeeded and the post genuinely is not there. */}
        {!loading && !post && loadFailure ? (
          <LoadFailedState
            title={
              loadFailure === "denied"
                ? "You cannot see this post"
                : "Could not load this post"
            }
            description={
              loadFailure === "denied"
                ? "It may be private, or shared with a different account."
                : "Something went wrong reaching PetNote. Check your connection and try again."
            }
            retryLabel="Try again"
            retryingLabel="Trying..."
            onRetry={() => setReloadToken((value) => value + 1)}
          />
        ) : null}
        {!loading && !post && !loadFailure ? (
          <div className="rounded-2xl bg-white p-6 text-center text-sm text-slate-500 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] dark:bg-slate-800 dark:text-slate-300">
            This post has been deleted.
          </div>
        ) : null}
        {post ? (
          <div className="space-y-4 rounded-2xl bg-white p-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
            <PostIdentity
              petId={post.petId}
              petName={post.petName}
              petAvatarUrl={post.petAvatarUrl}
              authorId={post.authorId}
              authorName={authorName || post.authorName}
              authorAvatarUrl={authorAvatar || post.authorAvatar}
              timeLabel={timeLabel}
              size="detail"
              trailing={
                <>
              {user && post.authorId !== user.uid && post.petId ? (
                <button
                  type="button"
                  onClick={toggleFollow}
                  className={`rounded-full px-4 py-1.5 text-xs font-semibold transition-all duration-200 ${
                    isFollowing
                      ? "border border-slate-200 text-slate-500 dark:border-slate-700 dark:text-slate-300"
                      : "bg-gradient-to-r from-purple-500 to-pink-500 text-white shadow-[0_10px_25px_-15px_rgba(168,85,247,0.7)]"
                  }`}
                >
                  {isFollowing ? "Following" : "Follow"}
                </button>
              ) : null}
                </>
              }
            />

            <MediaCarousel media={mediaItems} imageSize="large" />

            <PostActions
              liked={isLiked}
              onLike={handleLike}
              onComment={() =>
                commentsRef.current?.scrollIntoView({
                  behavior: "smooth",
                  block: "start",
                })
              }
              onShare={() => setShareOpen(true)}
              bookmarked={isBookmarked}
              onBookmark={handleBookmark}
            />

            <div>
              <p className="text-sm font-semibold text-slate-900 dark:text-white">
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
                className="text-xs text-slate-400 hover:text-purple-500 dark:text-slate-500"
              >
                {commentCount} comments
              </button>
            </div>

            <p className="text-sm text-slate-700 dark:text-slate-200">
              <span className="font-semibold text-slate-900 dark:text-white">
                {authorName || post.authorName}
              </span>{" "}
              {post.text}
            </p>

            {(post.tags ?? []).length > 0 ? (
              <div className="flex flex-wrap gap-2 text-xs">
                {(post.tags ?? []).map((tag) => (
                  <button
                    key={tag}
                    type="button"
                    onClick={() =>
                      navigate(`/search?tag=${encodeURIComponent(tag)}`)
                    }
                    className="rounded-full bg-purple-50 px-2 py-1 font-semibold text-purple-600 transition-all duration-200 hover:scale-105 hover:bg-purple-100 dark:bg-purple-500/10 dark:text-purple-300"
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

      {post ? (
        <ShareMenu
          open={shareOpen}
          onClose={() => setShareOpen(false)}
          postId={post.id}
          text={post.text}
          post={post}
        />
      ) : null}
    </div>
  );
}
