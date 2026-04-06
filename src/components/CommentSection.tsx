import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import {
  addComment,
  deleteComment,
  getComments,
  type Comment,
} from "../services/posts";
import { timeAgo } from "../utils/timeAgo";
import { useToast } from "../contexts/ToastContext";
import Avatar from "./Avatar";

type CommentSectionProps = {
  postId: string;
  postAuthorId: string;
  commentCount: number;
  maxVisible?: number;
  stickyInput?: boolean;
  onCommentAdded?: () => void;
  onCommentDeleted?: () => void;
};

export function CommentSection({
  postId,
  postAuthorId,
  commentCount,
  maxVisible = 5,
  stickyInput = false,
  onCommentAdded,
  onCommentDeleted,
}: CommentSectionProps) {
  const { user, isBanned } = useAuth();
  const navigate = useNavigate();
  const { showToast } = useToast();
  const inputRef = useRef<HTMLInputElement | null>(null);
  const inputWrapperRef = useRef<HTMLDivElement | null>(null);
  const [comments, setComments] = useState<Comment[]>([]);
  const [loading, setLoading] = useState(false);
  const [text, setText] = useState("");
  const [viewportOffset, setViewportOffset] = useState(0);
  const [replyTarget, setReplyTarget] = useState<{
    commentId: string;
    authorName: string;
    authorId: string;
  } | null>(null);
  const [commentToDelete, setCommentToDelete] = useState<Comment | null>(null);
  const [removingId, setRemovingId] = useState<string | null>(null);
  const isEmailVerified = !!user?.emailVerified;
  const remaining = 500 - text.length;
  const counterTone =
    remaining <= 0
      ? "text-red-500"
      : remaining <= 100
      ? "text-amber-500"
      : "text-slate-400 dark:text-slate-500";

  useEffect(() => {
    let ignore = false;
    const load = async () => {
      setLoading(true);
      try {
        const data = await getComments(postId);
        if (!ignore) setComments(data);
      } catch (err) {
        const message =
          err instanceof Error ? err.message : "Failed to load comments";
        if (!ignore) showToast(message, "error");
      } finally {
        if (!ignore) setLoading(false);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [postId]);

  useEffect(() => {
    if (!stickyInput || !window.visualViewport) return;
    const viewport = window.visualViewport;
    const handleResize = () => {
      const offset = Math.max(0, window.innerHeight - viewport.height - viewport.offsetTop);
      setViewportOffset(offset);
    };
    handleResize();
    viewport.addEventListener("resize", handleResize);
    viewport.addEventListener("scroll", handleResize);
    return () => {
      viewport.removeEventListener("resize", handleResize);
      viewport.removeEventListener("scroll", handleResize);
    };
  }, [stickyInput]);

  const visibleComments = useMemo(() => {
    if (!Number.isFinite(maxVisible)) {
      return comments;
    }
    return comments.slice(0, maxVisible);
  }, [comments, maxVisible]);

  const showViewAll =
    Number.isFinite(maxVisible) && comments.length > maxVisible;

  const handleSend = async () => {
    if (!user) {
      navigate("/login");
      return;
    }
    if (!isEmailVerified) {
      showToast("Please verify your email first", "warning");
      return;
    }
    if (isBanned) {
      showToast("Your account has been suspended.", "error");
      return;
    }

    const content = text.trim();
    if (!content) return;
    if (content.length > 500) return;

    setText("");

    const reply = replyTarget;
    const optimisticId = `local-${Date.now()}`;
    const optimistic: Comment = {
      id: optimisticId,
      authorId: user.uid,
      authorName: user.displayName || "PetNote User",
      authorAvatar:
        user.photoURL ||
        `https://api.dicebear.com/7.x/thumbs/svg?seed=${user.uid}`,
      text: content,
      createdAt: new Date(),
      replyTo: reply
        ? {
            commentId: reply.commentId,
            authorName: reply.authorName,
          }
        : undefined,
    };

    setComments((prev) => [optimistic, ...prev]);
    onCommentAdded?.();
    setReplyTarget(null);

    try {
      const createdId = await addComment(
        postId,
        {
          authorId: optimistic.authorId,
          authorName: optimistic.authorName,
          authorAvatar: optimistic.authorAvatar,
          text: optimistic.text,
          replyTo: optimistic.replyTo,
        }
      );
      if (createdId) {
        setComments((prev) =>
          prev.map((item) =>
            item.id === optimisticId ? { ...item, id: createdId } : item
          )
        );
      }
      showToast("Comment posted", "success");
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to post comment";
      showToast(message, "error");
    }
  };

  const handleDelete = async () => {
    if (!commentToDelete || !commentToDelete.id) return;
    if (commentToDelete.id.startsWith("local-")) return;
    const targetId = commentToDelete.id;
    setRemovingId(targetId);
    setTimeout(() => {
      setComments((prev) => prev.filter((item) => item.id !== targetId));
      onCommentDeleted?.();
      setRemovingId(null);
    }, 200);
    setCommentToDelete(null);

    try {
      await deleteComment(postId, targetId);
      showToast("Comment deleted", "success");
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to delete comment";
      showToast(message, "error");
    }
  };

  return (
    <section className="mt-3 rounded-2xl bg-slate-50 px-4 py-3 text-sm text-slate-700 dark:bg-slate-800 dark:text-slate-200">
      <div className={`space-y-3 ${stickyInput ? "pb-20" : ""}`}>
        {loading ? (
          <p className="text-xs text-slate-400 dark:text-slate-500">
            Loading comments...
          </p>
        ) : null}
        {visibleComments.map((comment) => {
          const canDelete =
            !!user &&
            (user.uid === comment.authorId || user.uid === postAuthorId);

          return (
            <div
              key={comment.id}
              className={`border-b border-slate-200 pb-3 pt-2 text-left transition-all duration-200 last:border-b-0 dark:border-slate-700 ${
                removingId === comment.id ? "opacity-0 -translate-x-2" : ""
              }`}
            >
              <div className="flex items-start gap-3">
                <Avatar
                  src={comment.authorAvatar}
                  alt={comment.authorName}
                  userId={comment.authorId}
                  size={24}
                  className="h-6 w-6"
                />
                <div className="flex-1">
                  <span className="text-xs font-semibold text-slate-900 dark:text-white">
                    {comment.authorName}
                  </span>

                  <p className="mt-1 text-left text-xs text-slate-600 dark:text-slate-300">
                    {comment.replyTo ? (
                      <span className="mr-1 text-purple-600">
                        @{comment.replyTo.authorName}
                      </span>
                    ) : null}
                    {comment.text}
                  </p>

                  <div className="mt-2 flex items-center justify-end gap-2 text-[10px] text-slate-400 dark:text-slate-500">
                    <span>{timeAgo(comment.createdAt as Date)}</span>
                    <span>·</span>
                    <button
                      type="button"
                      onClick={() => {
                        if (!user) {
                          navigate("/login");
                          return;
                        }
                        if (!comment.id) return;
                        setReplyTarget({
                          commentId: comment.id,
                          authorName: comment.authorName,
                          authorId: comment.authorId,
                        });
                        setTimeout(() => inputRef.current?.focus(), 0);
                      }}
                      className="font-semibold transition-all duration-200 hover:text-purple-500"
                    >
                      Reply
                    </button>
                    {canDelete ? (
                      <>
                        <span>·</span>
                        <button
                          type="button"
                          onClick={() => setCommentToDelete(comment)}
                          className="transition-all duration-200 hover:text-red-500"
                          aria-label="Delete comment"
                        >
                          🗑️
                        </button>
                      </>
                    ) : null}
                  </div>
                </div>
              </div>
            </div>
          );
        })}

        {showViewAll ? (
          <button
            type="button"
            className="text-xs font-semibold text-purple-600 hover:text-purple-500"
          >
            View all {commentCount} comments
          </button>
        ) : null}
      </div>

      <div
        ref={inputWrapperRef}
        style={stickyInput ? { bottom: viewportOffset } : undefined}
        className={
          stickyInput
            ? "sticky bottom-0 border-t border-slate-200 bg-slate-50 pt-3 pb-[env(safe-area-inset-bottom)] dark:border-slate-700 dark:bg-slate-800"
            : ""
        }
      >
        {replyTarget ? (
          <div className="mt-3 flex items-center justify-between rounded-xl bg-white px-3 py-2 text-xs text-slate-500 shadow-sm dark:bg-slate-700 dark:text-slate-300">
            <span>
              Replying to{" "}
              <span className="font-semibold">@{replyTarget.authorName}</span>
            </span>
            <button
              type="button"
              onClick={() => setReplyTarget(null)}
              className="text-slate-400 transition-all duration-200 hover:text-slate-600 dark:text-slate-300 dark:hover:text-slate-100"
            >
              ✕
            </button>
          </div>
        ) : null}

        <div
          className={`${replyTarget ? "mt-3" : "mt-4"} flex items-center gap-2`}
        >
          {user ? (
            <Avatar
              src={user.photoURL || undefined}
              alt={user.displayName || "User"}
              userId={user.uid}
              size={24}
              className="h-6 w-6"
            />
          ) : (
            <div className="flex h-6 w-6 items-center justify-center rounded-full bg-slate-200 text-[10px] text-slate-500 dark:bg-slate-700 dark:text-slate-300">
              👤
            </div>
          )}
          <input
            ref={inputRef}
            type="text"
            placeholder={
              isBanned
                ? "Account suspended"
                : !isEmailVerified
                ? "Verify your email to comment"
                : user
                ? "Add a comment..."
                : "Login to comment"
            }
            className="flex-1 rounded-full border border-slate-200 bg-white px-4 py-2 text-xs text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-700 dark:text-white"
            value={text}
            readOnly={!user || isBanned || !isEmailVerified}
            onFocus={() => {
              if (!user) navigate("/login");
              if (user && !isEmailVerified) {
                showToast("Please verify your email first", "warning");
              }
            }}
            onClick={() => {
              if (!user) navigate("/login");
              if (user && !isEmailVerified) {
                showToast("Please verify your email first", "warning");
              }
            }}
            onChange={(event) => setText(event.target.value)}
            maxLength={500}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                event.preventDefault();
                void handleSend();
              }
            }}
          />
          <button
            type="button"
            onClick={handleSend}
            disabled={!user || !text.trim() || isBanned || !isEmailVerified}
            className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-xs font-semibold text-white transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Send
          </button>
        </div>
        <div className={`mt-2 text-right text-[10px] ${counterTone}`}>
          {text.length}/500
        </div>
      </div>

      {commentToDelete ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-sm rounded-2xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)] dark:bg-slate-800">
            <h3 className="text-base font-semibold text-slate-900 dark:text-white">
              Delete Comment
            </h3>
            <p className="mt-2 text-sm text-slate-600 dark:text-slate-300">
              {user?.uid === postAuthorId && user?.uid !== commentToDelete.authorId
                ? "Delete this comment? You are the post owner."
                : "Delete this comment?"}
            </p>
            <div className="mt-5 flex items-center justify-end gap-3">
              <button
                type="button"
                onClick={() => setCommentToDelete(null)}
                className="rounded-full px-4 py-2 text-sm font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={handleDelete}
                className="rounded-full bg-red-500 px-4 py-2 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110"
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </section>
  );
}
