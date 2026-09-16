import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useModalBehavior } from "../hooks/useModalBehavior";
import { useToast } from "../contexts/ToastContext";
import type { Post } from "../services/posts";
import { generateShareCard } from "./ShareCard";
import { canShare, shareImage, shareLink } from "../services/share";

const SHARE_TITLE = "Check out this cute pet on PetNote!";

type ShareMenuProps = {
  open: boolean;
  onClose: () => void;
  postId?: string;
  shareUrl?: string;
  text?: string;
  post?: Post;
};

export function ShareMenu({ open, onClose, postId, shareUrl, text, post }: ShareMenuProps) {
  // A bottom action sheet is modal: it blocks the screen and has its own
  // Cancel. Escape, the scroll lock and focus restoration all apply.
  const panelRef = useModalBehavior({ open, onClose });
  // Computed once at mount rather than in an effect: both inputs — the
  // Capacitor platform and navigator.share — are fixed for the life of the
  // page, so there is nothing to synchronise with.
  const [shareAvailable] = useState(canShare);
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
    const outcome = await shareLink({
      title: SHARE_TITLE,
      text: text ? text.slice(0, 100) : "",
      url: postUrl,
    });
    if (!mountedRef.current) return;
    // Dismissing the sheet is a decision, not an error — say nothing.
    if (outcome === "cancelled") return;
    if (outcome === "shared") {
      onClose();
      return;
    }
    // A real failure used to be a console.warn nobody would ever see.
    showToast(
      outcome === "unsupported"
        ? "Sharing is not available here. Copy the link instead."
        : "Could not open the share sheet. Copy the link instead.",
      "error"
    );
  };

  const handleShareImage = async () => {
    if (!post || sharingImage) return;
    setSharingImage(true);
    let blob: Blob;
    try {
      blob = await generateShareCard(post);
    } catch {
      if (mountedRef.current) {
        setSharingImage(false);
        showToast("Could not build the share card", "error");
      }
      return;
    }
    const outcome = await shareImage({
      blob,
      fileName: "petnote-share.png",
      title: SHARE_TITLE,
      text: text ? text.slice(0, 100) : "",
    });
    if (!mountedRef.current) return;
    setSharingImage(false);
    if (outcome === "cancelled") return;
    if (outcome === "shared") {
      onClose();
      return;
    }
    showToast("Could not share the image", "error");
  };

  // Portal to <body> so transformed ancestors (PostCard hover lift, page
  // transition) can't become the containing block for this fixed sheet.
  return createPortal(
    <div
      className="fixed inset-0 z-50 flex items-end justify-center bg-black/50"
      onClick={onClose}
      role="dialog"
      aria-modal="true"
      aria-label="Share"
    >
      <div
        ref={panelRef}
        tabIndex={-1}
        className="w-full max-w-md rounded-t-2xl bg-white px-4 pb-[max(env(safe-area-inset-bottom),1rem)] pt-4 shadow-[0_-20px_50px_-30px_rgba(15,23,42,0.4)] transition-all duration-300 dark:bg-slate-800"
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
        {/* Adapter, not `navigator.share`: WKWebView defines that method
            and then rejects every call, which is why this button was dead. */}
        {shareAvailable ? (
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

    </div>,
    document.body
  );
}
