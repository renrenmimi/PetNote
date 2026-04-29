import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import Avatar from "../components/Avatar";
import LazyImage from "../components/LazyImage";
import { EmptyState } from "../components/EmptyState";
import { SkeletonProfile } from "../components/SkeletonProfile";
import { useAuth } from "../hooks/useAuth";
import { useAdmin } from "../hooks/useAdmin";
import { getBookmarkedPosts } from "../services/bookmarks";
import { getUserCheckins, type Checkin } from "../services/checkins";
import {
  getFollowingPets,
  unfollowPet,
  type FollowingPet,
} from "../services/follow";
import { getLocation, type Location } from "../services/locations";
import { type Post } from "../services/posts";
import {
  getRelationshipLabel,
  getUserPets,
  type Pet,
} from "../services/pets";
import { getUserProfile } from "../services/users";
import { useLanguage } from "../hooks/useLanguage";
import { getVideoThumbnail } from "../utils/cloudinaryUrl";
import { getSpeciesMeta } from "../utils/petHelpers";
import { timeAgo } from "../utils/timeAgo";

const genderSymbolClass = "text-base font-bold";

export function Profile() {
  const navigate = useNavigate();
  const { locale, t } = useLanguage();
  const { user, profile: authProfile } = useAuth();
  const { isAdmin } = useAdmin();

  const [loading, setLoading] = useState(true);
  const [profileName, setProfileName] = useState<string | null>(null);
  const [profileAvatar, setProfileAvatar] = useState<string | null>(null);
  const [profileBio, setProfileBio] = useState<string | null>(null);
  const [profileLocation, setProfileLocation] = useState<string | null>(null);

  const [pets, setPets] = useState<Pet[]>([]);

  const [savedPosts, setSavedPosts] = useState<Post[]>([]);
  const [savedLoading, setSavedLoading] = useState(false);

  const [checkins, setCheckins] = useState<Checkin[]>([]);
  const [checkinsLoading, setCheckinsLoading] = useState(false);
  const [checkinLocations, setCheckinLocations] = useState<Record<string, Location | null>>(
    {}
  );

  const [followingPets, setFollowingPets] = useState<FollowingPet[]>([]);
  const [followingModalOpen, setFollowingModalOpen] = useState(false);
  const [followingPetsLoading, setFollowingPetsLoading] = useState(false);

  const [activeTab, setActiveTab] = useState<"pets" | "saved" | "checkins">(
    "pets"
  );

  useEffect(() => {
    let ignore = false;
    if (!user) return;

    const load = async () => {
      setLoading(true);
      try {
        const [profile, petList] = await Promise.all([
          getUserProfile(user.uid),
          getUserPets(user.uid),
        ]);
        if (ignore) return;

        setProfileName(profile?.displayName || null);
        setProfileAvatar(profile?.avatarUrl || null);
        setProfileBio(profile?.bio || null);
        setPets(petList);

        if (profile?.location?.city) {
          const { city, state } = profile.location;
          setProfileLocation(state ? `${city}, ${state}` : city);
        } else {
          setProfileLocation(null);
        }
      } finally {
        if (!ignore) setLoading(false);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [user]);

  useEffect(() => {
    let ignore = false;
    if (!user || activeTab !== "saved") return;

    const loadSaved = async () => {
      setSavedLoading(true);
      try {
        const saved = await getBookmarkedPosts(user.uid);
        if (!ignore) {
          setSavedPosts(saved);
        }
      } finally {
        if (!ignore) {
          setSavedLoading(false);
        }
      }
    };

    void loadSaved();
    return () => {
      ignore = true;
    };
  }, [activeTab, user]);

  useEffect(() => {
    let ignore = false;
    if (!user || activeTab !== "checkins") return;

    const loadCheckins = async () => {
      setCheckinsLoading(true);
      try {
        const list = await getUserCheckins(user.uid);
        if (ignore) return;
        setCheckins(list);

        const uniqueIds = Array.from(
          new Set(list.map((item) => item.locationId).filter(Boolean))
        );
        const entries = await Promise.all(
          uniqueIds.map(async (id) => [id, await getLocation(id)] as const)
        );
        if (ignore) return;

        const mapping: Record<string, Location | null> = {};
        entries.forEach(([id, location]) => {
          mapping[id] = location;
        });
        setCheckinLocations(mapping);
      } catch (error) {
        console.warn("Permission error while loading check-ins:", error);
        if (!ignore) {
          setCheckins([]);
          setCheckinLocations({});
        }
      } finally {
        if (!ignore) {
          setCheckinsLoading(false);
        }
      }
    };

    void loadCheckins();
    return () => {
      ignore = true;
    };
  }, [activeTab, user]);

  const joinedDate = useMemo(() => {
    const created = user?.metadata?.creationTime;
    if (!created) return t("common.notSet");
    return new Date(created).toLocaleDateString(locale, {
      year: "numeric",
      month: "short",
      day: "numeric",
    });
  }, [locale, t, user]);

  if (!user) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-white dark:bg-slate-900">
        <div className="text-center">
          <p className="text-sm text-slate-500 dark:text-slate-300">
            {t("profile.loginRequired")}
          </p>
          <button
            type="button"
            onClick={() => navigate("/login")}
            className="mt-4 rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white"
          >
            {t("profile.goToLogin")}
          </button>
        </div>
      </main>
    );
  }

  return (
    <div className="min-h-screen bg-white pb-24 dark:bg-slate-900">
      <header className="sticky top-0 z-10 border-b border-slate-200 bg-white dark:border-slate-800 dark:bg-slate-900">
        <div className="mx-auto flex w-full max-w-md items-center justify-between px-4 py-3">
          <h1 className="text-base font-semibold text-slate-900 dark:text-white">
            {t("profile.title")}
          </h1>
          <button
            type="button"
            onClick={() => navigate("/settings")}
            className="text-xl text-slate-500 transition-colors hover:text-slate-700 dark:text-slate-300 dark:hover:text-white"
            aria-label={t("nav.settings")}
          >
            ⚙️
          </button>
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-6 px-4 py-6">
        {loading ? (
          <SkeletonProfile />
        ) : (
          <section className="space-y-4">
            <div className="flex flex-col items-center text-center">
              <div className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 p-[3px]">
                <div className="rounded-full bg-white p-[2px] dark:bg-slate-900">
                  <Avatar
                    src={profileAvatar || user.photoURL || undefined}
                    alt={profileName || user.displayName || t("common.user")}
                    userId={user.uid}
                    size={96}
                    className="h-24 w-24"
                  />
                </div>
              </div>
              <h2 className="mt-3 text-xl font-semibold text-slate-900 dark:text-white">
                {profileName || user.displayName || t("common.petnoteUser")}
              </h2>
              <p className="text-xs text-slate-500 dark:text-slate-400">
                @{profileName || user.displayName || t("profile.usernameFallback")}
              </p>
              {profileBio ? (
                <p className="mt-2 text-sm text-slate-600 dark:text-slate-300">
                  {profileBio}
                </p>
              ) : null}
              {profileLocation ? (
                <p className="mt-1 text-xs text-slate-400 dark:text-slate-500">
                  {profileLocation}
                </p>
              ) : null}
            </div>

            <div className="grid grid-cols-2 divide-x divide-slate-200 text-center dark:divide-slate-800">
              <div className="px-2 py-2">
                <p className="text-lg font-semibold text-slate-900 dark:text-white">
                  {pets.length}
                </p>
                <p className="text-xs text-slate-500 dark:text-slate-400">
                  {t("profile.petsCountLabel")}
                </p>
              </div>
              <button
                type="button"
                onClick={async () => {
                  setFollowingPetsLoading(true);
                  try {
                    const items = await getFollowingPets(user.uid);
                    setFollowingPets(items);
                    setFollowingModalOpen(true);
                  } finally {
                    setFollowingPetsLoading(false);
                  }
                }}
                className="px-2 py-2"
              >
                <p className="text-lg font-semibold text-slate-900 dark:text-white">
                  {authProfile?.followingPetsCount ?? followingPets.length}
                </p>
                <p className="text-xs text-slate-500 dark:text-slate-400">
                  {t("profile.followingLabel")}
                </p>
              </button>
            </div>

            <div className="flex items-center justify-center gap-3">
              <button
                type="button"
                onClick={() => navigate("/edit-profile")}
                className="rounded-full border border-slate-200 px-5 py-2 text-sm font-semibold text-slate-700 transition-all duration-200 hover:scale-105 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-200"
              >
                {t("profile.editProfile")}
              </button>
            </div>

            {isAdmin ? (
              <div className="flex items-center justify-center">
                <button
                  type="button"
                  onClick={() => navigate("/admin")}
                  className="rounded-full border border-red-200 px-4 py-2 text-xs font-semibold text-red-500 transition-all duration-200 hover:border-red-300 hover:bg-red-50 dark:border-red-500/40 dark:hover:bg-red-500/10"
                >
                  {t("profile.adminPanel")}
                </button>
              </div>
            ) : null}
          </section>
        )}

        {!loading ? (
          <section className="space-y-3">
            <div className="flex items-center gap-6 border-b border-slate-200 dark:border-slate-700">
              <button
                type="button"
                onClick={() => setActiveTab("pets")}
                className={`pb-2 text-sm font-semibold transition-all duration-200 ${
                  activeTab === "pets"
                    ? "border-b-2 border-purple-500 text-slate-900 dark:text-white"
                    : "text-slate-400 hover:text-slate-600 dark:text-slate-500 dark:hover:text-slate-200"
                }`}
              >
                {t("profile.tabPets")}
              </button>
              <button
                type="button"
                onClick={() => setActiveTab("saved")}
                className={`pb-2 text-sm font-semibold transition-all duration-200 ${
                  activeTab === "saved"
                    ? "border-b-2 border-purple-500 text-slate-900 dark:text-white"
                    : "text-slate-400 hover:text-slate-600 dark:text-slate-500 dark:hover:text-slate-200"
                }`}
              >
                {t("profile.tabSaved")}
              </button>
              <button
                type="button"
                onClick={() => setActiveTab("checkins")}
                className={`pb-2 text-sm font-semibold transition-all duration-200 ${
                  activeTab === "checkins"
                    ? "border-b-2 border-purple-500 text-slate-900 dark:text-white"
                    : "text-slate-400 hover:text-slate-600 dark:text-slate-500 dark:hover:text-slate-200"
                }`}
              >
                {t("profile.tabCheckins")}
              </button>
            </div>

            {activeTab === "pets" ? (
              pets.length === 0 ? (
                <EmptyState
                  icon="🐾"
                  title={t("profile.emptyPetsTitle")}
                  description={t("profile.emptyPetsDescription")}
                  actionText={t("profile.addPet")}
                  onAction={() => navigate("/add-pet")}
                />
              ) : (
                <div className="space-y-3">
                  {pets.map((pet) => {
                    const species = getSpeciesMeta(pet.species);
                    const postCount = pet.postCount ?? 0;
                    return (
                      <button
                        key={pet.id}
                        type="button"
                        onClick={() => navigate(`/pet/${pet.id}`)}
                        className="flex w-full items-center gap-3 rounded-2xl bg-white px-4 py-3 text-left shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 transition-all duration-200 hover:-translate-y-0.5 dark:bg-slate-800 dark:ring-slate-700"
                      >
                        <Avatar
                          src={pet.avatarUrl || undefined}
                          alt={pet.name}
                          userId={pet.id}
                          size={48}
                          className="h-12 w-12"
                        />
                        <div className="flex-1">
                          <div className="flex items-center gap-1">
                            <p className="text-sm font-semibold text-slate-900 dark:text-white">
                              {pet.name}
                            </p>
                            <span className="text-sm">{species.emoji}</span>
                            {pet.gender === "male" ? (
                              <span className={`${genderSymbolClass} text-blue-500`}>♂</span>
                            ) : pet.gender === "female" ? (
                              <span className={`${genderSymbolClass} text-pink-500`}>♀</span>
                            ) : null}
                          </div>
                          {pet.breed ? (
                            <p className="text-xs text-slate-400 dark:text-slate-500">
                              {pet.breed}
                            </p>
                          ) : null}
                          <p className="text-xs text-slate-400 dark:text-slate-500">
                            {t("profile.postsFollowers", {
                              posts: postCount,
                              followers: pet.followerCount || 0,
                            })}
                          </p>
                        </div>
                        <span className="rounded-full bg-slate-100 px-2 py-1 text-[10px] font-semibold text-slate-500 dark:bg-slate-700 dark:text-slate-300">
                          {getRelationshipLabel(pet.relationship, pet.customRelationship)}
                        </span>
                      </button>
                    );
                  })}

                  {pets.length < 5 ? (
                    <button
                      type="button"
                      onClick={() => navigate("/add-pet")}
                      className="w-full rounded-full border border-slate-200 px-4 py-2 text-sm font-semibold text-purple-600 transition-all duration-200 hover:border-purple-300 hover:bg-purple-50 dark:border-slate-700 dark:hover:bg-purple-500/10"
                    >
                      + {t("profile.addPet")}
                    </button>
                  ) : null}
                </div>
              )
            ) : null}

            {activeTab === "saved" ? (
              savedLoading ? (
                <div className="grid grid-cols-3 gap-2">
                  {[1, 2, 3].map((item) => (
                    <div
                      key={item}
                      className="aspect-square animate-pulse rounded-2xl bg-slate-200 dark:bg-slate-700"
                    />
                  ))}
                </div>
              ) : savedPosts.length === 0 ? (
                <EmptyState
                  icon="🔖"
                  title={t("profile.emptySavedTitle")}
                  description={t("profile.emptySavedDescription")}
                />
              ) : (
                <div className="grid grid-cols-3 gap-2">
                  {savedPosts.map((post) => {
                    const mediaList =
                      post.media && post.media.length > 0
                        ? post.media
                        : post.mediaUrl
                        ? [{ url: post.mediaUrl, type: post.mediaType || "image" }]
                        : [];
                    const first = mediaList[0];
                    const isMulti = mediaList.length > 1;
                    const isVideo = first?.type === "video";
                    const thumbSrc = isVideo
                      ? getVideoThumbnail(
                          first?.url || post.mediaUrl || "",
                          "thumbnail"
                        )
                      : first?.thumbUrl || first?.url || post.mediaUrl;
                    return (
                      <button
                        key={post.id}
                        type="button"
                        onClick={() => navigate(`/post/${post.id}`)}
                        className="relative aspect-square overflow-hidden rounded-2xl bg-slate-100 dark:bg-slate-800"
                      >
                        {thumbSrc ? (
                          <LazyImage
                            src={thumbSrc}
                            alt={post.text}
                            className="h-full w-full"
                            cloudinarySize="thumbnail"
                          />
                        ) : null}
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
              )
            ) : null}

            {activeTab === "checkins" ? (
              checkinsLoading ? (
                <div className="space-y-3">
                  {[1, 2, 3].map((item) => (
                    <div
                      key={item}
                      className="h-20 animate-pulse rounded-2xl bg-slate-200 dark:bg-slate-700"
                    />
                  ))}
                </div>
              ) : checkins.length === 0 ? (
                <EmptyState
                  icon="📍"
                  title={t("profile.emptyCheckinsTitle")}
                  description={t("profile.emptyCheckinsDescription")}
                />
              ) : (
                <div className="space-y-3">
                  {checkins.map((checkin) => {
                    const location = checkinLocations[checkin.locationId];
                    const locationName =
                      location?.name || t("profile.unknownLocation");
                    const locationPhoto = location?.photos?.[0];
                    return (
                      <button
                        key={checkin.id}
                        type="button"
                        onClick={() => navigate(`/location/${checkin.locationId}`)}
                        className="flex w-full items-center gap-3 rounded-2xl bg-white p-3 text-left shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 transition-all duration-200 hover:-translate-y-0.5 dark:bg-slate-800 dark:ring-slate-700"
                      >
                        {locationPhoto ? (
                          <LazyImage
                            src={locationPhoto}
                            alt={locationName}
                            className="h-14 w-14 rounded-xl"
                            cloudinarySize="small"
                          />
                        ) : (
                          <div className="flex h-14 w-14 items-center justify-center rounded-xl bg-gradient-to-br from-purple-400 to-pink-400 text-lg text-white">
                            📍
                          </div>
                        )}
                        <div className="flex-1">
                          <p className="text-sm font-semibold text-slate-900 dark:text-white">
                            {locationName}
                          </p>
                          <p className="text-xs text-slate-400">
                            {checkin.createdAt ? timeAgo(checkin.createdAt as Date) : ""}
                          </p>
                        </div>
                        <div className="h-14 w-14 overflow-hidden rounded-xl">
                          <LazyImage
                            src={checkin.photoUrl}
                            alt={t("profile.checkInImageAlt")}
                            className="h-full w-full"
                            cloudinarySize="small"
                          />
                        </div>
                      </button>
                    );
                  })}
                </div>
              )
            ) : null}
          </section>
        ) : null}

        {!loading ? (
          <div className="pt-4">
            <p className="text-xs text-slate-400 dark:text-slate-500">
              {t("profile.joinedOn", { date: joinedDate })}
            </p>
          </div>
        ) : null}
      </main>

      {followingModalOpen ? (
        <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-md rounded-3xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)] dark:bg-slate-800">
            <div className="flex items-center justify-between">
              <h3 className="text-base font-semibold text-slate-900 dark:text-white">
                {t("profile.followingPetsTitle")}
              </h3>
              <button
                type="button"
                onClick={() => {
                  setFollowingModalOpen(false);
                }}
                className="text-sm text-slate-500 hover:text-slate-700 dark:text-slate-300"
              >
                {t("common.close")}
              </button>
            </div>
            <div className="mt-4 space-y-3">
              {followingPetsLoading ? (
                <p className="text-center text-sm text-slate-500 dark:text-slate-300">
                  {t("common.loading")}
                </p>
              ) : followingPets.length === 0 ? (
                <p className="text-center text-sm text-slate-500 dark:text-slate-300">
                  {t("profile.noFollowingPets")}
                </p>
              ) : (
                followingPets.map((pet) => (
                  <div
                    key={pet.petId}
                    className="flex items-center justify-between rounded-2xl bg-white px-4 py-3 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700"
                  >
                    <button
                      type="button"
                      onClick={() => navigate(`/pet/${pet.petId}`)}
                      className="flex items-center gap-3 text-left"
                    >
                      <Avatar
                        src={pet.petAvatar || undefined}
                        alt={pet.petName || t("common.pet")}
                        userId={pet.petId}
                        size={40}
                        className="h-10 w-10"
                      />
                      <p className="text-sm font-semibold text-slate-900 dark:text-white">
                        {pet.petName || t("common.pet")}
                      </p>
                    </button>
                    <button
                      type="button"
                      onClick={async () => {
                        await unfollowPet(user.uid, pet.petId);
                        setFollowingPets((prev) =>
                          prev.filter((item) => item.petId !== pet.petId)
                        );
                      }}
                      className="rounded-full border border-slate-200 px-3 py-1 text-xs font-semibold text-slate-500 transition-all duration-200 hover:border-red-200 hover:text-red-500 dark:border-slate-700 dark:text-slate-300"
                    >
                      {t("profile.unfollow")}
                    </button>
                  </div>
                ))
              )}
            </div>
          </div>
        </div>
      ) : null}

    </div>
  );
}
