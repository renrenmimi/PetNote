import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { uploadImage } from "../services/cloudinary";
import { createPost } from "../services/posts";
import { getUserProfile, type UserProfile } from "../services/users";

const MAX_CHARS = 500;

export function Create() {
  const navigate = useNavigate();
  const { user } = useAuth();
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [file, setFile] = useState<File | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [caption, setCaption] = useState("");
  const [tags, setTags] = useState<string[]>([]);
  const [tagInput, setTagInput] = useState("");
  const [loading, setLoading] = useState(false);
  const [converting, setConverting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [dragActive, setDragActive] = useState(false);
  const [profile, setProfile] = useState<UserProfile | null>(null);

  const remaining = useMemo(
    () => Math.max(0, MAX_CHARS - caption.length),
    [caption]
  );

  useEffect(() => {
    if (!file) {
      setPreviewUrl(null);
      return;
    }

    const url = URL.createObjectURL(file);
    setPreviewUrl(url);

    return () => URL.revokeObjectURL(url);
  }, [file]);

  useEffect(() => {
    let ignore = false;
    if (!user) return;
    const load = async () => {
      const profileData = await getUserProfile(user.uid);
      if (!ignore) setProfile(profileData);
    };
    void load();
    return () => {
      ignore = true;
    };
  }, [user]);

  const handleSelectFile = async (nextFile: File | null) => {
    if (!nextFile) return;
    if (!nextFile.type.startsWith("image/") && !/\.heic$|\.heif$/i.test(nextFile.name)) {
      setError("Please upload an image file.");
      return;
    }
    setError(null);

    const isHeic =
      nextFile.type === "image/heic" ||
      nextFile.type === "image/heif" ||
      /\.heic$/i.test(nextFile.name) ||
      /\.heif$/i.test(nextFile.name);

    if (isHeic) {
      try {
        setConverting(true);
        const heic2any = (await import("heic2any")).default;
        const blob = await heic2any({
          blob: nextFile,
          toType: "image/jpeg",
          quality: 0.85,
        });
        const outputBlob = Array.isArray(blob) ? blob[0] : blob;
        const converted = new File(
          [outputBlob as Blob],
          nextFile.name.replace(/\.heic$/i, ".jpg").replace(/\.heif$/i, ".jpg"),
          { type: "image/jpeg" }
        );
        setFile(converted);
      } catch (err) {
        const message =
          err instanceof Error ? err.message : "Failed to convert image.";
        setError(message);
      } finally {
        setConverting(false);
      }
      return;
    }

    setFile(nextFile);
  };

  const handleDrop = (event: React.DragEvent<HTMLDivElement>) => {
    event.preventDefault();
    setDragActive(false);
    const dropped = event.dataTransfer.files?.[0];
    if (dropped) {
      void handleSelectFile(dropped);
    }
  };

  const handleTagCommit = (value: string) => {
    const normalized = value
      .split(/[,\s]+/)
      .map((tag) => tag.trim())
      .filter(Boolean);

    if (normalized.length === 0) return;

    setTags((prev) => {
      const next = [...prev];
      normalized.forEach((tag) => {
        if (!next.includes(tag)) {
          next.push(tag);
        }
      });
      return next;
    });
  };

  const handleTagKeyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      handleTagCommit(tagInput);
      setTagInput("");
    }
  };

  const handleShare = async () => {
    if (!file || !user || loading) return;
    setLoading(true);
    setError(null);
    setSuccess(null);

    try {
      const mediaUrl = await uploadImage(file);
      await createPost({
        authorId: user.uid,
        authorName:
          profile?.displayName || user.displayName || "PetNote User",
        authorAvatar:
          profile?.avatarUrl ||
          user.photoURL ||
          "https://i.pravatar.cc/150?img=12",
        text: caption.trim(),
        mediaUrl,
        mediaType: "image",
        tags,
      });
      setSuccess("Posted successfully!");
      setTimeout(() => {
        navigate("/", { replace: true });
      }, 600);
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to post. Try again.";
      setError(message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-white pb-10">
      <header className="sticky top-0 z-10 border-b border-slate-200 bg-white">
        <div className="mx-auto flex w-full max-w-md items-center justify-between px-4 py-3">
          <button
            type="button"
            onClick={() => navigate(-1)}
            className="text-xl text-slate-500 hover:text-slate-700"
            aria-label="Go back"
          >
            ←
          </button>
          <h1 className="text-base font-semibold text-slate-900">New Post</h1>
          <button
            type="button"
            onClick={handleShare}
            disabled={loading || !file}
            className="flex items-center gap-2 rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-1.5 text-sm font-semibold text-white shadow-md transition hover:brightness-110 disabled:cursor-not-allowed disabled:bg-slate-200 disabled:text-slate-400"
          >
            {loading ? (
              <>
                <span className="h-4 w-4 animate-spin rounded-full border-2 border-white/70 border-t-transparent" />
                Posting...
              </>
            ) : (
              "Share"
            )}
          </button>
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-6 px-4 py-6">
        <section
          className={`relative flex min-h-[240px] flex-col items-center justify-center rounded-2xl border-2 border-dashed bg-slate-50 text-center transition ${
            dragActive
              ? "border-purple-400 bg-purple-50"
              : "border-slate-200 hover:border-purple-300"
          }`}
          onClick={() => fileInputRef.current?.click()}
          onDragOver={(event) => {
            event.preventDefault();
            setDragActive(true);
          }}
          onDragLeave={() => setDragActive(false)}
          onDrop={handleDrop}
          role="button"
          tabIndex={0}
        >
          {previewUrl ? (
            <div className="relative w-full">
              <img
                src={previewUrl}
                alt="Preview"
                className="max-h-96 w-full rounded-2xl object-cover"
              />
              <button
                type="button"
                onClick={(event) => {
                  event.stopPropagation();
                  setFile(null);
                }}
                className="absolute right-3 top-3 flex h-8 w-8 items-center justify-center rounded-full bg-white/90 text-slate-600 shadow hover:bg-white"
                aria-label="Remove image"
              >
                ✕
              </button>
            </div>
          ) : (
            <div className="space-y-2 px-4">
              <div className="text-3xl">📷</div>
              <p className="text-sm font-semibold text-slate-700">
                {converting ? "Converting image..." : "Tap to add photo"}
              </p>
              <p className="text-xs text-slate-400">
                Drag & drop or click to upload
              </p>
            </div>
          )}

          <input
            ref={fileInputRef}
            type="file"
            accept="image/jpeg,image/png,image/gif,image/webp,image/heic,image/heif"
            className="hidden"
            onChange={(event) =>
              handleSelectFile(event.target.files?.[0] ?? null)
            }
          />
        </section>

        <section className="space-y-2">
          <div className="flex items-center justify-between">
            <label className="text-sm font-semibold text-slate-700">
              Caption
            </label>
            <span
              className={`text-xs ${
                remaining === 0 ? "text-red-500" : "text-slate-400"
              }`}
            >
              {remaining} left
            </span>
          </div>
          <textarea
            placeholder="Write a caption..."
            maxLength={MAX_CHARS}
            rows={4}
            className="w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200"
            value={caption}
            onChange={(event) => setCaption(event.target.value)}
          />
        </section>

        <section className="space-y-2">
          <label className="text-sm font-semibold text-slate-700">Tags</label>
          <input
            type="text"
            placeholder="Add tags (e.g. cat, cute)"
            className="w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200"
            value={tagInput}
            onChange={(event) => setTagInput(event.target.value)}
            onKeyDown={handleTagKeyDown}
            onBlur={() => {
              handleTagCommit(tagInput);
              setTagInput("");
            }}
          />
          {tags.length > 0 ? (
            <div className="flex flex-wrap gap-2">
              {tags.map((tag) => (
                <span
                  key={tag}
                  className="flex items-center gap-1 rounded-full bg-purple-50 px-3 py-1 text-xs font-semibold text-purple-600"
                >
                  #{tag}
                  <button
                    type="button"
                    onClick={() =>
                      setTags((prev) => prev.filter((item) => item !== tag))
                    }
                    className="text-purple-400 hover:text-purple-600"
                    aria-label={`Remove ${tag}`}
                  >
                    ✕
                  </button>
                </span>
              ))}
            </div>
          ) : null}
        </section>

        {success ? (
          <div className="rounded-2xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-600">
            {success}
          </div>
        ) : null}

        {error ? (
          <div className="rounded-2xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-600">
            {error}
          </div>
        ) : null}
      </main>
    </div>
  );
}
