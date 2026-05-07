import { useEffect, useMemo, useRef, useState } from "react";
import { useToast } from "../contexts/ToastContext";
import type { Post } from "../services/posts";
import { generateShareCard } from "./ShareCard";

type ShareMenuProps = {
  open: boolean;
  onClose: () => void;
  postId?: string;
  shareUrl?: string;
  text?: string;
  post?: Post;
};

export function ShareMenu({ open, onClose, postId, shareUrl, text, post }: ShareMenuProps) {
  const [canShare, setCanShare] = useState(false);
  const [sharingImage, setSharingImage] = useState(false);
  const mountedRef = useRef(true);
  const { showToast } = useToast();

  const postUrl = useMemo(() => {
    if (shareUrl) return shareUrl;
    if (typeof window === "undefined") return postId ? `/post/${postId}` : "/";
    if (postId) return `${window.location.origin}/post/${postId}`;
    return window.location.href;
  }, [postId, shareUrl]);

  useEffect(() => {
    setCanShare(typeof navigator !== "undefined" && !!navigator.share);
  }, []);

  useEffect(() => {
    // Re-arm on each mount so StrictMode's double-effect cycle doesn't
    // leave the flag stuck at false after the first dev-only cleanup.
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
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
    try {
      await navigator.share({
        title: "Check out this cute pet on PetNote!",
        text: text ? text.slice(0, 100) : "",
        url: postUrl,
      });
    } catch (error) {
      // navigator.share rejects with AbortError when the user dismisses
      // the share sheet — that's a normal interaction, not an error
      // worth surfacing or logging. Anything else we still want to see
      // in the console.
      if (!(error instanceof DOMException && error.name === "AbortError")) {
        console.warn("Share failed:", error);
      }
    }
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
        try {
          const link = document.createElement("a");
          link.href = url;
          link.download = "petnote-share.png";
          document.body.appendChild(link);
          link.click();
          link.remove();
        } finally {
          URL.revokeObjectURL(url);
        }
        showToast("Share card downloaded", "success");
      }
    } catch {
      showToast("Failed to generate share card", "error");
    } finally {
      if (mountedRef.current) {
        setSharingImage(false);
      }
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
