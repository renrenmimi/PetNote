import { useEffect, useMemo, useState } from "react";

type ShareMenuProps = {
  open: boolean;
  onClose: () => void;
  postId: string;
  text?: string;
};

export function ShareMenu({ open, onClose, postId, text }: ShareMenuProps) {
  const [copied, setCopied] = useState(false);
  const [canShare, setCanShare] = useState(false);

  const postUrl = useMemo(() => {
    if (typeof window === "undefined") return `/post/${postId}`;
    return `${window.location.origin}/post/${postId}`;
  }, [postId]);

  useEffect(() => {
    setCanShare(typeof navigator !== "undefined" && !!navigator.share);
  }, []);

  useEffect(() => {
    if (!copied) return;
    const timer = window.setTimeout(() => setCopied(false), 2000);
    return () => window.clearTimeout(timer);
  }, [copied]);

  if (!open) return null;

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(postUrl);
      setCopied(true);
    } catch {
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
        <button
          type="button"
          onClick={onClose}
          className="flex w-full items-center gap-3 px-2 py-4 text-sm text-slate-500 dark:text-slate-300"
        >
          <span className="text-lg">✕</span>
          Cancel
        </button>
      </div>

      {copied ? (
        <div className="fixed bottom-24 left-1/2 z-50 -translate-x-1/2 rounded-full bg-slate-900 px-4 py-2 text-xs font-semibold text-white shadow-lg dark:bg-slate-200 dark:text-slate-900">
          Link copied!
        </div>
      ) : null}
    </div>
  );
}
