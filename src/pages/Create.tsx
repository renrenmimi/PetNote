import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { uploadMedia } from "../services/cloudinary";
import { createPost, type MediaItem } from "../services/posts";
import { getPetsByOwner, type Pet } from "../services/pets";
import { getUserProfile, type UserProfile } from "../services/users";
import { compressImage } from "../utils/imageCompressor";
import { getSpeciesMeta } from "../utils/petHelpers";

const MAX_CHARS = 500;

export function Create() {
  const navigate = useNavigate();
  const { user, isBanned } = useAuth();
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [files, setFiles] = useState<
    Array<{
      id: string;
      fileId: string;
      file: File;
      type: "image" | "video";
      previewUrl: string;
      duration?: number;
      sizeLabel?: string;
    }>
  >([]);
  const [caption, setCaption] = useState("");
  const [tags, setTags] = useState<string[]>([]);
  const [tagInput, setTagInput] = useState("");
  const [loading, setLoading] = useState(false);
  const [converting, setConverting] = useState(false);
  const [compressing, setCompressing] = useState(false);
  const [uploadingIndex, setUploadingIndex] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [duplicateToast, setDuplicateToast] = useState<string | null>(null);
  const [duplicateSkipped, setDuplicateSkipped] = useState(0);
  const [compressToast, setCompressToast] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [dragActive, setDragActive] = useState(false);
  const [profile, setProfile] = useState<UserProfile | null>(null);
  const duplicateTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const compressTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const filesRef = useRef(files);
  const [pets, setPets] = useState<Pet[]>([]);
  const [selectedPetId, setSelectedPetId] = useState<string | null>(null);

  const remaining = useMemo(
    () => Math.max(0, MAX_CHARS - caption.length),
    [caption]
  );

  useEffect(() => {
    let ignore = false;
    if (!user) return;
    const load = async () => {
      const [profileData, petList] = await Promise.all([
        getUserProfile(user.uid),
        getPetsByOwner(user.uid),
      ]);
      if (!ignore) {
        setProfile(profileData);
        setPets(petList);
      }
    };
    void load();
    return () => {
      ignore = true;
    };
  }, [user]);

  useEffect(() => {
    filesRef.current = files;
  }, [files]);

  const validateVideoDuration = (file: File) =>
    new Promise<number>((resolve, reject) => {
      const url = URL.createObjectURL(file);
      const video = document.createElement("video");
      video.preload = "metadata";
      video.onloadedmetadata = () => {
        const duration = video.duration;
        URL.revokeObjectURL(url);
        resolve(duration);
      };
      video.onerror = () => {
        URL.revokeObjectURL(url);
        reject(new Error("Failed to load video metadata"));
      };
      video.src = url;
    });

  const getFileId = (file: File) =>
    `${file.name}-${file.size}-${file.lastModified}`;

  const processFiles = async (incoming: File[]) => {
    if (incoming.length === 0) return;
    setError(null);
    const currentFiles = filesRef.current;
    const availableSlots = 9 - currentFiles.length;
    if (incoming.length > availableSlots) {
      setError("Maximum 9 files allowed");
    }
    const slice = incoming.slice(0, availableSlots);
    const nextItems: typeof files = [];
    const existingIds = new Set(currentFiles.map((item) => item.fileId));
    const seenIds = new Set(existingIds);
    let skippedDuplicates = 0;
    let lastDuplicateName = "";
    let startedCompressing = false;

    const beginCompressing = () => {
      if (startedCompressing) return;
      startedCompressing = true;
      setCompressing(true);
      setCompressToast("Compressing images...");
    };

    for (const rawFile of slice) {
      const rawId = getFileId(rawFile);
      if (seenIds.has(rawId)) {
        skippedDuplicates += 1;
        lastDuplicateName = rawFile.name;
        continue;
      }
      seenIds.add(rawId);

      const isHeic =
        rawFile.type === "image/heic" ||
        rawFile.type === "image/heif" ||
        /\.heic$/i.test(rawFile.name) ||
        /\.heif$/i.test(rawFile.name);

      const isImage = rawFile.type.startsWith("image/") || isHeic;
      const isVideo = rawFile.type.startsWith("video/");

      if (!isImage && !isVideo) {
        setError("Unsupported file format");
        continue;
      }

      let file = rawFile;
      let duration: number | undefined;
      let sizeLabel: string | undefined;

      if (isHeic) {
        try {
          setConverting(true);
          const heic2any = (await import("heic2any")).default;
          const blob = await heic2any({
            blob: rawFile,
            toType: "image/jpeg",
            quality: 0.85,
          });
          const outputBlob = Array.isArray(blob) ? blob[0] : blob;
          file = new File(
            [outputBlob as Blob],
            rawFile.name
              .replace(/\.heic$/i, ".jpg")
              .replace(/\.heif$/i, ".jpg"),
            { type: "image/jpeg", lastModified: rawFile.lastModified }
          );
        } catch {
          setError("Failed to convert image.");
          continue;
        } finally {
          setConverting(false);
        }
      }

      if (file.type.startsWith("image/") && file.type !== "image/gif") {
        try {
          beginCompressing();
          const originalSize = file.size;
          const compressed = await compressImage(file, {
            maxWidth: 1920,
            maxHeight: 1920,
            quality: 0.8,
            maxSizeMB: 2,
          });
          if (compressed.size !== originalSize) {
            sizeLabel = `${formatBytes(originalSize)} → ${formatBytes(
              compressed.size
            )}`;
          }
          file = compressed;
        } catch {
          setError("Failed to compress image.");
        }
      }

      if (file.type.startsWith("image/")) {
        if (file.size > 10 * 1024 * 1024) {
          setError("File too large. Images: max 10MB, Videos: max 50MB");
          continue;
        }
      }

      if (file.type.startsWith("video/")) {
        if (file.size > 50 * 1024 * 1024) {
          setError("File too large. Images: max 10MB, Videos: max 50MB");
          continue;
        }
        try {
          duration = await validateVideoDuration(file);
          if (duration > 60) {
            setError("Video must be under 60 seconds");
            continue;
          }
        } catch {
          setError("Video must be under 60 seconds");
          continue;
        }
      }

      const previewUrl = URL.createObjectURL(file);
      nextItems.push({
        id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
        fileId: rawId,
        file,
        type: file.type.startsWith("video/") ? "video" : "image",
        previewUrl,
        duration,
        sizeLabel,
      });
    }

    if (nextItems.length > 0) {
      setFiles((prev) => [...prev, ...nextItems]);
    }

    if (skippedDuplicates > 0) {
      setDuplicateSkipped(skippedDuplicates);
      setDuplicateToast(
        `Duplicate file skipped: ${lastDuplicateName || "file"}`
      );
      if (duplicateTimerRef.current) {
        clearTimeout(duplicateTimerRef.current);
      }
      duplicateTimerRef.current = setTimeout(() => {
        setDuplicateToast(null);
      }, 2000);
    } else {
      setDuplicateSkipped(0);
    }

    if (startedCompressing) {
      setCompressing(false);
      if (compressTimerRef.current) {
        clearTimeout(compressTimerRef.current);
      }
      compressTimerRef.current = setTimeout(() => {
        setCompressToast(null);
      }, 800);
    }
  };

  const handleSelectFile = async (selected: File[] | FileList | null) => {
    if (!selected) return;
    await processFiles(Array.from(selected));
    if (fileInputRef.current) {
      fileInputRef.current.value = "";
    }
  };

  const handleDrop = (event: React.DragEvent<HTMLDivElement>) => {
    event.preventDefault();
    setDragActive(false);
    const dropped = event.dataTransfer.files;
    if (dropped?.length) {
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
    if (files.length === 0 || !user || loading) return;
    if (isBanned) {
      setError("Your account has been suspended.");
      return;
    }
    setLoading(true);
    setError(null);
    setSuccess(null);
    setUploadingIndex(1);

    try {
      const uploaded: MediaItem[] = [];
      for (let i = 0; i < files.length; i += 1) {
        setUploadingIndex(i + 1);
        const result = await uploadMedia(files[i].file);
        uploaded.push(result);
      }
      const selectedPet = pets.find((petItem) => petItem.id === selectedPetId);
      const postPayload: Parameters<typeof createPost>[0] = {
        authorId: user.uid,
        authorName:
          profile?.displayName || user.displayName || "PetNote User",
        authorAvatar:
          profile?.avatarUrl ||
          user.photoURL ||
          "https://i.pravatar.cc/150?img=12",
        text: caption.trim(),
        media: uploaded,
        tags,
      };
      if (selectedPet) {
        postPayload.petId = selectedPet.id;
        postPayload.petName = selectedPet.name;
        postPayload.petAvatarUrl = selectedPet.avatarUrl || "";
      }
      await createPost({
        ...postPayload,
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
      setUploadingIndex(null);
    }
  };

  const handleRemove = (id: string) => {
    setFiles((prev) => {
      const target = prev.find((item) => item.id === id);
      if (target) {
        URL.revokeObjectURL(target.previewUrl);
      }
      return prev.filter((item) => item.id !== id);
    });
  };

  useEffect(() => {
    return () => {
      filesRef.current.forEach((item) =>
        URL.revokeObjectURL(item.previewUrl)
      );
      if (duplicateTimerRef.current) {
        clearTimeout(duplicateTimerRef.current);
      }
      if (compressTimerRef.current) {
        clearTimeout(compressTimerRef.current);
      }
    };
  }, []);

  const gridCols =
    files.length <= 1
      ? "grid-cols-1"
      : files.length === 2
      ? "grid-cols-2"
      : files.length === 3
      ? "grid-cols-3"
      : files.length === 4
      ? "grid-cols-2"
      : "grid-cols-3";

  const formatDuration = (value?: number) => {
    if (!value && value !== 0) return "";
    const minutes = Math.floor(value / 60);
    const seconds = Math.floor(value % 60);
    return `${minutes}:${seconds.toString().padStart(2, "0")}`;
  };

  const formatBytes = (value: number) => {
    if (value < 1024) return `${value} B`;
    const kb = value / 1024;
    if (kb < 1024) return `${kb.toFixed(1)} KB`;
    const mb = kb / 1024;
    return `${mb.toFixed(1)} MB`;
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
            disabled={loading || files.length === 0 || converting || isBanned}
            className="flex items-center gap-2 rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-1.5 text-sm font-semibold text-white shadow-md transition hover:brightness-110 disabled:cursor-not-allowed disabled:bg-slate-200 disabled:text-slate-400"
          >
            {loading ? (
              <>
                <span className="h-4 w-4 animate-spin rounded-full border-2 border-white/70 border-t-transparent" />
                {uploadingIndex
                  ? `Uploading ${uploadingIndex}/${files.length}...`
                  : "Posting..."}
              </>
            ) : (
              "Share"
            )}
          </button>
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-6 px-4 py-6">
        <section
          className={`relative flex min-h-[240px] flex-col rounded-2xl border-2 border-dashed bg-slate-50 text-center transition ${
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
          {files.length > 0 ? (
            <div className={`grid ${gridCols} auto-rows-fr gap-1 p-3`}>
              {files.map((item) => (
                <div
                  key={item.id}
                  className="relative aspect-square overflow-hidden rounded-lg border border-slate-200 bg-white"
                  onClick={(event) => event.stopPropagation()}
                >
                  {item.type === "video" ? (
                    <>
                      <video
                        src={item.previewUrl}
                        className="h-full w-full object-cover"
                        muted
                        playsInline
                        preload="metadata"
                      />
                      <div className="pointer-events-none absolute inset-0 flex items-center justify-center bg-black/20">
                        <span className="rounded-full bg-white/90 px-2 py-1 text-xs text-slate-700">
                          ▶
                        </span>
                      </div>
                      {item.duration ? (
                        <span className="absolute bottom-2 right-2 rounded-full bg-black/60 px-2 py-0.5 text-[10px] font-semibold text-white">
                          {formatDuration(item.duration)}
                        </span>
                      ) : null}
                    </>
                  ) : (
                    <img
                      src={item.previewUrl}
                      alt="Preview"
                      className="h-full w-full object-cover"
                    />
                  )}
                  {item.sizeLabel ? (
                    <span className="absolute bottom-2 left-2 rounded-full bg-white/80 px-2 py-0.5 text-[10px] font-semibold text-slate-600">
                      {item.sizeLabel}
                    </span>
                  ) : null}
                  <button
                    type="button"
                    onClick={(event) => {
                      event.stopPropagation();
                      handleRemove(item.id);
                    }}
                    className="absolute right-2 top-2 flex h-6 w-6 items-center justify-center rounded-full bg-white/80 text-xs text-slate-700 shadow transition hover:bg-white"
                    aria-label="Remove file"
                  >
                    ✕
                  </button>
                </div>
              ))}

              {files.length < 9 ? (
                <button
                  type="button"
                  onClick={(event) => {
                    event.stopPropagation();
                    fileInputRef.current?.click();
                  }}
                  className="flex aspect-square items-center justify-center rounded-lg border-2 border-dashed border-slate-300 bg-white/70 text-xl text-slate-400 transition-all duration-200 hover:border-purple-400 hover:text-purple-500"
                >
                  +
                </button>
              ) : null}
            </div>
          ) : (
            <div className="flex flex-1 flex-col items-center justify-center space-y-2 px-4">
              <div className="text-3xl">📷</div>
              <p className="text-sm font-semibold text-slate-700">
                {converting ? "Converting image..." : "Tap to add photo or video"}
              </p>
              <p className="text-xs text-slate-400">
                Drag & drop or click to upload
              </p>
            </div>
          )}

          {converting ? (
            <div className="pointer-events-none absolute inset-0 flex items-center justify-center bg-white/70 text-sm font-semibold text-slate-600">
              Converting image...
            </div>
          ) : null}

          <input
            ref={fileInputRef}
            type="file"
            multiple
            accept="image/jpeg,image/png,image/gif,image/webp,image/heic,image/heif,video/mp4,video/quicktime,video/webm"
            className="hidden"
            onChange={(event) => handleSelectFile(event.target.files)}
          />
        </section>

        {files.length > 0 ? (
          <p className="text-right text-xs text-slate-400">
            {files.length}/9 files
            {duplicateSkipped > 0
              ? ` · ${duplicateSkipped} duplicate(s) skipped`
              : ""}
          </p>
        ) : null}

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
          <div className="flex items-center justify-between">
            <label className="text-sm font-semibold text-slate-700">
              Tag a pet
            </label>
            <button
              type="button"
              onClick={() => navigate("/add-pet")}
              className="text-xs font-semibold text-purple-600"
            >
              Add pet
            </button>
          </div>
          {pets.length === 0 ? (
            <div className="rounded-2xl border border-dashed border-slate-200 bg-slate-50 p-4 text-center text-xs text-slate-500">
              Add your first pet to tag in posts.
            </div>
          ) : (
            <div className="flex gap-3 overflow-x-auto pb-2">
              {pets.map((petItem) => {
                const meta = getSpeciesMeta(petItem.species);
                const selected = selectedPetId === petItem.id;
                return (
                  <button
                    key={petItem.id}
                    type="button"
                    onClick={() =>
                      setSelectedPetId((prev) =>
                        prev === petItem.id ? null : petItem.id
                      )
                    }
                    className="flex flex-col items-center text-xs text-slate-600"
                  >
                    <div
                      className={`rounded-full bg-gradient-to-r ${meta.gradient} p-0.5 ${
                        selected ? "ring-2 ring-purple-400 ring-offset-2" : ""
                      }`}
                    >
                      {petItem.avatarUrl ? (
                        <img
                          src={petItem.avatarUrl}
                          alt={petItem.name}
                          className="h-12 w-12 rounded-full border-2 border-white object-cover"
                        />
                      ) : (
                        <div className="flex h-12 w-12 items-center justify-center rounded-full border-2 border-white bg-white text-lg">
                          {meta.emoji}
                        </div>
                      )}
                    </div>
                    <span className="mt-1 max-w-[64px] truncate">
                      {petItem.name}
                    </span>
                  </button>
                );
              })}
            </div>
          )}
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

      {duplicateToast ? (
        <div className="fixed bottom-6 left-1/2 z-50 -translate-x-1/2">
          <div className="rounded-full bg-amber-500 px-4 py-2 text-sm font-semibold text-white shadow-lg">
            {duplicateToast}
          </div>
        </div>
      ) : null}

      {compressToast || compressing ? (
        <div className="fixed bottom-16 left-1/2 z-50 -translate-x-1/2">
          <div className="rounded-full bg-slate-900/90 px-4 py-2 text-xs font-semibold text-white shadow-lg">
            {compressToast || "Compressing images..."}
          </div>
        </div>
      ) : null}
    </div>
  );
}
