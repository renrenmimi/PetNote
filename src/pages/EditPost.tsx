import { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { MediaCarousel } from "../components/MediaCarousel";
import { getPetsByOwner, type Pet } from "../services/pets";
import { getPostById, updatePost, type Post } from "../services/posts";
import { getSpeciesMeta } from "../utils/petHelpers";

const MAX_CHARS = 500;

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
  const [error, setError] = useState<string | null>(null);

  const remaining = useMemo(
    () => Math.max(0, MAX_CHARS - caption.length),
    [caption]
  );

  useEffect(() => {
    let ignore = false;
    if (!postId || !user) return;
    const load = async () => {
      setLoading(true);
      const [postData, petList] = await Promise.all([
        getPostById(postId),
        getPetsByOwner(user.uid),
      ]);
      if (ignore) return;
      if (!postData) {
        setLoading(false);
        return;
      }
      setPost(postData);
      setCaption(postData.text || "");
      setTags(postData.tags || []);
      setSelectedPetId(postData.petId || null);
      setPets(petList);
      setLoading(false);
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [postId, user]);

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

  const handleSave = async () => {
    if (!post || !user || saving) return;
    if (post.authorId !== user.uid) {
      setError("You can only edit your own posts.");
      return;
    }
    setSaving(true);
    setError(null);
    try {
      const selectedPet = pets.find((petItem) => petItem.id === selectedPetId);
      await updatePost(post.id, {
        text: caption.trim(),
        tags,
        petId: selectedPet ? selectedPet.id : null,
        petName: selectedPet?.name,
        petAvatarUrl: selectedPet?.avatarUrl,
      });
      navigate(`/post/${post.id}`, { replace: true });
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to update post.";
      setError(message);
    } finally {
      setSaving(false);
    }
  };

  if (!user) return null;

  if (loading) {
    return (
      <div className="min-h-screen bg-white pb-10">
        <main className="mx-auto w-full max-w-md px-4 py-6">
          <div className="rounded-2xl bg-slate-50 p-6 text-center text-sm text-slate-500">
            Loading post...
          </div>
        </main>
      </div>
    );
  }

  if (!post) {
    return (
      <div className="min-h-screen bg-white pb-10">
        <main className="mx-auto w-full max-w-md px-4 py-6">
          <div className="rounded-2xl bg-slate-50 p-6 text-center text-sm text-slate-500">
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
          <h1 className="text-base font-semibold text-slate-900">Edit Post</h1>
          <button
            type="button"
            onClick={handleSave}
            disabled={saving}
            className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-1.5 text-sm font-semibold text-white shadow-md transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
          >
            {saving ? "Saving..." : "Save"}
          </button>
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-6 px-4 py-6">
        <section className="relative overflow-hidden rounded-2xl border border-slate-200 bg-slate-50/70">
          <MediaCarousel media={mediaItems} />
          <div className="absolute inset-0 flex items-center justify-center bg-white/60 text-xs font-semibold text-slate-600">
            Media cannot be changed after posting
          </div>
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

        {error ? (
          <div className="rounded-2xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-600">
            {error}
          </div>
        ) : null}
      </main>
    </div>
  );
}
