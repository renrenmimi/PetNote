import { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { MediaCarousel } from "../components/MediaCarousel";
import { getUserPets, type Pet } from "../services/pets";
import { getPostById, updatePost, type Post } from "../services/posts";
import { optimizeCloudinaryUrl } from "../utils/cloudinaryUrl";
import { getSpeciesMeta } from "../utils/petHelpers";
import { useToast } from "../contexts/ToastContext";

const MAX_CHARS = 2000;

export function EditPost() {
  const navigate = useNavigate();
  const { postId } = useParams();
  const { user } = useAuth();
  const [post, setPost] = useState<Post | null>(null);
  const [pets, setPets] = useState<Pet[]>([]);
  const [selectedPetId, setSelectedPetId] = useState<string | null>(null);
  const [caption, setCaption] = useState("");
  const [tags, setTags] = useState<string[]>([]);
  const [tagInput, setTagInput] = useState("");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const { showToast } = useToast();

  const remaining = useMemo(() => MAX_CHARS - caption.length, [caption]);
  const counterTone =
    remaining <= 0
      ? "text-red-500"
      : remaining <= Math.ceil(MAX_CHARS * 0.2)
      ? "text-amber-500"
      : "text-slate-400 dark:text-slate-500";

  useEffect(() => {
    let ignore = false;
    if (!postId || !user) return;
    const load = async () => {
      setLoading(true);
      try {
        const [postData, petList] = await Promise.all([
          getPostById(postId),
          getUserPets(user.uid),
        ]);
        if (ignore || !postData) return;
        setPost(postData);
        setCaption(postData.text || "");
        setTags(postData.tags || []);
        setSelectedPetId(postData.petId || null);
        setPets(petList);
      } catch (err) {
        // Without this catch a network/permission failure left the page on
        // "Loading post..." forever (same fix as PostDetail/PetProfile).
        if (!ignore) {
          showToast(
            err instanceof Error ? err.message : "Failed to load post.",
            "error"
          );
        }
      } finally {
        if (!ignore) setLoading(false);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
    // showToast comes from a stable context value; the effect should
    // re-run only when postId or user change.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [postId, user]);

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

  const handleTagKeyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      handleTagCommit(tagInput);
      setTagInput("");
    }
  };

  const handleSave = async () => {
    if (!post || !user || saving) return;
    if (post.authorId !== user.uid) {
      showToast("You can only edit your own posts.", "error");
      return;
    }
    const selectedPet = pets.find((petItem) => petItem.id === selectedPetId);
    if (!selectedPet) {
      // Posts must stay linked to a pet (the backend rejects petId:null too).
      showToast("Posts must be linked to a pet.", "warning");
      return;
    }
    setSaving(true);
    try {
      await updatePost(post.id, {
        text: caption.trim(),
        tags,
        petId: selectedPet.id,
        petName: selectedPet.name,
        petAvatarUrl: selectedPet.avatarUrl,
      });
      navigate(`/post/${post.id}`, { replace: true });
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to update post.";
      showToast(message, "error");
    } finally {
      setSaving(false);
    }
  };

  if (!user) return null;

  if (loading) {
    return (
      <div className="min-h-screen bg-white pb-10 dark:bg-slate-900">
        <main className="mx-auto w-full max-w-md px-4 py-6">
          <div className="rounded-2xl bg-slate-50 p-6 text-center text-sm text-slate-500 dark:bg-slate-800 dark:text-slate-300">
            Loading post...
          </div>
        </main>
      </div>
    );
  }

  if (!post) {
    return (
      <div className="min-h-screen bg-white pb-10 dark:bg-slate-900">
        <main className="mx-auto w-full max-w-md px-4 py-6">
          <div className="rounded-2xl bg-slate-50 p-6 text-center text-sm text-slate-500 dark:bg-slate-800 dark:text-slate-300">
            Post not found.
          </div>
        </main>
      </div>
    );
  }

  const mediaItems =
    post.media && post.media.length > 0
      ? post.media
      : post.mediaUrl
      ? [{ url: post.mediaUrl, type: post.mediaType || "image" }]
      : [];

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
            Edit Post
          </h1>
          <button
            type="button"
            onClick={handleSave}
            disabled={saving || !selectedPetId}
            className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-1.5 text-sm font-semibold text-white shadow-md transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
          >
            {saving ? "Saving..." : "Save"}
          </button>
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-6 px-4 py-6">
        <section className="relative overflow-hidden rounded-2xl border border-slate-200 bg-slate-50/70 dark:border-slate-700 dark:bg-slate-800">
          <MediaCarousel media={mediaItems} />
          <div className="absolute inset-0 flex items-center justify-center bg-white/60 text-xs font-semibold text-slate-600 dark:bg-slate-900/60 dark:text-slate-200">
            Media cannot be changed after posting
          </div>
        </section>

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
                    onClick={() => setSelectedPetId(petItem.id)}
                    className="flex flex-col items-center text-xs text-slate-600 dark:text-slate-300"
                  >
                    <div
                      className={`rounded-full bg-gradient-to-r ${meta.gradient} p-0.5 ${
                        selected ? "ring-2 ring-purple-400 ring-offset-2" : ""
                      }`}
                    >
                      {petItem.avatarUrl ? (
                        <img
                          src={optimizeCloudinaryUrl(petItem.avatarUrl, "avatar")}
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
