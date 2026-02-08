import { useEffect, useMemo } from "react";
import { useNavigate } from "react-router-dom";
import type { Post } from "../services/posts";

type QuickActionMenuProps = {
  isOpen: boolean;
  position: { x: number; y: number };
  post: Post;
  isLiked: boolean;
  isBookmarked: boolean;
  isOwner: boolean;
  onClose: () => void;
  onLike: () => void;
  onBookmark: () => void;
  onShare: () => void;
  onReport: () => void;
  onBlock: () => void;
  onEdit: () => void;
  onDelete: () => void;
};

export function QuickActionMenu({
  isOpen,
  position,
  post,
  isLiked,
  isBookmarked,
  isOwner,
  onClose,
  onLike,
  onBookmark,
  onShare,
  onReport,
  onBlock,
  onEdit,
  onDelete,
}: QuickActionMenuProps) {
  const navigate = useNavigate();

  const menuStyle = useMemo(() => {
    const width = 220;
    const height = isOwner ? 300 : 250;
    const padding = 16;
    const x = Math.min(position.x, window.innerWidth - width - padding);
    const y = Math.min(position.y, window.innerHeight - height - padding);
    return { left: Math.max(padding, x), top: Math.max(padding, y) };
  }, [position, isOwner]);

  useEffect(() => {
    if (!isOpen) return;
    const handleKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", handleKey);
    return () => window.removeEventListener("keydown", handleKey);
  }, [isOpen, onClose]);

  if (!isOpen) return null;

  return (
    <div
      className="fixed inset-0 z-50 bg-black/40 backdrop-blur-sm"
      onClick={onClose}
    >
      <div
        className="absolute w-56 origin-top-left rounded-2xl bg-white py-2 shadow-2xl transition-all duration-200 dark:bg-slate-800"
        style={menuStyle}
        onClick={(event) => event.stopPropagation()}
      >
        <button
          type="button"
          onClick={onLike}
          className="flex h-11 w-full items-center gap-2 px-4 text-sm text-slate-700 transition-all duration-200 hover:bg-slate-50 dark:text-slate-200 dark:hover:bg-slate-700"
        >
          ❤️ {isLiked ? "Unlike" : "Like"}
        </button>
        <button
          type="button"
          onClick={onBookmark}
          className="flex h-11 w-full items-center gap-2 px-4 text-sm text-slate-700 transition-all duration-200 hover:bg-slate-50 dark:text-slate-200 dark:hover:bg-slate-700"
        >
          🔖 {isBookmarked ? "Unsave" : "Save"}
        </button>
        <button
          type="button"
          onClick={onShare}
          className="flex h-11 w-full items-center gap-2 px-4 text-sm text-slate-700 transition-all duration-200 hover:bg-slate-50 dark:text-slate-200 dark:hover:bg-slate-700"
        >
          ↗️ Share
        </button>
        <button
          type="button"
          onClick={() => navigate(`/profile/${post.authorId}`)}
          className="flex h-11 w-full items-center gap-2 px-4 text-sm text-slate-700 transition-all duration-200 hover:bg-slate-50 dark:text-slate-200 dark:hover:bg-slate-700"
        >
          👤 View Profile
        </button>
        {isOwner ? (
          <>
            <button
              type="button"
              onClick={onEdit}
              className="flex h-11 w-full items-center gap-2 px-4 text-sm text-slate-700 transition-all duration-200 hover:bg-slate-50 dark:text-slate-200 dark:hover:bg-slate-700"
            >
              ✏️ Edit
            </button>
            <button
              type="button"
              onClick={onDelete}
              className="flex h-11 w-full items-center gap-2 px-4 text-sm text-red-500 transition-all duration-200 hover:bg-red-50 dark:hover:bg-red-500/10"
            >
              🗑️ Delete
            </button>
          </>
        ) : (
          <>
            <button
              type="button"
              onClick={onReport}
              className="flex h-11 w-full items-center gap-2 px-4 text-sm text-orange-500 transition-all duration-200 hover:bg-orange-50 dark:hover:bg-orange-500/10"
            >
              ⚠️ Report Post
            </button>
            <button
              type="button"
              onClick={onBlock}
              className="flex h-11 w-full items-center gap-2 px-4 text-sm text-red-500 transition-all duration-200 hover:bg-red-50 dark:hover:bg-red-500/10"
            >
              ⛔ Block User
            </button>
          </>
        )}
        <div className="mt-1 border-t border-slate-200 pt-2 text-center text-xs text-slate-400 dark:border-slate-700 dark:text-slate-500">
          <button type="button" onClick={onClose} className="w-full">
            Cancel
          </button>
        </div>
      </div>
    </div>
  );
}
