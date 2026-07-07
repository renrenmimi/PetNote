import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  deleteCloudinaryAssets,
  uploadMedia,
  type UploadedAsset,
} from "../services/cloudinary";
import { checkIn } from "../services/checkins";
import { useToast } from "../contexts/ToastContext";
import { useAuth } from "../hooks/useAuth";
import Avatar from "./Avatar";

interface CheckInModalProps {
  open: boolean;
  onClose: () => void;
  locationId: string;
  locationName: string;
  currentUser: {
    uid: string;
    name: string;
    avatar: string;
  };
  userPets?: Array<{
    id: string;
    name: string;
    avatarUrl?: string;
  }>;
  onSuccess?: () => void;
}

const MAX_CAPTION = 150;

export function CheckInModal({
  open,
  onClose,
  locationId,
  locationName,
  currentUser,
  userPets = [],
  onSuccess,
}: CheckInModalProps) {
  const { showToast } = useToast();
  const { user } = useAuth();
  const requiresEmailVerification = !!user && !user.emailVerified;
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const previewUrlRef = useRef<string | null>(null);
  const mountedRef = useRef(true);
  const [file, setFile] = useState<File | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [caption, setCaption] = useState("");
  const [selectedPetId, setSelectedPetId] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const revokePreviewUrl = useCallback(() => {
    if (!previewUrlRef.current) return;
    URL.revokeObjectURL(previewUrlRef.current);
    previewUrlRef.current = null;
  }, []);

  useEffect(() => {
    if (open) return;
    setFile(null);
    setCaption("");
    setSelectedPetId(null);
    revokePreviewUrl();
    setPreviewUrl(null);
  }, [open, revokePreviewUrl]);

  useEffect(() => {
    // Re-arm on each mount so StrictMode's double-effect cycle doesn't
    // leave the flag stuck at false after the first dev-only cleanup.
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      revokePreviewUrl();
    };
  }, [revokePreviewUrl]);

  if (!open) return null;

  const remaining = MAX_CAPTION - caption.length;
  const counterTone =
    remaining <= 0
      ? "text-red-500"
      : remaining <= Math.ceil(MAX_CAPTION * 0.2)
      ? "text-amber-500"
      : "text-slate-400 dark:text-slate-500";

  const handleSelect = (selected: File | null) => {
    if (!selected) return;
    if (!selected.type.startsWith("image/")) {
      showToast("Please select an image", "warning");
      return;
    }
    const objectUrl = URL.createObjectURL(selected);
    revokePreviewUrl();
    previewUrlRef.current = objectUrl;
    setFile(selected);
    setPreviewUrl(objectUrl);
  };

  const handleSubmit = async () => {
    if (!file || submitting) return;
    if (requiresEmailVerification) {
      showToast("Please verify your email before checking in.", "warning");
      return;
    }
    setSubmitting(true);
    const uploaded: UploadedAsset[] = [];
    try {
      const upload = await uploadMedia(file);
      uploaded.push(upload);
      const selectedPet = userPets.find((pet) => pet.id === selectedPetId);
      await checkIn(locationId, {
        userId: currentUser.uid,
        userName: currentUser.name,
        userAvatar: currentUser.avatar,
        photoUrl: upload.url,
        caption: caption.trim() || undefined,
        petId: selectedPet?.id,
        petName: selectedPet?.name,
      });
      showToast("Checked in! 📍", "success");
      onSuccess?.();
      onClose();
    } catch {
      // Best-effort orphan cleanup before surfacing the original error toast.
      void deleteCloudinaryAssets(uploaded);
      showToast("Check-in failed. Try again.", "error");
    } finally {
      if (mountedRef.current) {
        setSubmitting(false);
      }
    }
  };

  // Portal to <body> so transformed ancestors (page transition, card hover)
  // can't become the containing block for this fixed overlay.
  return createPortal(
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      onClick={onClose}
    >
      <div
        className="w-full max-w-sm rounded-2xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)] dark:bg-slate-800"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="flex items-center justify-between">
          <div>
            <h3 className="text-base font-semibold text-slate-900 dark:text-white">
              📍 Check In
            </h3>
            <p className="text-xs text-slate-500 dark:text-slate-400">
              {locationName}
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="text-sm text-slate-400 hover:text-slate-600 dark:text-slate-500"
          >
            ✕
          </button>
        </div>

        <div className="mt-4 space-y-3">
          <div
            className="flex h-40 cursor-pointer flex-col items-center justify-center rounded-2xl border-2 border-dashed border-slate-200 bg-slate-50 text-center text-xs text-slate-500 transition hover:border-purple-300 dark:border-slate-700 dark:bg-slate-900"
            onClick={() => fileInputRef.current?.click()}
          >
            {previewUrl ? (
              <img
                src={previewUrl}
                alt="Check-in"
                className="h-full w-full rounded-2xl object-cover"
              />
            ) : (
              <>
                <div className="text-2xl">📸</div>
                <p className="mt-2 font-semibold text-slate-600 dark:text-slate-300">
                  Take a photo at this location
                </p>
                <p className="text-[11px] text-slate-400">
                  Tap to upload
                </p>
              </>
            )}
            <input
              ref={fileInputRef}
              type="file"
              accept="image/*"
              className="hidden"
              onChange={(event) => handleSelect(event.target.files?.[0] || null)}
            />
          </div>

          <div>
            <div className="flex items-center justify-between">
              <label className="text-xs font-semibold text-slate-600 dark:text-slate-300">
                Caption (optional)
              </label>
              <span className={`text-xs ${counterTone}`}>
                {caption.length}/{MAX_CAPTION}
              </span>
            </div>
            <textarea
              value={caption}
              onChange={(event) => setCaption(event.target.value)}
              maxLength={MAX_CAPTION}
              rows={3}
              placeholder="What are you doing here? 🐾"
              className="mt-2 w-full rounded-2xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-900 dark:text-white"
            />
          </div>

          {userPets.length > 0 ? (
            <div>
              <p className="text-xs font-semibold text-slate-600 dark:text-slate-300">
                Which pet is with you? (optional)
              </p>
              <div className="mt-2 flex gap-2 overflow-x-auto pb-1">
                {userPets.map((pet) => {
                  const selected = selectedPetId === pet.id;
                  return (
                    <button
                      key={pet.id}
                      type="button"
                      onClick={() =>
                        setSelectedPetId((prev) =>
                          prev === pet.id ? null : pet.id
                        )
                      }
                      className={`flex min-w-[96px] items-center gap-2 rounded-xl border px-2 py-1.5 text-left transition-all duration-200 ${
                        selected
                          ? "border-purple-400 bg-purple-50 dark:border-purple-400 dark:bg-purple-500/20"
                          : "border-slate-200 bg-white dark:border-slate-700 dark:bg-slate-900"
                      }`}
                    >
                      <Avatar
                        src={pet.avatarUrl}
                        alt={pet.name}
                        userId={pet.id}
                        size={24}
                        className="h-6 w-6"
                      />
                      <span className="truncate text-xs font-semibold text-slate-700 dark:text-slate-200">
                        {pet.name}
                      </span>
                    </button>
                  );
                })}
              </div>
            </div>
          ) : null}
        </div>

        <button
          type="button"
          disabled={!file || submitting || requiresEmailVerification}
          onClick={handleSubmit}
          className="mt-4 w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white shadow-md transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
        >
          {submitting
            ? "Checking in..."
            : requiresEmailVerification
            ? "🔒 Verify Email to Check In"
            : "Check In"}
        </button>
      </div>
    </div>,
    document.body
  );
}
