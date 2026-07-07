import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { createInvitation, getActiveInvitation, type Invitation } from "../services/invitations";
import { useToast } from "../contexts/ToastContext";

type InviteCodeModalProps = {
  isOpen: boolean;
  petId: string;
  petName: string;
  userId: string;
  userName: string;
  onClose: () => void;
};

const formatCode = (code: string): string => {
  const normalized = code.replace(/\s+/g, "").toUpperCase();
  if (normalized.length <= 4) return normalized;
  return `${normalized.slice(0, 4)} ${normalized.slice(4, 8)}`;
};

const getExpiresInLabel = (expiresAtMillis: number): string => {
  const diffMs = Math.max(0, expiresAtMillis - Date.now());
  const totalMinutes = Math.floor(diffMs / 60000);
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return `Expires in ${hours}h ${minutes}m`;
};

export function InviteCodeModal({
  isOpen,
  petId,
  petName,
  userId,
  userName,
  onClose,
}: InviteCodeModalProps) {
  const [activeInvitation, setActiveInvitation] = useState<Invitation | null>(null);
  const [loading, setLoading] = useState(false);
  const [generating, setGenerating] = useState(false);
  const mountedRef = useRef(true);
  const openRef = useRef(isOpen);
  const { showToast } = useToast();

  const formattedCode = useMemo(
    () => (activeInvitation?.code ? formatCode(activeInvitation.code) : ""),
    [activeInvitation?.code]
  );

  useEffect(() => {
    openRef.current = isOpen;
    if (!isOpen) {
      setLoading(false);
      setGenerating(false);
    }
  }, [isOpen]);

  useEffect(() => {
    // Re-arm on each mount so StrictMode's double-effect cycle doesn't
    // leave the flag stuck at false after the first dev-only cleanup.
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  useEffect(() => {
    let ignore = false;
    if (!isOpen) return;

    const load = async () => {
      setLoading(true);
      try {
        const invitation = await getActiveInvitation(petId);
        if (!ignore) {
          setActiveInvitation(invitation);
        }
      } catch {
        if (!ignore) {
          showToast("Failed to load invitation codes.", "error");
        }
      } finally {
        if (!ignore) {
          setLoading(false);
        }
      }
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [isOpen, petId, showToast]);

  const handleGenerateCode = async () => {
    if (generating) return;
    setGenerating(true);
    try {
      const invitation = await createInvitation(petId, userId, userName);
      if (!mountedRef.current || !openRef.current) return;
      setActiveInvitation(invitation);
      showToast("Invitation code generated.", "success");
    } catch (error) {
      if (!mountedRef.current || !openRef.current) return;
      const message =
        error instanceof Error ? error.message : "Could not generate invitation code.";
      showToast(message, "error");
    } finally {
      if (mountedRef.current && openRef.current) {
        setGenerating(false);
      }
    }
  };

  const handleCopy = async () => {
    if (!activeInvitation?.code) return;
    try {
      await navigator.clipboard.writeText(activeInvitation.code);
      showToast("Code copied.", "success");
    } catch {
      showToast("Unable to copy code.", "error");
    }
  };

  const handleShare = async () => {
    if (!activeInvitation?.code) return;
    const message = `Join ${petName}'s family on PetNote with this invitation code: ${formatCode(
      activeInvitation.code
    )}`;
    if (navigator.share) {
      try {
        await navigator.share({ text: message });
      } catch {
        // Ignore cancelled shares.
      }
      return;
    }
    try {
      await navigator.clipboard.writeText(message);
      showToast("Invite message copied.", "success");
    } catch {
      showToast("Unable to share invitation.", "error");
    }
  };

  if (!isOpen) return null;

  // Portal to <body> so transformed ancestors can't reposition this overlay.
  return createPortal(
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4" onClick={onClose}>
      <div
        className="w-full max-w-sm rounded-2xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)] dark:bg-slate-800"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="text-base font-semibold text-slate-900 dark:text-white">
              Invite Family Member
            </h3>
            <p className="mt-1 text-xs text-slate-500 dark:text-slate-300">
              Share this code so someone can join {petName}&apos;s profile.
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="text-sm text-slate-500 hover:text-slate-700 dark:text-slate-300"
          >
            Close
          </button>
        </div>

        <div className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-center dark:border-slate-700 dark:bg-slate-900">
          {loading ? (
            <p className="text-sm text-slate-500 dark:text-slate-300">Loading invitation...</p>
          ) : activeInvitation?.code ? (
            <>
              <p className="font-mono text-2xl font-bold tracking-widest text-slate-900 dark:text-white">
                {formattedCode}
              </p>
              <p className="mt-2 text-xs text-slate-500 dark:text-slate-300">
                {getExpiresInLabel(activeInvitation.expiresAtMillis)}
              </p>
            </>
          ) : (
            <p className="text-sm text-slate-500 dark:text-slate-300">
              No active invitation code yet.
            </p>
          )}
        </div>

        <div className="mt-4 flex flex-wrap items-center gap-2">
          {!activeInvitation?.code ? (
            <button
              type="button"
              onClick={handleGenerateCode}
              disabled={generating}
              className="flex-1 rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
            >
              {generating ? "Generating..." : "Generate Invitation Code"}
            </button>
          ) : (
            <>
              <button
                type="button"
                onClick={handleCopy}
                className="flex-1 rounded-full border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-700 transition-all duration-200 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-300"
              >
                Copy Code
              </button>
              <button
                type="button"
                onClick={handleShare}
                className="flex-1 rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110"
              >
                Share
              </button>
            </>
          )}
        </div>

        <p className="mt-3 text-center text-xs text-slate-400 dark:text-slate-500">
          Each code can only be used once.
        </p>
      </div>
    </div>,
    document.body
  );
}
