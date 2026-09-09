import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { sendEmailVerification } from "firebase/auth";
import { useAuth } from "../hooks/useAuth";
import {
  deleteCloudinaryAssets,
  uploadMedia,
  type UploadedAsset,
} from "../services/cloudinary";
import {
  createPost,
  getPublishStatus,
  newOperationId,
  type MediaItem,
} from "../services/posts";
import { decideAssetReclaim } from "../utils/mediaReclaim";
import { getUserPets, type Pet } from "../services/pets";
import { getUserProfile, type UserProfile } from "../services/users";
import {
  compressImage,
  convertHeicToJpeg,
  isHeicImage,
} from "../utils/imageCompressor";
import { optimizeCloudinaryUrl } from "../utils/cloudinaryUrl";
import { getSpeciesMeta } from "../utils/petHelpers";
import { useToast } from "../contexts/ToastContext";
import { FILTER_MAP, ImageFilter, type FilterName } from "../components/ImageFilter";

const MAX_CHARS = 2000;

/**
 * Per-user draft key. The old key was a single global string, so two accounts
 * sharing a browser saw each other's unfinished post.
 */
const draftKeyFor = (uid: string) => `petnote_post_draft:${uid}`;

interface PostDraft {
  text: string;
  tags: string[];
  petId?: string;
  savedAt: number;
  /**
   * Stable id for this submission, kept in the draft so a retry — including
   * one after a reload — reuses it and the server recognises the operation
   * instead of publishing a second post.
   */
  operationId?: string;
  /**
   * Media that has already reached Cloudinary.
   *
   * The asset records, not the files: once an upload succeeds the bytes are on
   * the CDN, so a retry does not have to re-upload them and a reload can pick
   * the work back up. publicId is kept alongside the url because discarding
   * the draft is the one moment those assets become genuinely unreferenced and
   * safe to delete.
   *
   * Files that were selected but never uploaded cannot live here —
   * sessionStorage holds strings, not blobs — so those stay in memory only.
   * The banner says so rather than implying more than is true.
   */
  uploadedAssets?: UploadedAsset[];
  /**
   * True once this attempt's media reached the publish call.
   *
   * Durable on purpose. It used to be a local variable inside one submit, so
   * the catch could protect the assets but nothing else could: changing the
   * selection, discarding the draft, or coming back to an expired one all
   * deleted media that a committed post might already reference.
   */
  handedOff?: boolean;
}

/** Where a submission got to, for feedback that names the actual stage. */
type PublishPhase =
  | { kind: "idle" }
  | { kind: "preparing"; index: number; total: number }
  | { kind: "uploading"; index: number; total: number }
  | { kind: "publishing" }
  | { kind: "failed"; stage: "upload" | "publish" };

export function Create() {
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const { user, emailVerified, isBanned } = useAuth();
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
  const [phase, setPhase] = useState<PublishPhase>({ kind: "idle" });
  // Survives a failed attempt so a retry reuses the same operation id and the
  // media that already made it to Cloudinary.
  const operationIdRef = useRef<string | null>(null);
  const uploadedAssetsRef = useRef<UploadedAsset[]>([]);
  // Mirrors PostDraft.handedOff so the reclaim exits below can see it without
  // waiting for a draft round trip. `undefined` means "not recorded", which is
  // treated as handed off — a missing marker is not evidence of a safe delete.
  const handedOffRef = useRef<boolean | undefined>(false);

  /**
   * The one place that decides whether uploaded media may be deleted.
   *
   * Every exit goes through it: the policy is in utils/mediaReclaim.ts and it
   * refuses to delete anything whose publish outcome is not known to have
   * failed, checking with the server by operationId when it can.
   */
  const reclaimAssets = async (
    assets: UploadedAsset[],
    options: { handedOff: boolean | undefined; operationId: string | null }
  ) => {
    const decision = decideAssetReclaim({
      assets,
      handedOff: options.handedOff,
      operationId: options.operationId,
    });
    if (decision.reclaim) {
      await deleteCloudinaryAssets(decision.assets).catch(() => undefined);
    }
    return decision;
  };
  const [duplicateSkipped, setDuplicateSkipped] = useState(0);
  const [dragActive, setDragActive] = useState(false);
  const [profile, setProfile] = useState<UserProfile | null>(null);
  const filesRef = useRef(files);
  const navigateTimerRef = useRef<number | null>(null);
  // Stays true from a successful submit until the component unmounts on
  // navigate, so the post-success delay window can't accept a second submit
  // and create a duplicate post.
  const submitLockedRef = useRef(false);
  const [pets, setPets] = useState<Pet[]>([]);
  const [petsReady, setPetsReady] = useState(false);
  const [selectedPetId, setSelectedPetId] = useState<string | null>(null);
  const [draft, setDraft] = useState<PostDraft | null>(null);
  const [showDraftBanner, setShowDraftBanner] = useState(false);
  const [draftReady, setDraftReady] = useState(false);
  const [sendingVerification, setSendingVerification] = useState(false);
  const isEmailVerified = !!user && emailVerified;

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
      try {
        const [profileData, petList] = await Promise.all([
          getUserProfile(user.uid),
          getUserPets(user.uid),
        ]);
        if (!ignore) {
          setProfile(profileData);
          setPets(petList);
        }
      } finally {
        // Gate the "add a pet first" empty state on this flag so users who
        // DO have pets don't see it flash while the fetch is in flight.
        if (!ignore) setPetsReady(true);
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
    if (pets.length === 1) {
      setSelectedPetId((prev) => prev || pets[0].id);
    }
  }, [pets]);

  useEffect(() => {
    if (!user) return;
    try {
      const saved = sessionStorage.getItem(draftKeyFor(user.uid));
      if (saved) {
        const parsed: PostDraft = JSON.parse(saved);
        if (Date.now() - parsed.savedAt > 24 * 60 * 60 * 1000) {
          sessionStorage.removeItem(draftKeyFor(user.uid));
          // An abandoned attempt's uploads are usually unreferenced, but not
          // always: the attempt may have committed and lost its response. Ask
          // before deleting, and keep them if the answer is not "no post".
          if (parsed.uploadedAssets?.length) {
            void reclaimAssets(parsed.uploadedAssets, {
              handedOff: parsed.handedOff,
              operationId: parsed.operationId ?? null,
            });
          }
        } else {
          setDraft(parsed);
          setShowDraftBanner(true);
        }
      }
    } catch {
      // ignore
    } finally {
      setDraftReady(true);
    }
  }, [user]);

  useEffect(() => {
    filesRef.current = files;
  }, [files]);

  // A failed attempt's uploaded assets are matched to the file selection by
  // position, so changing the selection (or a filter, which changes the bytes)
  // invalidates them. Reclaim them and start a fresh operation rather than
  // publishing a post whose media is a mix of two different selections.
  const selectionSignature = useMemo(
    () => files.map((item) => `${item.id}:${filtersById[item.id] ?? ""}`).join("|"),
    [files, filtersById]
  );
  const selectionSignatureRef = useRef<string | null>(null);
  useEffect(() => {
    const previous = selectionSignatureRef.current;
    selectionSignatureRef.current = selectionSignature;
    if (previous === null || previous === selectionSignature) return;
    if (uploadedAssetsRef.current.length === 0) return;
    const stale = uploadedAssetsRef.current;
    const staleOperationId = operationIdRef.current;
    const staleHandedOff = handedOffRef.current;
    // The assets no longer line up with the selection either way, so this
    // attempt is over. Whether they can be *deleted* is a different question,
    // and the server answers it.
    uploadedAssetsRef.current = [];
    operationIdRef.current = null;
    handedOffRef.current = false;
    setPhase({ kind: "idle" });
    void reclaimAssets(stale, {
      handedOff: staleHandedOff,
      operationId: staleOperationId,
    }).then(async (decision) => {
      if (decision.reclaim || !staleOperationId) return;
      // The photos are kept either way. The lookup is only used to say
      // something true about what happened — it does not authorise deleting
      // anything, because "no post yet" is not "no post ever".
      const status = await getPublishStatus(staleOperationId).catch(() => null);
      if (status?.published) {
        showToast(
          "Your earlier post did go through — those photos are still in use.",
          "info"
        );
      }
    });
    // showToast comes from a memoized context value and reclaimAssets is
    // recreated every render by design (it closes over nothing that changes
    // the decision); the effect must fire only when the selection changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectionSignature]);

  useEffect(() => {
    if (!draftReady || showDraftBanner || !user) return;
    const key = draftKeyFor(user.uid);
    const timer = setTimeout(() => {
      const hasUploaded = uploadedAssetsRef.current.length > 0;
      if (caption.trim() || tags.length > 0 || selectedPetId || hasUploaded) {
        const payload: PostDraft = {
          text: caption,
          tags,
          petId: selectedPetId || undefined,
          savedAt: Date.now(),
          ...(operationIdRef.current
            ? { operationId: operationIdRef.current }
            : {}),
          ...(hasUploaded ? { uploadedAssets: uploadedAssetsRef.current } : {}),
          // Written explicitly when known, including when false — leaving the
          // field out would make a later read say "unrecorded". But an
          // *already* unrecorded state must stay unrecorded: writing false
          // there would upgrade "we don't know" into "safe to delete", which
          // is the exact inversion this policy exists to prevent.
          ...(handedOffRef.current === undefined
            ? {}
            : { handedOff: handedOffRef.current }),
        };
        sessionStorage.setItem(key, JSON.stringify(payload));
      } else {
        sessionStorage.removeItem(key);
      }
    }, 1000);
    return () => clearTimeout(timer);
  }, [caption, tags, selectedPetId, draftReady, showDraftBanner, user, phase]);

  const validateVideoDuration = (file: File) =>
    new Promise<number>((resolve, reject) => {
      const url = URL.createObjectURL(file);
      const video = document.createElement("video");
      let settled = false;
      let timeoutId = 0;
      const settle = (callback: () => void) => {
        if (settled) return;
        settled = true;
        window.clearTimeout(timeoutId);
        URL.revokeObjectURL(url);
        video.removeAttribute("src");
        video.load();
        callback();
      };
      video.preload = "metadata";
      video.onloadedmetadata = () => {
        const duration = video.duration;
        settle(() => resolve(duration));
      };
      video.onerror = () => {
        settle(() => reject(new Error("Failed to load video metadata")));
      };
      timeoutId = window.setTimeout(() => {
        settle(() => reject(new Error("Failed to load video metadata")));
      }, 10000);
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

      const isHeic = isHeicImage(rawFile);
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
          file = await convertHeicToJpeg(rawFile);
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
            "File too large. Images: max 10MB, Videos: max 80MB",
            "warning"
          );
          continue;
        }
      }

      if (file.type.startsWith("video/")) {
        if (file.size > 80 * 1024 * 1024) {
          showToast(
            "File too large. Images: max 10MB, Videos: max 80MB",
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
    // Mirror the server normalizeTags: lowercase, strip a leading '#', drop
    // empty / over-length tags, dedupe, and cap the total at 20.
    const incoming = value
      .split(/[,\s]+/)
      .map((tag) => tag.trim().toLowerCase().replace(/^#/, ""))
      .filter((tag) => tag.length > 0 && tag.length <= 40);

    if (incoming.length === 0) return;

    setTags((prev) => {
      const next = [...prev];
      incoming.forEach((tag) => {
        if (next.length >= 20) return;
        if (!next.includes(tag)) next.push(tag);
      });
      return next;
    });
  };

  const handleRestoreDraft = () => {
    if (!draft) return;
    const hasInput = caption.trim() || tags.length > 0 || selectedPetId;
    if (hasInput) {
      const confirmed = window.confirm(
        "Replace your current draft with the saved one?"
      );
      if (!confirmed) return;
    }
    setCaption(draft.text || "");
    setTags(draft.tags || []);
    setSelectedPetId(draft.petId || null);
    // Restore the failed attempt's identity and its already-uploaded media, so
    // resuming publishes the same post rather than a second one, and does not
    // re-upload bytes that are already on the CDN.
    operationIdRef.current = draft.operationId ?? null;
    uploadedAssetsRef.current = draft.uploadedAssets ?? [];
    // Absent means unrecorded, not false. Kept as undefined so the policy
    // errs towards keeping the media.
    handedOffRef.current = draft.handedOff;
    setShowDraftBanner(false);
    setDraft(null);
  };

  const handleDiscardDraft = () => {
    if (user) sessionStorage.removeItem(draftKeyFor(user.uid));
    // "I don't want this draft" is not the same as "no post exists". If the
    // attempt committed and lost its response, its images are in use and
    // deleting them here would break a real post.
    const orphans = draft?.uploadedAssets ?? uploadedAssetsRef.current;
    if (orphans.length > 0) {
      void reclaimAssets(orphans, {
        handedOff: draft ? draft.handedOff : handedOffRef.current,
        operationId: draft?.operationId ?? operationIdRef.current,
      });
    }
    operationIdRef.current = null;
    uploadedAssetsRef.current = [];
    handedOffRef.current = false;
    setShowDraftBanner(false);
    setDraft(null);
  };

  const handleTagKeyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      handleTagCommit(tagInput);
      setTagInput("");
    }
  };

  const handleShare = async () => {
    if (files.length === 0 || !user || loading || submitLockedRef.current) return;
    if (!isEmailVerified) {
      showToast("Please verify your email before posting", "warning");
      return;
    }
    if (!selectedPetId) {
      showToast("Please select a pet", "warning");
      return;
    }
    if (isBanned) {
      showToast("Your account has been suspended.", "error");
      return;
    }
    submitLockedRef.current = true;
    setLoading(true);

    // One id for this submission, reused by every retry of it. The server
    // derives the post's document id from it, so retrying after a lost
    // response returns the post the first attempt made instead of a second
    // one — which is what makes the failure path below safe.
    if (!operationIdRef.current) {
      operationIdRef.current = newOperationId();
    }
    const operationId = operationIdRef.current;

    // Anything a previous attempt already got onto Cloudinary. Re-uploading it
    // would waste the person's data and leak the old copies.
    const alreadyUploaded = uploadedAssetsRef.current;
    const remaining = files.slice(alreadyUploaded.length);
    setPhase({
      kind: "uploading",
      index: alreadyUploaded.length,
      total: files.length,
    });

    // True once the media has been handed to createPost. From that moment a
    // failure is ambiguous — the write may have committed and the response
    // been lost — so the assets must NOT be deleted. Same protection AddPlace
    // already had; the composer was destroying media it might still need.
    let handedOff = false;
    try {
      for (let i = 0; i < remaining.length; i += 1) {
        const current = remaining[i];
        const absoluteIndex = alreadyUploaded.length + i;
        let uploadFile = current.file;
        if (current.type === "image") {
          const filterName = filtersById[current.id] || "normal";
          const filterCss = FILTER_MAP[filterName] || "none";
          if (
            filterName !== "normal" &&
            current.sourceFile.type !== "image/gif"
          ) {
            // Filtering and re-compressing is CPU work on the main thread, and
            // on a phone it is the slowest part of a large photo. Naming it
            // separately stops the UI claiming "uploading" while nothing is
            // on the wire.
            setPhase({
              kind: "preparing",
              index: absoluteIndex + 1,
              total: files.length,
            });
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
        setPhase({
          kind: "uploading",
          index: absoluteIndex + 1,
          total: files.length,
        });
        const result = await uploadMedia(uploadFile);
        // Record each success as it lands, not at the end: a failure on file
        // three must not throw away files one and two.
        uploadedAssetsRef.current = [...uploadedAssetsRef.current, result];
      }

      const selectedPet = pets.find((petItem) => petItem.id === selectedPetId);
      if (!selectedPet) {
        throw new Error("Please select a valid pet.");
      }
      const media: MediaItem[] = uploadedAssetsRef.current.map((asset) => ({
        url: asset.url,
        type: asset.type,
        ...(asset.thumbUrl ? { thumbUrl: asset.thumbUrl } : {}),
      }));

      setPhase({ kind: "publishing" });
      handedOff = true;
      // Durable before the call, not after: if this attempt commits and the
      // response is lost, every later exit has to know the outcome is
      // uncertain — including one that happens after a reload.
      handedOffRef.current = true;
      try {
        sessionStorage.setItem(
          draftKeyFor(user.uid),
          JSON.stringify({
            text: caption,
            tags,
            petId: selectedPet.id,
            savedAt: Date.now(),
            operationId,
            uploadedAssets: uploadedAssetsRef.current,
            handedOff: true,
          } satisfies PostDraft)
        );
      } catch {
        // Storage full or blocked. The in-memory flag still guards this
        // session's exits; only a reload loses the protection.
      }
      const { deduplicated } = await createPost({
        authorId: user.uid,
        authorName:
          profile?.displayName || user.displayName || "PetNote User",
        authorAvatar:
          profile?.avatarUrl ||
          user.photoURL ||
          `https://api.dicebear.com/7.x/thumbs/svg?seed=${user.uid}`,
        text: caption.trim(),
        media,
        tags,
        petId: selectedPet.id,
        petName: selectedPet.name,
        petAvatarUrl: selectedPet.avatarUrl || "",
        operationId,
      });

      sessionStorage.removeItem(draftKeyFor(user.uid));
      operationIdRef.current = null;
      uploadedAssetsRef.current = [];
      handedOffRef.current = false;
      setPhase({ kind: "idle" });
      showToast(
        deduplicated
          ? "That post was already published."
          : "Posted successfully!",
        "success"
      );
      if (navigateTimerRef.current) {
        window.clearTimeout(navigateTimerRef.current);
      }
      navigateTimerRef.current = window.setTimeout(() => {
        navigateTimerRef.current = null;
        navigate("/", { replace: true });
      }, 600);
    } catch (err) {
      // Only clean up media that never reached the backend. Past the handoff
      // the write may have committed with the response lost, and deleting the
      // assets then leaves a real post pointing at dead URLs — irreversibly.
      // A rare orphan asset is the cheaper mistake, and pressing Share again
      // is safe because the operation id makes the publish idempotent.
      // Assets that did upload are deliberately kept, not deleted: the retry
      // resumes from them instead of making the person send the same photos
      // again. They are reclaimed when the draft is discarded or expires, and
      // when the file selection changes so they no longer line up.
      setPhase({ kind: "failed", stage: handedOff ? "publish" : "upload" });
      submitLockedRef.current = false;
      setLoading(false);
      const message =
        err instanceof Error ? err.message : "Failed to post. Try again.";
      showToast(
        handedOff
          ? `${message} Press Share again — it won't post twice.`
          : message,
        "error"
      );
    }
  };

  /**
   * What the button says while working.
   *
   * "Uploading 2/3" while the main thread is busy filtering and compressing a
   * photo was not just imprecise, it was the wrong thing to look at on a slow
   * phone: nothing was on the wire yet. Each stage now names itself.
   */
  const phaseLabel = useMemo(() => {
    switch (phase.kind) {
      case "preparing":
        return `Preparing ${phase.index}/${phase.total}...`;
      case "uploading":
        return `Uploading ${Math.max(1, phase.index)}/${phase.total}...`;
      case "publishing":
        return "Publishing...";
      default:
        return "Posting...";
    }
  }, [phase]);

  const handleResendVerification = async () => {
    if (!user || sendingVerification) return;
    setSendingVerification(true);
    try {
      await sendEmailVerification(user);
      showToast("Verification email sent!", "success");
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : "Failed to send verification email.";
      showToast(message, "error");
    } finally {
      setSendingVerification(false);
    }
  };

  const handleRemove = (id: string) => {
    // Compute the index and revoke the URL OUTSIDE the updaters: nesting a
    // dispatch (or revoking) inside setFiles is an impure updater that
    // StrictMode double-invokes, decrementing the selection twice in dev.
    const index = files.findIndex((item) => item.id === id);
    if (index === -1) return;
    URL.revokeObjectURL(files[index].previewUrl);
    setFiles((prev) => prev.filter((item) => item.id !== id));
    setSelectedIndex((current) => {
      if (current > index) return current - 1;
      if (current === index) return Math.max(0, current - 1);
      return current;
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
      if (navigateTimerRef.current) {
        window.clearTimeout(navigateTimerRef.current);
      }
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
    try {
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
      const nextName = file.name.replace(/\.\w+$/, ".jpg");
      return new File([blob], nextName, { type: "image/jpeg" });
    } finally {
      URL.revokeObjectURL(url);
    }
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
            disabled={
              loading ||
              files.length === 0 ||
              converting ||
              isBanned ||
              !selectedPetId ||
              !isEmailVerified
            }
            className="flex items-center gap-2 rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-1.5 text-sm font-semibold text-white shadow-md transition hover:brightness-110 disabled:cursor-not-allowed disabled:bg-slate-200 disabled:text-slate-400 dark:disabled:bg-slate-700 dark:disabled:text-slate-500"
          >
            {loading ? (
              <>
                <span className="h-4 w-4 animate-spin rounded-full border-2 border-white/70 border-t-transparent" />
                {phaseLabel}
              </>
            ) : phase.kind === "failed" ? (
              "Retry"
            ) : (
              "Share"
            )}
          </button>
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-6 px-4 py-6">
        {showDraftBanner && draft ? (
          <div className="flex items-center justify-between gap-3 rounded-2xl bg-blue-50 px-4 py-3 text-sm text-blue-700 shadow-sm dark:bg-blue-900/20 dark:text-blue-200">
            <div className="flex items-start gap-2">
              <span className="text-lg">📝</span>
              {/* Names what is actually in the draft. Photos are only in there
                  if a previous attempt already uploaded them; ones that were
                  only selected cannot be stored in sessionStorage, so
                  promising "your draft" without qualification would be a
                  promise the storage cannot keep. */}
              <span>
                {draft.uploadedAssets?.length
                  ? `Unsaved draft, with ${draft.uploadedAssets.length} photo${
                      draft.uploadedAssets.length === 1 ? "" : "s"
                    } already uploaded`
                  : "You have an unsaved draft (text, tags and pet — photos need picking again)"}
              </span>
            </div>
            <div className="flex items-center gap-2">
              <button
                type="button"
                onClick={handleRestoreDraft}
                className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-3 py-1 text-xs font-semibold text-white"
              >
                Restore
              </button>
              <button
                type="button"
                onClick={handleDiscardDraft}
                className="rounded-full bg-white px-3 py-1 text-xs font-semibold text-slate-600 shadow-sm transition hover:bg-slate-100 dark:bg-slate-800 dark:text-slate-300"
              >
                Discard
              </button>
            </div>
          </div>
        ) : null}
        {user && !isEmailVerified ? (
          <section className="space-y-3 rounded-2xl border border-amber-200 bg-amber-50 p-6 text-center dark:border-amber-500/30 dark:bg-amber-500/10">
            <p className="text-base font-semibold text-amber-800 dark:text-amber-200">
              Please verify your email before posting
            </p>
            <p className="text-sm text-amber-700/90 dark:text-amber-300/90">
              Check your inbox for a verification link from PetNote.
            </p>
            <button
              type="button"
              onClick={handleResendVerification}
              disabled={sendingVerification}
              className="mx-auto rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:opacity-70"
            >
              {sendingVerification ? "Sending..." : "Resend Verification Email"}
            </button>
          </section>
        ) : !petsReady ? (
          <section className="space-y-3 rounded-2xl border border-dashed border-slate-200 bg-slate-50 p-6 dark:border-slate-700 dark:bg-slate-800">
            <div className="h-5 w-2/3 animate-pulse rounded bg-slate-200 dark:bg-slate-700" />
            <div className="h-4 w-1/2 animate-pulse rounded bg-slate-200 dark:bg-slate-700" />
          </section>
        ) : pets.length === 0 ? (
          <section className="space-y-3 rounded-2xl border border-dashed border-slate-300 bg-slate-50 p-6 text-center dark:border-slate-700 dark:bg-slate-800">
            <h2 className="text-base font-semibold text-slate-900 dark:text-white">
              You need to add a pet before posting
            </h2>
            <p className="text-sm text-slate-500 dark:text-slate-300">
              Add your pet profile first — we&apos;ll bring you straight back
              here.
            </p>
            <button
              type="button"
              // Carry the destination so adding a pet returns to the composer
              // instead of the new pet's page. This is the "ask for a pet when
              // publishing needs one" half of shortening onboarding: it only
              // works if the detour comes back.
              onClick={() =>
                navigate("/add-pet", { state: { from: "/create" } })
              }
              className="mx-auto rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white"
            >
              Add Pet
            </button>
          </section>
        ) : (
        <>
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
              Which pet is this about? *
            </label>
            <button
              type="button"
              onClick={() => navigate("/add-pet")}
              className="text-xs font-semibold text-purple-600"
            >
              Add pet
            </button>
          </div>
          <div className="flex gap-3 overflow-x-auto py-2">
            {pets.map((petItem) => {
              const meta = getSpeciesMeta(petItem.species);
              const selected = selectedPetId === petItem.id;
              return (
                <button
                  key={petItem.id}
                  type="button"
                  onClick={() => setSelectedPetId(petItem.id)}
                  className="flex flex-col items-center text-xs text-slate-600 dark:text-slate-300"
                >
                  {petItem.avatarUrl ? (
                    <img
                      src={optimizeCloudinaryUrl(petItem.avatarUrl, "avatar")}
                      alt={petItem.name}
                      className={`h-12 w-12 rounded-full object-cover transition-all duration-200 ${
                        selected
                          ? "border-2 border-purple-500"
                          : "border-2 border-transparent"
                      }`}
                    />
                  ) : (
                    <div
                      className={`flex h-12 w-12 items-center justify-center rounded-full bg-white text-lg transition-all duration-200 dark:bg-slate-900 ${
                        selected
                          ? "border-2 border-purple-500"
                          : "border-2 border-transparent"
                      }`}
                    >
                      {meta.emoji}
                    </div>
                  )}
                  <span className="mt-1 max-w-[64px] truncate">
                    {petItem.name}
                  </span>
                </button>
              );
            })}
          </div>
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
        </>
        )}
      </main>
    </div>
  );
}
