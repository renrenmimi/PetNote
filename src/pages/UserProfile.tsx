import { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import Avatar from "../components/Avatar";
import { useAuth } from "../hooks/useAuth";
import { useBlockedUsers } from "../hooks/useBlockedUsers";
import { batchCheckFollowingPets } from "../hooks/useBatchFollowingPets";
import { unblockUser } from "../services/block";
import { useFollowPet } from "../hooks/useFollow";
import { getFollowingPets, type FollowingPet } from "../services/follow";
import {
  getRelationshipLabel,
  getUserPets,
  type Pet,
} from "../services/pets";
import { getUserProfile, type UserProfile } from "../services/users";
import { getSpeciesMeta } from "../utils/petHelpers";
import { useToast } from "../contexts/ToastContext";

// initialFollowing skips the per-card checkIfFollowingPet getDoc inside
// useFollowPet, so the parent's batched lookup becomes the single source
// of truth. Disabling fetchFollowerCount drops another per-pet getDoc
// since this card doesn't render the follower number.
function PetFollowButton({
  petId,
  initialFollowing,
}: {
  petId: string;
  initialFollowing?: boolean;
}) {
  const { user } = useAuth();
  const { isFollowing, toggleFollow, loading } = useFollowPet(petId, {
    initialFollowing,
    fetchFollowerCount: false,
  });
  if (!user) return null;

  return (
    <button
      type="button"
      onClick={toggleFollow}
      disabled={loading}
      className={`rounded-full px-4 py-1.5 text-xs font-semibold transition-all duration-200 hover:scale-105 ${
        isFollowing
          ? "border border-slate-200 text-slate-500 dark:border-slate-700 dark:text-slate-300"
          : "bg-gradient-to-r from-purple-500 to-pink-500 text-white shadow-[0_10px_25px_-15px_rgba(168,85,247,0.7)]"
      }`}
    >
      {isFollowing ? "Following" : "Follow"}
    </button>
  );
}

export function UserProfile() {
  const navigate = useNavigate();
  const { userId } = useParams();
  const { user } = useAuth();
  const { showToast } = useToast();
  const { isBlocked } = useBlockedUsers(user?.uid ?? null);

  const [profile, setProfile] = useState<UserProfile | null>(null);
  const [pets, setPets] = useState<Pet[]>([]);
  const [followingPets, setFollowingPets] = useState<FollowingPet[]>([]);
  const [followedPetIds, setFollowedPetIds] = useState<Set<string>>(new Set());
  const [loading, setLoading] = useState(true);
  const [followingModalOpen, setFollowingModalOpen] = useState(false);

  useEffect(() => {
    let ignore = false;
    if (!userId) return;
    // Clear the previous profile's data immediately so navigating
    // /profile/a → /profile/b never shows A's name/avatar/pets under B's URL
    // while B's fetch is in flight.
    setProfile(null);
    setPets([]);
    setFollowingPets([]);

    const load = async () => {
      setLoading(true);
      try {
        const [profileData, petList, followingResult] = await Promise.all([
          getUserProfile(userId),
          getUserPets(userId),
          user?.uid === userId
            ? getFollowingPets(userId)
            : Promise.resolve({
                followingPets: [] as FollowingPet[],
                lastDoc: null,
                hasMore: false,
              }),
        ]);
        if (ignore) return;
        setProfile(profileData);
        setPets(petList);
        setFollowingPets(followingResult.followingPets);
      } catch {
        // finally already clears loading; swallow so the failure doesn't
        // surface as an unhandled rejection.
      } finally {
        if (!ignore) {
          setLoading(false);
        }
      }
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [user?.uid, userId]);

  // Pre-fetch the viewer's follow status for every pet rendered on this
  // page in a single batched read instead of letting each PetFollowButton
  // do its own checkIfFollowingPet getDoc (N+1 on profiles with many
  // pets).
  useEffect(() => {
    let ignore = false;
    if (!user?.uid || pets.length === 0) {
      setFollowedPetIds(new Set());
      return;
    }
    const load = async () => {
      const ids = pets.map((pet) => pet.id);
      const followed = await batchCheckFollowingPets(user.uid, ids);
      if (!ignore) {
        setFollowedPetIds(followed);
      }
    };
    void load();
    return () => {
      ignore = true;
    };
  }, [pets, user?.uid]);

  const joinedDate = useMemo(() => {
    if (!profile?.createdAt) return "Unknown";
    const date =
      profile.createdAt instanceof Date
        ? profile.createdAt
        : typeof profile.createdAt === "object" &&
          profile.createdAt !== null &&
          "toDate" in profile.createdAt &&
          typeof (profile.createdAt as { toDate: () => Date }).toDate ===
            "function"
        ? (profile.createdAt as { toDate: () => Date }).toDate()
        : null;
    return date
      ? date.toLocaleDateString(undefined, {
          year: "numeric",
          month: "short",
          day: "numeric",
        })
      : "Unknown";
  }, [profile?.createdAt]);

  if (!userId) {
    return null;
  }

  const blocked = user ? isBlocked(userId) : false;

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
            Profile
          </h1>
          <div className="w-6" />
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-6 px-4 py-6">
        {blocked ? (
          <section className="rounded-3xl bg-white p-6 text-center shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
            <h2 className="text-base font-semibold text-slate-900 dark:text-white">
              You have blocked this user
            </h2>
            <p className="mt-2 text-sm text-slate-500 dark:text-slate-300">
              Unblock to view their profile and pets again.
            </p>
            <button
              type="button"
              onClick={async () => {
                if (!user) return;
                try {
                  await unblockUser(user.uid, userId);
                } catch {
                  showToast("Failed to unblock user.", "error");
                }
              }}
              className="mt-4 rounded-full border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-700 transition-all duration-200 hover:scale-105 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-200"
            >
              Unblock
            </button>
          </section>
        ) : null}

        {!blocked ? (
          <section className="space-y-4">
            <div className="flex flex-col items-center text-center">
              <div className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 p-[3px]">
                <div className="rounded-full bg-white p-[2px] dark:bg-slate-900">
                  <Avatar
                    src={profile?.avatarUrl || undefined}
                    alt={profile?.displayName || "User"}
                    userId={profile?.id}
                    size={96}
                    className="h-24 w-24"
                  />
                </div>
              </div>
              <h2 className="mt-3 text-xl font-semibold text-slate-900 dark:text-white">
                {profile?.displayName || "PetNote User"}
              </h2>
              <p className="text-xs text-slate-500 dark:text-slate-400">
                @{profile?.displayName || "unknown"}
              </p>
              {profile?.bio ? (
                <p className="mt-2 text-sm text-slate-600 dark:text-slate-300">
                  {profile.bio}
                </p>
              ) : null}
              {profile?.location?.city ? (
                <p className="mt-1 text-xs text-slate-400 dark:text-slate-500">
                  {profile.location.state
                    ? `${profile.location.city}, ${profile.location.state}`
                    : profile.location.city}
                </p>
              ) : null}
            </div>

            <div className="grid grid-cols-2 divide-x divide-slate-200 text-center dark:divide-slate-800">
              <div className="px-2 py-2">
                <p className="text-lg font-semibold text-slate-900 dark:text-white">
                  {pets.length}
                </p>
                <p className="text-xs text-slate-500 dark:text-slate-400">Pets</p>
              </div>
              {user?.uid === userId ? (
                <button
                  type="button"
                  onClick={() => setFollowingModalOpen(true)}
                  className="px-2 py-2"
                >
                  <p className="text-lg font-semibold text-slate-900 dark:text-white">
                    {profile?.followingPetsCount ?? followingPets.length}
                  </p>
                  <p className="text-xs text-slate-500 dark:text-slate-400">Following</p>
                </button>
              ) : (
                // Other users' followingPets subcollection is owner-only per
                // Firestore rules — the modal would always be empty, so the
                // stat is display-only here.
                <div className="px-2 py-2">
                  <p className="text-lg font-semibold text-slate-900 dark:text-white">
                    {profile?.followingPetsCount ?? 0}
                  </p>
                  <p className="text-xs text-slate-500 dark:text-slate-400">Following</p>
                </div>
              )}
            </div>

            <p className="text-center text-xs text-slate-400 dark:text-slate-500">
              Joined {joinedDate}
            </p>
          </section>
        ) : null}

        {!blocked ? (
          <section className="space-y-3">
            <h3 className="text-base font-semibold text-slate-900 dark:text-white">
              Pets
            </h3>
            {loading ? (
              <div className="space-y-3">
                {[1, 2, 3].map((item) => (
                  <div
                    key={item}
                    className="h-20 animate-pulse rounded-2xl bg-slate-200 dark:bg-slate-700"
                  />
                ))}
              </div>
            ) : pets.length === 0 ? (
              <div className="rounded-2xl border border-slate-100 bg-slate-50 p-6 text-center text-sm text-slate-500 dark:border-slate-700 dark:bg-slate-800 dark:text-slate-300">
                No pets yet
              </div>
            ) : (
              <div className="space-y-3">
                {pets.map((pet) => {
                  const species = getSpeciesMeta(pet.species);
                  return (
                    <div
                      key={pet.id}
                      className="flex items-center justify-between rounded-2xl bg-white px-4 py-3 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700"
                    >
                      <button
                        type="button"
                        onClick={() => navigate(`/pet/${pet.id}`)}
                        className="flex items-center gap-3 text-left"
                      >
                        <Avatar
                          src={pet.avatarUrl || undefined}
                          alt={pet.name}
                          userId={pet.id}
                          size={44}
                          className="h-11 w-11"
                        />
                        <div>
                          <div className="flex items-center gap-1">
                            <p className="text-sm font-semibold text-slate-900 dark:text-white">
                              {pet.name}
                            </p>
                            <span className="text-sm">{species.emoji}</span>
                          </div>
                          {pet.breed ? (
                            <p className="text-xs text-slate-400 dark:text-slate-500">
                              {pet.breed}
                            </p>
                          ) : null}
                          {pet.relationship ? (
                            <p className="text-[11px] text-slate-400 dark:text-slate-500">
                              {getRelationshipLabel(
                                pet.relationship,
                                pet.customRelationship
                              )}
                            </p>
                          ) : null}
                        </div>
                      </button>
                      <PetFollowButton
                        petId={pet.id}
                        initialFollowing={followedPetIds.has(pet.id)}
                      />
                    </div>
                  );
                })}
              </div>
            )}
          </section>
        ) : null}
      </main>

      {followingModalOpen ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-md rounded-3xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)] dark:bg-slate-800">
            <div className="flex items-center justify-between">
              <h3 className="text-base font-semibold text-slate-900 dark:text-white">
                Following Pets
              </h3>
              <button
                type="button"
                onClick={() => {
                  setFollowingModalOpen(false);
                }}
                className="text-sm text-slate-500 hover:text-slate-700 dark:text-slate-300"
              >
                Close
              </button>
            </div>
            <div className="mt-4 space-y-3">
              {followingPets.length === 0 ? (
                <p className="text-center text-sm text-slate-500 dark:text-slate-300">
                  No followed pets yet
                </p>
              ) : (
                followingPets.map((pet) => (
                  <button
                    key={pet.petId}
                    type="button"
                    onClick={() => navigate(`/pet/${pet.petId}`)}
                    className="flex w-full items-center gap-3 rounded-2xl bg-white px-4 py-3 text-left shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 transition-all duration-200 hover:-translate-y-0.5 dark:bg-slate-800 dark:ring-slate-700"
                  >
                    <Avatar
                      src={pet.petAvatar || undefined}
                      alt={pet.petName || "Pet"}
                      userId={pet.petId}
                      size={40}
                      className="h-10 w-10"
                    />
                    <p className="text-sm font-semibold text-slate-900 dark:text-white">
                      {pet.petName || "Pet"}
                    </p>
                  </button>
                ))
              )}
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
