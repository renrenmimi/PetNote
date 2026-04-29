import { useEffect, useMemo, useRef, useState } from "react";
import { useToast } from "../contexts/ToastContext";
import { submitReview } from "../services/locations";
import { useAuth } from "../hooks/useAuth";
import { uploadImage } from "../services/cloudinary";

type LocationRatingModalProps = {
  open: boolean;
  onClose: () => void;
  locationId: string;
  locationName: string;
  locationAddress: string;
  meetupId?: string;
  onSubmitted?: () => void;
};

const tagOptions = [
  "🌳 Spacious",
  "🐕 Off-leash area",
  "💧 Water access",
  "🅿️ Easy parking",
  "🚽 Restrooms nearby",
  "🪑 Seating available",
  "🌙 Well-lit",
  "🐕‍🦺 Dog-friendly",
  "🐱 Cat-friendly",
  "☕ Café nearby",
  "🏖️ Beach access",
  "🏃 Trails available",
];

const range = [1, 2, 3, 4, 5];

export function LocationRatingModal({
  open,
  onClose,
  locationId,
  locationName,
  locationAddress,
  meetupId,
  onSubmitted,
}: LocationRatingModalProps) {
  const { user, profile } = useAuth();
  const { showToast } = useToast();
  const [rating, setRating] = useState(0);
  const [space, setSpace] = useState(0);
  const [safety, setSafety] = useState(0);
  const [cleanliness, setCleanliness] = useState(0);
  const [comment, setComment] = useState("");
  const [tags, setTags] = useState<string[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const [photos, setPhotos] = useState<File[]>([]);
  const [photoPreviews, setPhotoPreviews] = useState<string[]>([]);
  const mountedRef = useRef(true);

  const remaining = useMemo(() => 300 - comment.length, [comment]);

  useEffect(() => {
    const urls = photos.map((file) => URL.createObjectURL(file));
    setPhotoPreviews(urls);
    return () => {
      urls.forEach((url) => URL.revokeObjectURL(url));
    };
  }, [photos]);

  useEffect(() => {
    if (!open) {
      setRating(0);
      setSpace(0);
      setSafety(0);
      setCleanliness(0);
      setComment("");
      setTags([]);
      setPhotos([]);
    }
  }, [open]);

  useEffect(() => {
    return () => {
      mountedRef.current = false;
    };
  }, []);

  if (!open) return null;

  const toggleTag = (tag: string) => {
    setTags((prev) =>
      prev.includes(tag) ? prev.filter((t) => t !== tag) : [...prev, tag]
    );
  };

  const handleSubmit = async () => {
    if (!user) return;
    if (rating === 0) {
      showToast("Please provide an overall rating.", "warning");
      return;
    }
    setSubmitting(true);
    try {
      const photoUrls = await Promise.all(photos.map((file) => uploadImage(file)));
      const reviewPayload: Parameters<typeof submitReview>[1] = {
        userId: user.uid,
        userName: profile?.displayName || user.displayName || "PetNote User",
        userAvatar:
          profile?.avatarUrl ||
          user.photoURL ||
          `https://api.dicebear.com/7.x/thumbs/svg?seed=${user.uid}`,
        rating,
        comment: comment.trim(),
        photos: photoUrls,
        tags,
        petFriendly: {
          space: space || rating,
          safety: safety || rating,
          cleanliness: cleanliness || rating,
        },
      };
      if (meetupId) {
        reviewPayload.meetupId = meetupId;
      }
      await submitReview(locationId, {
        ...reviewPayload,
      });
      showToast("Thanks for your review! 🐾", "success");
      onSubmitted?.();
      onClose();
    } catch {
      showToast("Failed to submit review.", "error");
    } finally {
      if (mountedRef.current) {
        setSubmitting(false);
      }
    }
  };

  const handlePhotos = (files: FileList | null) => {
    if (!files) return;
    const incoming = Array.from(files);
    const available = 3 - photos.length;
    if (available <= 0) return;
    setPhotos((prev) => [...prev, ...incoming.slice(0, available)]);
  };

  const removePhoto = (index: number) => {
    setPhotos((prev) => prev.filter((_, idx) => idx !== index));
  };

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 px-4 pb-6">
      <div className="w-full max-w-md rounded-2xl bg-white p-5 shadow-xl dark:bg-slate-800">
        <div className="flex items-center justify-between">
          <h3 className="text-base font-semibold text-slate-900 dark:text-white">
            Rate this location 📍
          </h3>
          <button
            type="button"
            onClick={onClose}
            className="text-slate-400 hover:text-slate-600 dark:text-slate-300"
          >
            ✕
          </button>
        </div>
        <div className="mt-2 text-sm text-slate-500 dark:text-slate-300">
          <p className="font-semibold text-slate-900 dark:text-white">
            {locationName}
          </p>
          <p>{locationAddress}</p>
        </div>

        <div className="mt-4">
          <p className="text-sm font-semibold text-slate-900 dark:text-white">
            Overall rating
          </p>
          <div className="mt-2 flex items-center gap-2 text-2xl">
            {range.map((value) => (
              <button
                key={value}
                type="button"
                onClick={() => setRating(value)}
                className={`transition-transform duration-150 ${
                  rating >= value ? "scale-110 text-amber-500" : "text-slate-300"
                }`}
              >
                {rating >= value ? "⭐" : "☆"}
              </button>
            ))}
          </div>
        </div>

        <div className="mt-4 space-y-3 text-sm text-slate-600 dark:text-slate-300">
          <p className="font-semibold text-slate-900 dark:text-white">
            Pet-friendly details
          </p>
          {[
            { label: "🐾 Space for pets", value: space, setter: setSpace },
            { label: "🛡️ Safety", value: safety, setter: setSafety },
            { label: "✨ Cleanliness", value: cleanliness, setter: setCleanliness },
          ].map((item) => (
            <div key={item.label} className="flex items-center justify-between">
              <span>{item.label}</span>
              <div className="flex items-center gap-1">
                {range.map((value) => (
                  <button
                    key={value}
                    type="button"
                    onClick={() => item.setter(value)}
                    className={`h-2 w-2 rounded-full transition-all duration-150 ${
                      item.value >= value
                        ? "bg-gradient-to-r from-purple-500 to-pink-500"
                        : "bg-slate-300 dark:bg-slate-600"
                    }`}
                  />
                ))}
              </div>
            </div>
          ))}
        </div>

        <div className="mt-4">
          <p className="text-sm font-semibold text-slate-900 dark:text-white">
            What&apos;s great about this place?
          </p>
          <div className="mt-2 flex flex-wrap gap-2">
            {tagOptions.map((tag) => {
              const selected = tags.includes(tag);
              return (
                <button
                  key={tag}
                  type="button"
                  onClick={() => toggleTag(tag)}
                  className={`rounded-full px-3 py-1 text-xs font-semibold transition-all duration-200 ${
                    selected
                      ? "bg-gradient-to-r from-purple-500 to-pink-500 text-white"
                      : "border border-slate-300 text-slate-600 dark:border-slate-600 dark:text-slate-300"
                  }`}
                >
                  {tag}
                </button>
              );
            })}
          </div>
        </div>

        <div className="mt-4">
          <div className="flex items-center justify-between">
            <p className="text-sm font-semibold text-slate-900 dark:text-white">
              Add photos (optional)
            </p>
            <span className="text-xs text-slate-400">{photos.length}/3</span>
          </div>
          <div className="mt-2 grid grid-cols-3 gap-2">
            {photoPreviews.map((url, idx) => (
              <div key={url} className="relative aspect-square overflow-hidden rounded-xl">
                <img src={url} alt={`Upload ${idx + 1}`} className="h-full w-full object-cover" />
                <button
                  type="button"
                  onClick={() => removePhoto(idx)}
                  className="absolute right-1 top-1 flex h-5 w-5 items-center justify-center rounded-full bg-black/60 text-[10px] text-white"
                >
                  ✕
                </button>
              </div>
            ))}
            {photos.length < 3 ? (
              <label className="flex aspect-square items-center justify-center rounded-xl border border-dashed border-slate-300 text-xs text-slate-400 dark:border-slate-600">
                +
                <input
                  type="file"
                  accept="image/*"
                  multiple
                  className="hidden"
                  onChange={(event) => handlePhotos(event.target.files)}
                />
              </label>
            ) : null}
          </div>
        </div>

        <div className="mt-4">
          <div className="flex items-center justify-between">
            <p className="text-sm font-semibold text-slate-900 dark:text-white">
              Share your experience
            </p>
            <span
              className={`text-xs ${
                remaining <= 60 ? "text-amber-500" : "text-slate-400"
              }`}
            >
              {comment.length}/300
            </span>
          </div>
          <textarea
            value={comment}
            onChange={(event) => setComment(event.target.value)}
            maxLength={300}
            rows={3}
            placeholder="Share your experience about this location..."
            className="mt-2 w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
          />
        </div>

        <button
          type="button"
          onClick={handleSubmit}
          disabled={submitting}
          className="mt-4 w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white shadow-[0_12px_25px_-15px_rgba(168,85,247,0.8)] transition-all duration-200 hover:scale-[1.01] disabled:cursor-not-allowed disabled:opacity-70"
        >
          {submitting ? "Submitting..." : "Submit Review"}
        </button>
      </div>
    </div>
  );
}
