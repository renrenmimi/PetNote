import { useEffect, useRef, useState } from "react";
import { uploadMedia } from "../services/cloudinary";
import { checkIn } from "../services/checkins";
import { useToast } from "../contexts/ToastContext";

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
  onSuccess?: () => void;
}

const MAX_CAPTION = 150;

export function CheckInModal({
  open,
  onClose,
  locationId,
  locationName,
  currentUser,
  onSuccess,
}: CheckInModalProps) {
  const { showToast } = useToast();
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [file, setFile] = useState<File | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [caption, setCaption] = useState("");
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!open) {
      setFile(null);
      setCaption("");
      if (previewUrl) URL.revokeObjectURL(previewUrl);
      setPreviewUrl(null);
    }
  }, [open]);

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
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    setFile(selected);
    setPreviewUrl(URL.createObjectURL(selected));
  };

  const handleSubmit = async () => {
    if (!file || submitting) return;
    setSubmitting(true);
    try {
      const upload = await uploadMedia(file);
      await checkIn(locationId, {
        userId: currentUser.uid,
        userName: currentUser.name,
        userAvatar: currentUser.avatar,
        photoUrl: upload.url,
        caption: caption.trim() || undefined,
      });
      showToast("Checked in! 📍", "success");
      onSuccess?.();
      onClose();
    } catch {
      showToast("Check-in failed. Try again.", "error");
    } finally {
      setSubmitting(false);
    }
  };

  return (
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
        </div>

        <button
          type="button"
          disabled={!file || submitting}
          onClick={handleSubmit}
          className="mt-4 w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white shadow-md transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
        >
          {submitting ? "Checking in..." : "Check In"}
        </button>
      </div>
    </div>
  );
}
