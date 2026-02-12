import { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import Avatar from "../components/Avatar";
import { EmptyState } from "../components/EmptyState";
import { InviteCodeModal } from "../components/InviteCodeModal";
import LazyImage from "../components/LazyImage";
import { useAuth } from "../hooks/useAuth";
import { useFollowPet } from "../hooks/useFollow";
import { getPetFollowers, type PetFollower } from "../services/follow";
import { getCheckinsByPet, type Checkin } from "../services/checkins";
import { getLocation, type Location } from "../services/locations";
import {
  deletePet,
  getPetById,
  getPetFamily,
  getPetTotalLikes,
  getPostsByPet,
  getRelationshipLabel,
  isFamilyMember,
  type FamilyMember,
  type Pet,
} from "../services/pets";
import type { Post } from "../services/posts";
import { getUserProfile } from "../services/users";
import { getSpeciesMeta } from "../utils/petHelpers";
import { getVideoThumbnail, optimizeCloudinaryUrl } from "../utils/cloudinaryUrl";
import { timeAgo } from "../utils/timeAgo";

const genderSymbolClass = "text-lg font-bold";

export function PetProfile() {
  const navigate = useNavigate();
  const { petId } = useParams();
  const { user, profile } = useAuth();

  const [pet, setPet] = useState<Pet | null>(null);
  const [posts, setPosts] = useState<Post[]>([]);
  const [petLikes, setPetLikes] = useState(0);
  const [ownerName, setOwnerName] = useState<string | null>(null);
  const [familyMembers, setFamilyMembers] = useState<FamilyMember[]>([]);
  const [viewerIsFamilyMember, setViewerIsFamilyMember] = useState(false);

  const [checkins, setCheckins] = useState<Checkin[]>([]);
  const [checkinLocations, setCheckinLocations] = useState<Record<string, Location | null>>(
    {}
  );

  const [loading, setLoading] = useState(true);
  const [activeTab, setActiveTab] = useState<"posts" | "checkins">("posts");
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [inviteOpen, setInviteOpen] = useState(false);
  const [followersOpen, setFollowersOpen] = useState(false);
  const [followers, setFollowers] = useState<PetFollower[]>([]);
  const [followersLoading, setFollowersLoading] = useState(false);

  const { isFollowing, followerCount, toggleFollow, loading: followLoading } =
    useFollowPet(petId ?? "");

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

      const [petPosts, family, totalLikes, petCheckins] = await Promise.all([
        getPostsByPet(petId),
        getPetFamily(petId),
        getPetTotalLikes(petId),
        getCheckinsByPet(petId, 100),
      ]);

      const primaryOwnerId = petData.primaryOwnerId || petData.ownerId;
      const primaryMember = family.find((member) => member.role === "primary");
      const fallbackOwnerProfile = primaryMember
        ? null
        : await getUserProfile(primaryOwnerId);

      let members = family;
      if (members.length === 0) {
        members = [
          {
            userId: primaryOwnerId,
            userName: fallbackOwnerProfile?.displayName || "Family",
            userAvatar:
              fallbackOwnerProfile?.avatarUrl ||
              `https://api.dicebear.com/7.x/thumbs/svg?seed=${primaryOwnerId}`,
            relationship: "caretaker",
            role: "primary",
          },
        ];
      }

      const isMember = user
        ? members.some((member) => member.userId === user.uid) ||
          (await isFamilyMember(petId, user.uid))
        : false;

      const uniqueLocationIds = Array.from(
        new Set(petCheckins.map((item) => item.locationId).filter(Boolean))
      );
      const locationEntries = await Promise.all(
        uniqueLocationIds.map(async (id) => [id, await getLocation(id)] as const)
      );
      const locationMap: Record<string, Location | null> = {};
      locationEntries.forEach(([id, location]) => {
        locationMap[id] = location;
      });

      if (!ignore) {
        setPet(petData);
        setPosts(petPosts);
        setPetLikes(totalLikes);
        setFamilyMembers(members);
        setViewerIsFamilyMember(isMember);
        setOwnerName(
          primaryMember?.userName || fallbackOwnerProfile?.displayName || "Family"
        );
        setCheckins(petCheckins);
        setCheckinLocations(locationMap);
        setLoading(false);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [petId, user]);

  const speciesMeta = useMemo(
    () => getSpeciesMeta(pet?.species),
    [pet?.species]
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

  const primaryOwnerId = pet.primaryOwnerId || pet.ownerId;
  const isPrimaryOwner = user?.uid === primaryOwnerId;

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
                src={optimizeCloudinaryUrl(pet.avatarUrl, "avatar")}
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

          <div className="mt-2 flex flex-wrap items-center justify-center gap-2 text-sm text-slate-500 dark:text-slate-300">
            <span>{speciesMeta.emoji}</span>
            {pet.breed ? <span>{pet.breed}</span> : null}
            {pet.gender === "male" ? (
              <span className={`${genderSymbolClass} text-blue-500`}>♂</span>
            ) : pet.gender === "female" ? (
              <span className={`${genderSymbolClass} text-pink-500`}>♀</span>
            ) : null}
            {pet.age ? <span>{pet.age}</span> : null}
            {!pet.age && birthdayLabel ? <span>{birthdayLabel}</span> : null}
          </div>

          {pet.bio ? (
            <p className="mt-3 text-sm text-slate-600 dark:text-slate-300">{pet.bio}</p>
          ) : null}

          <button
            type="button"
            onClick={() => navigate(`/profile/${primaryOwnerId}`)}
            className="mt-3 text-xs text-slate-500 hover:text-purple-600 dark:text-slate-400"
          >
            Family: {ownerName}
          </button>
        </section>

        <section className="space-y-3 rounded-2xl bg-white p-4 shadow-sm ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <div className="grid grid-cols-3 divide-x divide-slate-200 text-center dark:divide-slate-700">
            <button
              type="button"
              onClick={async () => {
                setFollowersLoading(true);
                try {
                  const data = await getPetFollowers(pet.id);
                  setFollowers(data);
                  setFollowersOpen(true);
                } finally {
                  setFollowersLoading(false);
                }
              }}
              className="px-2 py-2"
            >
              <p className="text-lg font-semibold text-slate-900 dark:text-white">
                {pet.followerCount ?? followerCount}
              </p>
              <p className="text-xs text-slate-400 dark:text-slate-500">Followers</p>
            </button>
            <div className="px-2 py-2">
              <p className="text-lg font-semibold text-slate-900 dark:text-white">
                {posts.length}
              </p>
              <p className="text-xs text-slate-400 dark:text-slate-500">Posts</p>
            </div>
            <div className="px-2 py-2">
              <p className="text-lg font-semibold text-slate-900 dark:text-white">
                {petLikes}
              </p>
              <p className="text-xs text-slate-400 dark:text-slate-500">Likes</p>
            </div>
          </div>

          {viewerIsFamilyMember ? (
            <div
              className={`grid gap-2 ${
                isPrimaryOwner ? "grid-cols-3" : "grid-cols-2"
              }`}
            >
              <button
                type="button"
                onClick={() => navigate(`/edit-pet/${pet.id}`)}
                className="rounded-full border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-700 transition-all duration-200 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-200"
              >
                Edit Pet
              </button>
              <button
                type="button"
                onClick={() => setInviteOpen(true)}
                className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white"
              >
                Invite Family
              </button>
              {isPrimaryOwner ? (
                <button
                  type="button"
                  onClick={() => setConfirmDelete(true)}
                  className="rounded-full border border-red-200 px-4 py-2 text-sm font-semibold text-red-500 transition-all duration-200 hover:bg-red-50 dark:border-red-500/40 dark:hover:bg-red-500/10"
                >
                  Delete
                </button>
              ) : null}
            </div>
          ) : (
            <button
              type="button"
              onClick={toggleFollow}
              disabled={!user || followLoading}
              className={`w-full rounded-full px-4 py-2 text-sm font-semibold transition-all duration-200 ${
                isFollowing
                  ? "border border-slate-200 text-slate-500 hover:border-red-300 hover:text-red-500 dark:border-slate-700 dark:text-slate-300"
                  : "bg-gradient-to-r from-purple-500 to-pink-500 text-white shadow-[0_10px_25px_-15px_rgba(168,85,247,0.7)]"
              }`}
            >
              {isFollowing ? "Following" : "Follow"}
            </button>
          )}
        </section>

        <section className="space-y-3 rounded-2xl bg-white p-4 shadow-sm ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <div className="flex items-center justify-between">
            <h3 className="text-sm font-semibold text-slate-900 dark:text-white">🏠 Family</h3>
            {viewerIsFamilyMember ? (
              <button
                type="button"
                onClick={() => setInviteOpen(true)}
                className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-3 py-1 text-xs font-semibold text-white"
              >
                Invite
              </button>
            ) : null}
          </div>
          <div className="flex gap-3 overflow-x-auto pb-1">
            {familyMembers.map((member) => (
              <button
                key={member.userId}
                type="button"
                onClick={() => navigate(`/profile/${member.userId}`)}
                className="flex min-w-[96px] flex-col items-center text-center"
              >
                <Avatar
                  src={member.userAvatar}
                  alt={member.userName}
                  userId={member.userId}
                  size={48}
                  className="h-12 w-12"
                />
                <span className="mt-2 line-clamp-1 text-xs font-semibold text-slate-900 dark:text-white">
                  {member.userName}
                  {member.role === "primary" ? " ★" : ""}
                </span>
                <span className="mt-1 rounded-full bg-slate-100 px-2 py-0.5 text-[10px] text-slate-500 dark:bg-slate-700 dark:text-slate-300">
                  {getRelationshipLabel(member.relationship, member.customRelationship)}
                </span>
              </button>
            ))}
          </div>
        </section>

        <section className="space-y-3">
          <div className="flex items-center gap-6 border-b border-slate-200 dark:border-slate-700">
            <button
              type="button"
              onClick={() => setActiveTab("posts")}
              className={`pb-2 text-sm font-semibold transition-all duration-200 ${
                activeTab === "posts"
                  ? "border-b-2 border-purple-500 text-slate-900 dark:text-white"
                  : "text-slate-400 hover:text-slate-600 dark:text-slate-500 dark:hover:text-slate-200"
              }`}
            >
              Posts
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
              Check-ins
            </button>
          </div>

          {activeTab === "posts" ? (
            posts.length === 0 ? (
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
                  const thumbSrc = isVideo
                    ? getVideoThumbnail(first?.url || post.mediaUrl || "", "thumbnail")
                    : first?.thumbUrl || first?.url || post.mediaUrl;
                  return (
                    <button
                      key={post.id}
                      type="button"
                      onClick={() => navigate(`/post/${post.id}`)}
                      className="relative aspect-square overflow-hidden rounded-2xl bg-slate-100 transition-all duration-200 hover:scale-[1.02] dark:bg-slate-800"
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
          ) : (
            checkins.length === 0 ? (
              <EmptyState
                icon="📍"
                title="No check-ins with this pet"
                description="Check in at places when this pet is with you"
              />
            ) : (
              <div className="space-y-3">
                {checkins.map((checkin) => {
                  const location = checkinLocations[checkin.locationId];
                  const locationName = location?.name || "Unknown location";
                  return (
                    <button
                      key={checkin.id}
                      type="button"
                      onClick={() => navigate(`/location/${checkin.locationId}`)}
                      className="flex w-full items-center gap-3 rounded-2xl bg-white p-3 text-left shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 transition-all duration-200 hover:-translate-y-0.5 dark:bg-slate-800 dark:ring-slate-700"
                    >
                      <div className="h-14 w-14 overflow-hidden rounded-xl">
                        <LazyImage
                          src={checkin.photoUrl}
                          alt="Check-in"
                          className="h-full w-full"
                          cloudinarySize="small"
                        />
                      </div>
                      <div className="flex-1">
                        <p className="text-sm font-semibold text-slate-900 dark:text-white">
                          {locationName}
                        </p>
                        <p className="text-xs text-slate-400 dark:text-slate-500">
                          {checkin.createdAt ? timeAgo(checkin.createdAt as Date) : ""}
                        </p>
                      </div>
                    </button>
                  );
                })}
              </div>
            )
          )}
        </section>
      </main>

      {followersOpen ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-md rounded-3xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)] dark:bg-slate-800">
            <div className="flex items-center justify-between">
              <h3 className="text-base font-semibold text-slate-900 dark:text-white">
                Followers
              </h3>
              <button
                type="button"
                onClick={() => setFollowersOpen(false)}
                className="text-sm text-slate-500 hover:text-slate-700 dark:text-slate-300"
              >
                Close
              </button>
            </div>
            <div className="mt-4 space-y-3">
              {followersLoading ? (
                <p className="text-center text-sm text-slate-500 dark:text-slate-300">
                  Loading...
                </p>
              ) : followers.length === 0 ? (
                <p className="text-center text-sm text-slate-500 dark:text-slate-300">
                  No followers yet
                </p>
              ) : (
                followers.map((follower) => (
                  <button
                    key={follower.userId}
                    type="button"
                    onClick={() => navigate(`/profile/${follower.userId}`)}
                    className="flex w-full items-center gap-3 rounded-2xl bg-white px-4 py-3 text-left shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 transition-all duration-200 hover:-translate-y-0.5 dark:bg-slate-800 dark:ring-slate-700"
                  >
                    <Avatar
                      src={follower.userAvatar || undefined}
                      alt={follower.userName || "User"}
                      userId={follower.userId}
                      size={40}
                      className="h-10 w-10"
                    />
                    <p className="text-sm font-semibold text-slate-900 dark:text-white">
                      {follower.userName || "PetNote User"}
                    </p>
                  </button>
                ))
              )}
            </div>
          </div>
        </div>
      ) : null}

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

      {user && viewerIsFamilyMember ? (
        <InviteCodeModal
          isOpen={inviteOpen}
          onClose={() => setInviteOpen(false)}
          petId={pet.id}
          petName={pet.name}
          userId={user.uid}
          userName={profile?.displayName || user.displayName || "User"}
        />
      ) : null}
    </div>
  );
}
