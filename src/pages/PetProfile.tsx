import { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { deletePet, getPetById, getPostsByPet, type Pet } from "../services/pets";
import { getUserProfile } from "../services/users";
import { getGenderMeta, getSpeciesMeta } from "../utils/petHelpers";
import type { Post } from "../services/posts";
import { EmptyState } from "../components/EmptyState";

export function PetProfile() {
  const navigate = useNavigate();
  const { petId } = useParams();
  const { user } = useAuth();
  const [pet, setPet] = useState<Pet | null>(null);
  const [posts, setPosts] = useState<Post[]>([]);
  const [ownerName, setOwnerName] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [deleting, setDeleting] = useState(false);

  useEffect(() => {
    let ignore = false;
    if (!petId) return;

    const load = async () => {
      setLoading(true);
      const petData = await getPetById(petId);
      if (!petData) {
        if (!ignore) setLoading(false);
        return;
      }
      const [petPosts, ownerProfile] = await Promise.all([
        getPostsByPet(petId),
        getUserProfile(petData.ownerId),
      ]);
      if (!ignore) {
        setPet(petData);
        setPosts(petPosts);
        setOwnerName(ownerProfile?.displayName || "Owner");
        setLoading(false);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [petId]);

  const speciesMeta = useMemo(
    () => getSpeciesMeta(pet?.species),
    [pet?.species]
  );
  const genderMeta = useMemo(
    () => getGenderMeta(pet?.gender),
    [pet?.gender]
  );

  const birthdayLabel = useMemo(() => {
    if (!pet?.birthday) return null;
    const date =
      pet.birthday instanceof Date
        ? pet.birthday
        : typeof pet.birthday === "object" &&
          pet.birthday !== null &&
          "toDate" in pet.birthday &&
          typeof (pet.birthday as { toDate: () => Date }).toDate === "function"
        ? (pet.birthday as { toDate: () => Date }).toDate()
        : null;
    if (!date) return null;
    return `Born: ${date.toLocaleDateString(undefined, {
      year: "numeric",
      month: "short",
      day: "numeric",
    })}`;
  }, [pet?.birthday]);

  if (!petId) return null;

  if (loading) {
    return (
      <div className="min-h-screen bg-white pb-10 dark:bg-slate-900">
        <main className="mx-auto w-full max-w-md px-4 py-6">
          <div className="rounded-2xl bg-slate-50 p-6 text-center text-sm text-slate-500 dark:bg-slate-800 dark:text-slate-300">
            Loading pet profile...
          </div>
        </main>
      </div>
    );
  }

  if (!pet) {
    return (
      <div className="min-h-screen bg-white pb-10 dark:bg-slate-900">
        <main className="mx-auto w-full max-w-md px-4 py-6">
          <div className="rounded-2xl bg-slate-50 p-6 text-center text-sm text-slate-500 dark:bg-slate-800 dark:text-slate-300">
            Pet not found.
          </div>
        </main>
      </div>
    );
  }

  const isOwner = user?.uid === pet.ownerId;

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
            Pet Profile
          </h1>
          <div className="w-6" />
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-6 px-4 py-6">
        <section className="rounded-3xl bg-white p-6 text-center shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <div className={`mx-auto w-fit rounded-full bg-gradient-to-r ${speciesMeta.gradient} p-1`}>
            {pet.avatarUrl ? (
              <img
                src={pet.avatarUrl}
                alt={pet.name}
                className="h-24 w-24 rounded-full border-4 border-white object-cover dark:border-slate-800"
              />
            ) : (
              <div className="flex h-24 w-24 items-center justify-center rounded-full border-4 border-white bg-white text-4xl dark:border-slate-800 dark:bg-slate-900">
                {speciesMeta.emoji}
              </div>
            )}
          </div>
          <h2 className="mt-4 text-2xl font-semibold text-slate-900 dark:text-white">
            {pet.name}
          </h2>
          <p className="text-sm text-slate-500 dark:text-slate-300">
            {speciesMeta.emoji} {pet.breed || speciesMeta.label}
          </p>
          <div className="mt-2 flex items-center justify-center gap-2 text-xs text-slate-500 dark:text-slate-400">
            {pet.age ? <span>{pet.age}</span> : birthdayLabel ? <span>{birthdayLabel}</span> : null}
            <span style={{ color: genderMeta.color }}>
              {genderMeta.icon}
            </span>
          </div>
          {pet.bio ? (
            <p className="mt-3 text-sm text-slate-600 dark:text-slate-300">{pet.bio}</p>
          ) : null}

          <button
            type="button"
            onClick={() => navigate(`/profile/${pet.ownerId}`)}
            className="mt-3 text-xs text-slate-500 hover:text-purple-600 dark:text-slate-400"
          >
            Owner: {ownerName}
          </button>

          {isOwner ? (
            <div className="mt-4 flex items-center justify-center gap-3">
              <button
                type="button"
                onClick={() => navigate(`/edit-pet/${pet.id}`)}
                className="rounded-full border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-700 transition-all duration-200 hover:scale-105 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-200"
              >
                Edit Pet
              </button>
              <button
                type="button"
                onClick={() => setConfirmDelete(true)}
                className="rounded-full px-4 py-2 text-sm font-semibold text-red-500 transition-all duration-200 hover:scale-105 hover:bg-red-50"
              >
                Delete Pet
              </button>
            </div>
          ) : null}
        </section>

        <section className="rounded-2xl bg-white p-4 text-center shadow-sm ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <p className="text-lg font-semibold text-slate-900 dark:text-white">{posts.length}</p>
          <p className="text-xs text-slate-400 dark:text-slate-500">Posts</p>
        </section>

        <section className="space-y-3">
          <h3 className="text-base font-semibold text-slate-900 dark:text-white">
            Posts
          </h3>
          {posts.length === 0 ? (
            <EmptyState
              icon="🐾"
              title="No posts with this pet"
              description="Tag this pet when posting to show posts here"
            />
          ) : (
            <div className="grid grid-cols-3 gap-2">
              {posts.map((post) => {
                const mediaList =
                  post.media && post.media.length > 0
                    ? post.media
                    : post.mediaUrl
                    ? [{ url: post.mediaUrl, type: post.mediaType || "image" }]
                    : [];
                const first = mediaList[0];
                const isVideo = first?.type === "video";
                const isMulti = mediaList.length > 1;
                return (
                  <button
                    key={post.id}
                    type="button"
                    onClick={() => navigate(`/post/${post.id}`)}
                    className="relative aspect-square overflow-hidden rounded-2xl bg-slate-100 transition-all duration-200 hover:scale-[1.02] dark:bg-slate-800"
                  >
                    <img
                      src={first?.thumbUrl || first?.url || post.mediaUrl}
                      alt={post.text}
                      className="h-full w-full object-cover"
                    />
                    {isVideo ? (
                      <span className="absolute left-2 top-2 rounded bg-black/60 px-1.5 py-0.5 text-[10px] text-white">
                        ▶
                      </span>
                    ) : isMulti ? (
                      <span className="absolute left-2 top-2 rounded bg-black/60 px-1.5 py-0.5 text-[10px] text-white">
                        ⧉
                      </span>
                    ) : null}
                  </button>
                );
              })}
            </div>
          )}
        </section>
      </main>

      {confirmDelete ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-sm rounded-2xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)] dark:bg-slate-800">
            <h3 className="text-base font-semibold text-slate-900 dark:text-white">
              Delete Pet
            </h3>
            <p className="mt-2 text-sm text-slate-600 dark:text-slate-300">
              Are you sure you want to delete this pet? This action cannot be
              undone.
            </p>
            <div className="mt-5 flex items-center justify-end gap-3">
              <button
                type="button"
                onClick={() => setConfirmDelete(false)}
                className="rounded-full px-4 py-2 text-sm font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
              >
                Cancel
              </button>
              <button
                type="button"
                disabled={deleting}
                onClick={async () => {
                  if (deleting) return;
                  setDeleting(true);
                  await deletePet(pet.id);
                  navigate("/profile", { replace: true });
                }}
                className="rounded-full bg-red-500 px-4 py-2 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
              >
                {deleting ? "Deleting..." : "Delete"}
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
