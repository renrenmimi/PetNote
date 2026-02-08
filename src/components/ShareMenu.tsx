import { useEffect, useMemo, useState } from "react";
import { useToast } from "../contexts/ToastContext";
import type { Post } from "../services/posts";
import { generateShareCard } from "./ShareCard";

type ShareMenuProps = {
  open: boolean;
  onClose: () => void;
  postId: string;
  text?: string;
  post?: Post;
};

export function ShareMenu({ open, onClose, postId, text, post }: ShareMenuProps) {
  const [canShare, setCanShare] = useState(false);
  const [sharingImage, setSharingImage] = useState(false);
  const { showToast } = useToast();

  const postUrl = useMemo(() => {
    if (typeof window === "undefined") return `/post/${postId}`;
    return `${window.location.origin}/post/${postId}`;
  }, [postId]);

  useEffect(() => {
    setCanShare(typeof navigator !== "undefined" && !!navigator.share);
  }, []);

  if (!open) return null;

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(postUrl);
      showToast("Link copied!", "success");
    } catch {
      showToast("Unable to copy link", "error");
      // ignore
    }
  };

  const handleShare = async () => {
    if (!navigator.share) return;
    await navigator.share({
      title: "Check out this cute pet on PetNote!",
      text: text ? text.slice(0, 100) : "",
      url: postUrl,
    });
  };

  const handleShareImage = async () => {
    if (!post) return;
    setSharingImage(true);
    try {
      const blob = await generateShareCard(post);
      const file = new File([blob], "petnote-share.png", { type: "image/png" });
      if (navigator.share && navigator.canShare?.({ files: [file] })) {
        await navigator.share({
          files: [file],
          title: "Check out this cute pet on PetNote!",
          text: text ? text.slice(0, 100) : "",
        });
      } else {
        const url = URL.createObjectURL(blob);
        const link = document.createElement("a");
        link.href = url;
        link.download = "petnote-share.png";
        document.body.appendChild(link);
        link.click();
        link.remove();
        URL.revokeObjectURL(url);
        showToast("Share card downloaded", "success");
      }
    } catch {
      showToast("Failed to generate share card", "error");
    } finally {
      setSharingImage(false);
    }
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center bg-black/50"
      onClick={onClose}
    >
      <div
        className="w-full max-w-md rounded-t-2xl bg-white px-4 py-4 shadow-[0_-20px_50px_-30px_rgba(15,23,42,0.4)] transition-all duration-300 dark:bg-slate-800"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="mx-auto mb-3 h-1.5 w-12 rounded-full bg-slate-200 dark:bg-slate-700" />
        <button
          type="button"
          onClick={handleCopy}
          className="flex w-full items-center gap-3 border-b border-slate-100 px-2 py-4 text-sm text-slate-700 dark:border-slate-700 dark:text-slate-200"
        >
          <span className="text-lg">🔗</span>
          Copy Link
        </button>
        {canShare ? (
          <button
            type="button"
            onClick={handleShare}
            className="flex w-full items-center gap-3 border-b border-slate-100 px-2 py-4 text-sm text-slate-700 dark:border-slate-700 dark:text-slate-200"
          >
            <span className="text-lg">📤</span>
            Share to...
          </button>
        ) : null}
        {post ? (
          <button
            type="button"
            onClick={handleShareImage}
            disabled={sharingImage}
            className="flex w-full items-center gap-3 border-b border-slate-100 px-2 py-4 text-sm text-slate-700 disabled:opacity-60 dark:border-slate-700 dark:text-slate-200"
          >
            <span className="text-lg">🖼️</span>
            {sharingImage ? "Generating card..." : "Share as Image"}
          </button>
        ) : null}
        <button
          type="button"
          onClick={onClose}
          className="flex w-full items-center gap-3 px-2 py-4 text-sm text-slate-500 dark:text-slate-300"
        >
          <span className="text-lg">✕</span>
          Cancel
        </button>
      </div>

    </div>
  );
}
