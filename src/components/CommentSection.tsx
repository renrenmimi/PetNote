import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { addComment, getComments, type Comment } from "../services/posts";

type CommentSectionProps = {
  postId: string;
  commentCount: number;
  onCommentAdded?: () => void;
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

export function CommentSection({
  postId,
  commentCount,
  onCommentAdded,
}: CommentSectionProps) {
  const { user } = useAuth();
  const navigate = useNavigate();
  const [comments, setComments] = useState<Comment[]>([]);
  const [loading, setLoading] = useState(false);
  const [text, setText] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let ignore = false;
    const load = async () => {
      setLoading(true);
      setError(null);
      try {
        const data = await getComments(postId);
        if (!ignore) setComments(data);
      } catch (err) {
        const message =
          err instanceof Error ? err.message : "Failed to load comments";
        if (!ignore) setError(message);
      } finally {
        if (!ignore) setLoading(false);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [postId]);

  const visibleComments = useMemo(() => comments.slice(0, 5), [comments]);

  const handleSend = async () => {
    if (!user) {
      navigate("/login");
      return;
    }

    const content = text.trim();
    if (!content) return;

    setText("");

    const optimistic: Comment = {
      id: `local-${Date.now()}`,
      authorId: user.uid,
      authorName: user.displayName || "PetNote User",
      authorAvatar: user.photoURL || "https://i.pravatar.cc/100?img=12",
      text: content,
      createdAt: new Date(),
    };

    setComments((prev) => [optimistic, ...prev]);
    onCommentAdded?.();

    try {
      await addComment(postId, {
        authorId: optimistic.authorId,
        authorName: optimistic.authorName,
        authorAvatar: optimistic.authorAvatar,
        text: optimistic.text,
      });
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to post comment";
      setError(message);
    }
  };

  return (
    <section className="mt-3 rounded-2xl bg-slate-50 px-4 py-3 text-sm text-slate-700">
      <div className="space-y-3">
        {loading ? (
          <p className="text-xs text-slate-400">Loading comments...</p>
        ) : null}
        {error ? <p className="text-xs text-red-500">{error}</p> : null}

        {visibleComments.map((comment) => (
          <div
            key={comment.id}
            className="flex gap-3 border-b border-slate-200 pb-3 last:border-b-0 last:pb-0"
          >
            <img
              src={comment.authorAvatar || "https://i.pravatar.cc/100?img=12"}
              alt={comment.authorName}
              className="h-8 w-8 rounded-full object-cover"
            />
            <div className="flex-1">
              <div className="flex items-center justify-between">
                <span className="text-xs font-semibold text-slate-900">
                  {comment.authorName}
                </span>
                <span className="text-[10px] text-slate-400">
                  {formatTimeAgo(comment.createdAt)}
                </span>
              </div>
              <p className="text-xs text-slate-600">{comment.text}</p>
            </div>
          </div>
        ))}

        {commentCount > 5 ? (
          <button
            type="button"
            className="text-xs font-semibold text-purple-600 hover:text-purple-500"
          >
            View all {commentCount} comments
          </button>
        ) : null}
      </div>

      <div className="mt-4 flex items-center gap-2">
        <input
          type="text"
          placeholder={user ? "Add a comment..." : "Login to comment"}
          className="flex-1 rounded-full border border-slate-200 bg-white px-4 py-2 text-xs text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200"
          value={text}
          readOnly={!user}
          onFocus={() => {
            if (!user) navigate("/login");
          }}
          onClick={() => {
            if (!user) navigate("/login");
          }}
          onChange={(event) => setText(event.target.value)}
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
          disabled={!user || !text.trim()}
          className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-xs font-semibold text-white transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-50"
        >
          Send
        </button>
      </div>
    </section>
  );
}
