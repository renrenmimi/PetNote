import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { uploadMedia } from "../services/cloudinary";
import { createPost, type MediaItem } from "../services/posts";
import { getPetsByOwner, type Pet } from "../services/pets";
import { getUserProfile, type UserProfile } from "../services/users";
import { compressImage } from "../utils/imageCompressor";
import { getSpeciesMeta } from "../utils/petHelpers";
import { useToast } from "../contexts/ToastContext";
import { FILTER_MAP, ImageFilter, type FilterName } from "../components/ImageFilter";

const MAX_CHARS = 2000;

export function Create() {
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const { user, isBanned } = useAuth();
  const { showToast } = useToast();
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [files, setFiles] = useState<
    Array<{
      id: string;
      fileId: string;
      file: File;
      sourceFile: File;
      type: "image" | "video";
      previewUrl: string;
      duration?: number;
      sizeLabel?: string;
    }>
  >([]);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [filtersById, setFiltersById] = useState<Record<string, FilterName>>(
    {}
  );
  const [caption, setCaption] = useState("");
  const [tags, setTags] = useState<string[]>([]);
  const [tagInput, setTagInput] = useState("");
  const [loading, setLoading] = useState(false);
  const [converting, setConverting] = useState(false);
  const [uploadingIndex, setUploadingIndex] = useState<number | null>(null);
  const [duplicateSkipped, setDuplicateSkipped] = useState(0);
  const [dragActive, setDragActive] = useState(false);
  const [profile, setProfile] = useState<UserProfile | null>(null);
  const filesRef = useRef(files);
  const [pets, setPets] = useState<Pet[]>([]);
  const [selectedPetId, setSelectedPetId] = useState<string | null>(null);

  const remaining = useMemo(() => MAX_CHARS - caption.length, [caption]);
  const counterTone =
    remaining <= 0
      ? "text-red-500"
      : remaining <= Math.ceil(MAX_CHARS * 0.2)
      ? "text-amber-500"
      : "text-slate-400 dark:text-slate-500";

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
    const petId = searchParams.get("petId");
    if (!petId || pets.length === 0) return;
    const exists = pets.some((pet) => pet.id === petId);
    if (exists) {
      setSelectedPetId(petId);
    }
  }, [pets, searchParams]);

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
    const currentFiles = filesRef.current;
    const availableSlots = 9 - currentFiles.length;
    if (incoming.length > availableSlots) {
      showToast("Maximum 9 files allowed", "warning");
    }
    const slice = incoming.slice(0, availableSlots);
    const nextItems: typeof files = [];
    const existingIds = new Set(currentFiles.map((item) => item.fileId));
    const seenIds = new Set(existingIds);
    let skippedDuplicates = 0;
    let lastDuplicateName = "";
    let startedCompressing = false;

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
        showToast("Unsupported file format", "warning");
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
          showToast("Failed to convert image.", "error");
          continue;
        } finally {
          setConverting(false);
        }
      }

      const sourceFile = file;

      if (file.type.startsWith("image/") && file.type !== "image/gif") {
        try {
          if (!startedCompressing) {
            startedCompressing = true;
            showToast("Compressing images...", "info");
          }
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
          showToast("Failed to compress image.", "error");
        }
      }

      if (file.type.startsWith("image/")) {
        if (file.size > 10 * 1024 * 1024) {
          showToast(
            "File too large. Images: max 10MB, Videos: max 50MB",
            "warning"
          );
          continue;
        }
      }

      if (file.type.startsWith("video/")) {
        if (file.size > 50 * 1024 * 1024) {
          showToast(
            "File too large. Images: max 10MB, Videos: max 50MB",
            "warning"
          );
          continue;
        }
        try {
          duration = await validateVideoDuration(file);
          if (duration > 60) {
            showToast("Video must be under 60 seconds", "warning");
            continue;
          }
        } catch {
          showToast("Video must be under 60 seconds", "warning");
          continue;
        }
      }

      const previewUrl = URL.createObjectURL(file);
      nextItems.push({
        id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
        fileId: rawId,
        file,
        sourceFile,
        type: file.type.startsWith("video/") ? "video" : "image",
        previewUrl,
        duration,
        sizeLabel,
      });
    }

    if (nextItems.length > 0) {
      setFiles((prev) => [...prev, ...nextItems]);
      setFiltersById((prev) => {
        const next = { ...prev };
        nextItems.forEach((item) => {
          next[item.id] = "normal";
        });
        return next;
      });
    }

    if (skippedDuplicates > 0) {
      setDuplicateSkipped(skippedDuplicates);
      showToast(
        `Duplicate file skipped: ${lastDuplicateName || "file"}`,
        "warning"
      );
    } else {
      setDuplicateSkipped(0);
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
        const trimmed = tag.slice(0, 30);
        if (trimmed && !next.includes(trimmed)) {
          next.push(trimmed);
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
      showToast("Your account has been suspended.", "error");
      return;
    }
    setLoading(true);
    setUploadingIndex(1);

    try {
      const uploaded: MediaItem[] = [];
      for (let i = 0; i < files.length; i += 1) {
        setUploadingIndex(i + 1);
        const current = files[i];
        let uploadFile = current.file;
        if (current.type === "image") {
          const filterName = filtersById[current.id] || "normal";
          const filterCss = FILTER_MAP[filterName] || "none";
          if (
            filterName !== "normal" &&
            current.sourceFile.type !== "image/gif"
          ) {
            uploadFile = await applyFilter(current.sourceFile, filterCss);
            uploadFile = await compressImage(uploadFile, {
              maxWidth: 1920,
              maxHeight: 1920,
              quality: 0.8,
              maxSizeMB: 2,
            });
          } else if (current.file.type.startsWith("image/")) {
            uploadFile = current.file;
          }
        }
        const result = await uploadMedia(uploadFile);
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
          `https://api.dicebear.com/7.x/thumbs/svg?seed=${user.uid}`,
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
      showToast("Posted successfully!", "success");
      setTimeout(() => {
        navigate("/", { replace: true });
      }, 600);
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to post. Try again.";
      showToast(message, "error");
    } finally {
      setLoading(false);
      setUploadingIndex(null);
    }
  };

  const handleRemove = (id: string) => {
    setFiles((prev) => {
      const index = prev.findIndex((item) => item.id === id);
      const target = prev[index];
      if (target) {
        URL.revokeObjectURL(target.previewUrl);
      }
      const next = prev.filter((item) => item.id !== id);
      setSelectedIndex((current) => {
        if (index === -1) return current;
        if (current > index) return current - 1;
        if (current === index) return Math.max(0, current - 1);
        return current;
      });
      return next;
    });
    setFiltersById((prev) => {
      const next = { ...prev };
      delete next[id];
      return next;
    });
  };

  useEffect(() => {
    return () => {
      filesRef.current.forEach((item) =>
        URL.revokeObjectURL(item.previewUrl)
      );
    };
  }, []);

  useEffect(() => {
    if (selectedIndex >= files.length && files.length > 0) {
      setSelectedIndex(files.length - 1);
    }
    if (files.length === 0) {
      setSelectedIndex(0);
    }
  }, [files.length, selectedIndex]);

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

  const selectedItem = files[selectedIndex];
  const selectedFilter =
    selectedItem && selectedItem.type === "image"
      ? filtersById[selectedItem.id] || "normal"
      : "normal";

  const applyFilter = async (file: File, filterCSS: string): Promise<File> => {
    if (filterCSS === "none") return file;
    const img = new Image();
    const url = URL.createObjectURL(file);
    await new Promise<void>((resolve, reject) => {
      img.onload = () => resolve();
      img.onerror = () => reject(new Error("Failed to load image"));
      img.src = url;
    });

    const canvas = document.createElement("canvas");
    canvas.width = img.width;
    canvas.height = img.height;
    const ctx = canvas.getContext("2d");
    if (!ctx) {
      URL.revokeObjectURL(url);
      return file;
    }
    ctx.filter = filterCSS;
    ctx.drawImage(img, 0, 0);

    const blob = await new Promise<Blob>((resolve, reject) => {
      canvas.toBlob(
        (result) => {
          if (result) resolve(result);
          else reject(new Error("Failed to apply filter"));
        },
        "image/jpeg",
        0.9
      );
    });
    URL.revokeObjectURL(url);
    const nextName = file.name.replace(/\.\w+$/, ".jpg");
    return new File([blob], nextName, { type: "image/jpeg" });
  };

  return (
    <div className="min-h-screen bg-white pb-10 dark:bg-slate-900">
      <header className="sticky top-0 z-10 border-b border-slate-200 bg-white dark:border-slate-800 dark:bg-slate-900">
        <div className="mx-auto flex w-full max-w-md items-center justify-between px-4 py-3">
          <button
            type="button"
            onClick={() => navigate(-1)}
            className="text-xl text-slate-500 hover:text-slate-700 dark:text-slate-300"
            aria-label="Go back"
          >
            ←
          </button>
          <h1 className="text-base font-semibold text-slate-900 dark:text-white">
            New Post
          </h1>
          <button
            type="button"
            onClick={handleShare}
            disabled={loading || files.length === 0 || converting || isBanned}
            className="flex items-center gap-2 rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-1.5 text-sm font-semibold text-white shadow-md transition hover:brightness-110 disabled:cursor-not-allowed disabled:bg-slate-200 disabled:text-slate-400 dark:disabled:bg-slate-700 dark:disabled:text-slate-500"
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
          className={`relative flex min-h-[240px] flex-col rounded-2xl border-2 border-dashed bg-slate-50 text-center transition dark:bg-slate-800 ${
            dragActive
              ? "border-purple-400 bg-purple-50 dark:bg-purple-500/10"
              : "border-slate-200 hover:border-purple-300 dark:border-slate-700 dark:hover:border-purple-400"
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
              {files.map((item, index) => {
                const filterCss = FILTER_MAP[filtersById[item.id] || "normal"];
                const isSelected = index === selectedIndex;
                return (
                <div
                  key={item.id}
                  className={`relative aspect-square overflow-hidden rounded-lg border bg-white dark:bg-slate-900 ${
                    isSelected
                      ? "border-purple-400 ring-2 ring-purple-300"
                      : "border-slate-200 dark:border-slate-700"
                  }`}
                  onClick={(event) => {
                    event.stopPropagation();
                    setSelectedIndex(index);
                  }}
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
                        <span className="rounded-full bg-white/90 px-2 py-1 text-xs text-slate-700 dark:bg-slate-800/90 dark:text-slate-200">
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
                      style={{ filter: filterCss }}
                    />
                  )}
                  {item.sizeLabel ? (
                    <span className="absolute bottom-2 left-2 rounded-full bg-white/80 px-2 py-0.5 text-[10px] font-semibold text-slate-600 dark:bg-slate-800/90 dark:text-slate-200">
                      {item.sizeLabel}
                    </span>
                  ) : null}
                  <button
                    type="button"
                    onClick={(event) => {
                      event.stopPropagation();
                      handleRemove(item.id);
                    }}
                    className="absolute right-2 top-2 flex h-6 w-6 items-center justify-center rounded-full bg-white/80 text-xs text-slate-700 shadow transition hover:bg-white dark:bg-slate-800/90 dark:text-slate-200"
                    aria-label="Remove file"
                  >
                    ✕
                  </button>
                </div>
              )})}

              {files.length < 9 ? (
                <button
                  type="button"
                  onClick={(event) => {
                    event.stopPropagation();
                    fileInputRef.current?.click();
                  }}
                  className="flex aspect-square items-center justify-center rounded-lg border-2 border-dashed border-slate-300 bg-white/70 text-xl text-slate-400 transition-all duration-200 hover:border-purple-400 hover:text-purple-500 dark:border-slate-600 dark:bg-slate-900/60 dark:text-slate-500"
                >
                  +
                </button>
              ) : null}
            </div>
          ) : (
            <div className="flex flex-1 flex-col items-center justify-center space-y-2 px-4">
              <div className="text-3xl">📷</div>
              <p className="text-sm font-semibold text-slate-700 dark:text-slate-200">
                {converting ? "Converting image..." : "Tap to add photo or video"}
              </p>
              <p className="text-xs text-slate-400 dark:text-slate-500">
                Drag & drop or click to upload
              </p>
            </div>
          )}

          {converting ? (
            <div className="pointer-events-none absolute inset-0 flex items-center justify-center bg-white/70 text-sm font-semibold text-slate-600 dark:bg-slate-900/70 dark:text-slate-200">
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
          <p className="text-right text-xs text-slate-400 dark:text-slate-500">
            {files.length}/9 files
            {duplicateSkipped > 0
              ? ` · ${duplicateSkipped} duplicate(s) skipped`
              : ""}
          </p>
        ) : null}

        {selectedItem && selectedItem.type === "image" ? (
          <ImageFilter
            previewUrl={selectedItem.previewUrl}
            selected={selectedFilter}
            onSelect={(filter) =>
              setFiltersById((prev) => ({
                ...prev,
                [selectedItem.id]: filter,
              }))
            }
          />
        ) : null}

        <section className="space-y-2">
          <div className="flex items-center justify-between">
            <label className="text-sm font-semibold text-slate-700 dark:text-slate-200">
              Caption
            </label>
            <span className={`text-xs ${counterTone}`}>
              {caption.length}/{MAX_CHARS}
            </span>
          </div>
          <textarea
            placeholder="Write a caption..."
            maxLength={MAX_CHARS}
            rows={4}
            className="w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
            value={caption}
            onChange={(event) => setCaption(event.target.value)}
          />
        </section>

        <section className="space-y-2">
          <div className="flex items-center justify-between">
            <label className="text-sm font-semibold text-slate-700 dark:text-slate-200">
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
            <div className="rounded-2xl border border-dashed border-slate-200 bg-slate-50 p-4 text-center text-xs text-slate-500 dark:border-slate-700 dark:bg-slate-800 dark:text-slate-300">
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
                    className="flex flex-col items-center text-xs text-slate-600 dark:text-slate-300"
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
                          className="h-12 w-12 rounded-full border-2 border-white object-cover dark:border-slate-800"
                        />
                      ) : (
                        <div className="flex h-12 w-12 items-center justify-center rounded-full border-2 border-white bg-white text-lg dark:border-slate-800 dark:bg-slate-900">
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
          <label className="text-sm font-semibold text-slate-700 dark:text-slate-200">
            Tags
          </label>
          <input
            type="text"
            placeholder="Add tags (e.g. cat, cute)"
            className="w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
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
                  className="flex items-center gap-1 rounded-full bg-purple-50 px-3 py-1 text-xs font-semibold text-purple-600 dark:bg-purple-500/10 dark:text-purple-300"
                >
                  #{tag}
                  <button
                    type="button"
                    onClick={() =>
                      setTags((prev) => prev.filter((item) => item !== tag))
                    }
                    className="text-purple-400 hover:text-purple-600 dark:text-purple-300"
                    aria-label={`Remove ${tag}`}
                  >
                    ✕
                  </button>
                </span>
              ))}
            </div>
          ) : null}
        </section>

      </main>
    </div>
  );
}
