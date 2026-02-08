import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { useAdmin } from "../hooks/useAdmin";
import { PostCard } from "../components/PostCard";
import { UserCard } from "../components/UserCard";
import { EmptyState } from "../components/EmptyState";
import { SkeletonProfile } from "../components/SkeletonProfile";
import Avatar from "../components/Avatar";
import { getBookmarkedPosts } from "../services/bookmarks";
import { getFollowers, getFollowing } from "../services/follow";
import {
  deletePost,
  getPostById,
  getPostsByUser,
  getUserStats,
  unpinPost,
  type Post,
} from "../services/posts";
import { getPetsByOwner, type Pet } from "../services/pets";
import { getUserProfile, getUsersByIds, type UserProfile } from "../services/users";
import { getSpeciesMeta } from "../utils/petHelpers";
import { useToast } from "../contexts/ToastContext";

export function Profile() {
  const navigate = useNavigate();
  const { user, signOut, profile: authProfile } = useAuth();
  const { isAdmin } = useAdmin();
  const { showToast } = useToast();
  const [posts, setPosts] = useState<Post[]>([]);
  const [stats, setStats] = useState({ postCount: 0, totalLikes: 0 });
  const [loading, setLoading] = useState(true);
  const [profileName, setProfileName] = useState<string | null>(null);
  const [profileAvatar, setProfileAvatar] = useState<string | null>(null);
  const [profileBio, setProfileBio] = useState<string | null>(null);
  const [profileLocation, setProfileLocation] = useState<string | null>(null);
  const [pinnedPost, setPinnedPost] = useState<Post | null>(null);
  const [pets, setPets] = useState<Pet[]>([]);
  const [savedPosts, setSavedPosts] = useState<Post[]>([]);
  const [savedLoading, setSavedLoading] = useState(false);
  const [activeTab, setActiveTab] = useState<"posts" | "saved">("posts");
  const [followCounts, setFollowCounts] = useState({
    followerCount: 0,
    followingCount: 0,
  });
  const [modalTitle, setModalTitle] = useState<string | null>(null);
  const [modalUsers, setModalUsers] = useState<UserProfile[]>([]);
  const [deleteTarget, setDeleteTarget] = useState<Post | null>(null);
  const [deleting, setDeleting] = useState(false);

  useEffect(() => {
    let ignore = false;
    if (!user) return;

    const load = async () => {
      setLoading(true);
      try {
        const [postList, userStats, profile, petList] = await Promise.all([
          getPostsByUser(user.uid),
          getUserStats(user.uid),
          getUserProfile(user.uid),
          getPetsByOwner(user.uid),
        ]);
        if (ignore) return;
        setPosts(postList);
        setStats(userStats);
        setProfileName(profile?.displayName || null);
        setProfileAvatar(profile?.avatarUrl || null);
        setProfileBio(profile?.bio || null);
        if (profile?.location?.city) {
          const { city, state } = profile.location;
          setProfileLocation(state ? `${city}, ${state}` : city);
        } else {
          setProfileLocation(null);
        }
        setPets(petList);
        setFollowCounts({
          followerCount: profile?.followerCount ?? 0,
          followingCount: profile?.followingCount ?? 0,
        });
        if (profile?.pinnedPostId) {
          const pinned =
            postList.find((item) => item.id === profile.pinnedPostId) ??
            (await getPostById(profile.pinnedPostId));
          setPinnedPost(pinned ?? null);
        } else {
          setPinnedPost(null);
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
    if (!user) return;
    const pinnedId = authProfile?.pinnedPostId;
    if (!pinnedId) {
      setPinnedPost(null);
      return;
    }
    const loadPinned = async () => {
      const pinned =
        posts.find((item) => item.id === pinnedId) ??
        (await getPostById(pinnedId));
      if (!ignore) setPinnedPost(pinned ?? null);
    };
    void loadPinned();
    return () => {
      ignore = true;
    };
  }, [authProfile?.pinnedPostId, posts, user]);

  useEffect(() => {
    let ignore = false;
    if (!user || activeTab !== "saved") return;
    const loadSaved = async () => {
      setSavedLoading(true);
      try {
        const saved = await getBookmarkedPosts(user.uid);
        if (!ignore) setSavedPosts(saved);
      } finally {
        if (!ignore) setSavedLoading(false);
      }
    };
    void loadSaved();
    return () => {
      ignore = true;
    };
  }, [activeTab, user]);

  const joinedDate = useMemo(() => {
    const created = user?.metadata?.creationTime;
    if (!created) return "Unknown";
    return new Date(created).toLocaleDateString(undefined, {
      year: "numeric",
      month: "short",
      day: "numeric",
    });
  }, [user]);

  const gridPosts = useMemo(() => {
    if (!pinnedPost) return posts;
    return posts.filter((post) => post.id !== pinnedPost.id);
  }, [pinnedPost, posts]);

  const formatLikes = (value: number) => {
    if (value >= 1000) {
      const formatted = (value / 1000).toFixed(1).replace(/\.0$/, "");
      return `${formatted}k`;
    }
    return value.toString();
  };

  if (!user) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-white dark:bg-slate-900">
        <div className="text-center">
          <p className="text-sm text-slate-500 dark:text-slate-300">
            Please log in to view profile.
          </p>
          <button
            type="button"
            onClick={() => navigate("/login")}
            className="mt-4 rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white"
          >
            Go to Login
          </button>
        </div>
      </main>
    );
  }

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
          <h1 className="text-base font-semibold text-slate-900 dark:text-white">Profile</h1>
          <div className="w-6" />
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
                  alt={profileName || user.displayName || "User"}
                  userId={user.uid}
                  size={96}
                  className="h-24 w-24"
                />
              </div>
            </div>
            <h2 className="mt-3 text-xl font-semibold text-slate-900 dark:text-white">
              {profileName || user.displayName || "PetNote User"}
            </h2>
            <p className="text-xs text-slate-500 dark:text-slate-400">
              @{profileName?.replace(/\s+/g, "").toLowerCase() || user.email}
            </p>
            {profileBio ? (
              <p className="mt-2 text-sm text-slate-600 dark:text-slate-300">
                {profileBio}
              </p>
            ) : null}
            {profileLocation ? (
              <p className="mt-1 text-xs text-slate-400 dark:text-slate-500">
                📍 {profileLocation}
              </p>
            ) : null}
          </div>

          <div className="grid grid-cols-3 divide-x divide-slate-200 text-center dark:divide-slate-800">
            <div className="px-2 py-2">
              <p className="text-lg font-semibold text-slate-900 dark:text-white">
                {stats.postCount}
              </p>
              <p className="text-xs text-slate-500 dark:text-slate-400">Posts</p>
            </div>
            <button
              type="button"
              onClick={async () => {
                const ids = await getFollowers(user.uid);
                const profiles = await getUsersByIds(ids);
                setModalTitle("Followers");
                setModalUsers(profiles);
              }}
              className="px-2 py-2"
            >
              <p className="text-lg font-semibold text-slate-900 dark:text-white">
                {followCounts.followerCount}
              </p>
              <p className="text-xs text-slate-500 dark:text-slate-400">Followers</p>
            </button>
            <button
              type="button"
              onClick={async () => {
                const ids = await getFollowing(user.uid);
                const profiles = await getUsersByIds(ids);
                setModalTitle("Following");
                setModalUsers(profiles);
              }}
              className="px-2 py-2"
            >
              <p className="text-lg font-semibold text-slate-900 dark:text-white">
                {followCounts.followingCount}
              </p>
              <p className="text-xs text-slate-500 dark:text-slate-400">Following</p>
            </button>
          </div>

          <p className="text-center text-xs text-slate-500 dark:text-slate-400">
            ❤️ {formatLikes(stats.totalLikes)} likes received
          </p>

          <div className="flex items-center justify-center gap-3">
            <button
              type="button"
              onClick={() => navigate("/edit-profile")}
              className="rounded-full border border-slate-200 px-5 py-2 text-sm font-semibold text-slate-700 transition-all duration-200 hover:scale-105 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-200"
            >
              Edit Profile
            </button>
            <button
              type="button"
              onClick={() => navigate("/settings")}
              className="flex h-10 w-10 items-center justify-center rounded-full border border-slate-200 text-lg text-slate-500 transition-all duration-200 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-300"
              aria-label="Settings"
            >
              ⚙️
            </button>
          </div>

          {isAdmin ? (
            <div className="flex items-center justify-center">
              <button
                type="button"
                onClick={() => navigate("/admin")}
                className="rounded-full border border-red-200 px-4 py-2 text-xs font-semibold text-red-500 transition-all duration-200 hover:border-red-300 hover:bg-red-50 dark:border-red-500/40 dark:hover:bg-red-500/10"
              >
                Admin Panel
              </button>
            </div>
          ) : null}

          <button
            type="button"
            onClick={async () => {
              await signOut();
              navigate("/login", { replace: true });
            }}
            className="mx-auto text-xs font-semibold text-red-500 hover:text-red-600"
          >
            Sign Out
          </button>

          <p className="text-center text-xs text-slate-400 dark:text-slate-500">
            Joined {joinedDate}
          </p>
        </section>
        )}

        {!loading ? (
        <section className="space-y-3">
          <div className="flex items-center justify-between">
            <h3 className="text-base font-semibold text-slate-900 dark:text-white">
              My Pets
            </h3>
            {pets.length < 5 ? (
              <button
                type="button"
                onClick={() => navigate("/add-pet")}
                className="text-xs font-semibold text-purple-600 transition-all duration-200 hover:text-purple-500"
              >
                Add Pet
              </button>
            ) : null}
          </div>

          {pets.length === 0 ? (
            <EmptyState
              icon="🐾"
              title="No pets added"
              description="Add your furry friend!"
              actionText="Add Pet"
              onAction={() => navigate("/add-pet")}
            />
          ) : (
            <div className="flex gap-4 overflow-x-auto pb-2">
              {pets.map((pet) => {
                const meta = getSpeciesMeta(pet.species);
                return (
                  <button
                    key={pet.id}
                    type="button"
                    onClick={() => navigate(`/pet/${pet.id}`)}
                    className="flex min-w-[90px] flex-col items-center text-center text-xs text-slate-600 dark:text-slate-300"
                  >
                    <div className={`rounded-full bg-gradient-to-r ${meta.gradient} p-0.5`}>
                      {pet.avatarUrl ? (
                        <img
                          src={pet.avatarUrl}
                          alt={pet.name}
                          className="h-14 w-14 rounded-full border-2 border-white object-cover dark:border-slate-800"
                        />
                      ) : (
                        <div className="flex h-14 w-14 items-center justify-center rounded-full border-2 border-white bg-white text-xl dark:border-slate-800 dark:bg-slate-900">
                          {meta.emoji}
                        </div>
                      )}
                    </div>
                    <span className="mt-2 font-semibold text-slate-900 dark:text-white">
                      {pet.name}
                    </span>
                    <span className="text-[11px] text-slate-400 dark:text-slate-500">
                      {pet.breed || meta.label}
                    </span>
                  </button>
                );
              })}

              {pets.length < 5 ? (
                <button
                  type="button"
                  onClick={() => navigate("/add-pet")}
                  className="flex min-w-[90px] flex-col items-center text-center text-xs text-slate-500 dark:text-slate-400"
                >
                  <div className="flex h-14 w-14 items-center justify-center rounded-full border-2 border-dashed border-slate-300 text-lg text-slate-400 dark:border-slate-600 dark:text-slate-500">
                    +
                  </div>
                  <span className="mt-2 text-[11px] text-slate-400 dark:text-slate-500">
                    Add Pet
                  </span>
                </button>
              ) : null}
            </div>
          )}
        </section>
        ) : null}

        {!loading ? (
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
              onClick={() => setActiveTab("saved")}
              className={`pb-2 text-sm font-semibold transition-all duration-200 ${
                activeTab === "saved"
                  ? "border-b-2 border-purple-500 text-slate-900 dark:text-white"
                  : "text-slate-400 hover:text-slate-600 dark:text-slate-500 dark:hover:text-slate-200"
              }`}
            >
              Saved
            </button>
          </div>

          {activeTab === "posts" && loading ? (
            <div className="grid grid-cols-3 gap-2">
              {[1, 2, 3].map((item) => (
                <div
                  key={item}
                  className="aspect-square animate-pulse rounded-2xl bg-slate-200 dark:bg-slate-700"
                />
              ))}
            </div>
          ) : activeTab === "posts" && posts.length === 0 && !pinnedPost ? (
            <EmptyState
              icon="📷"
              title="No posts yet"
              description="Share your first pet moment!"
              actionText="Create Post"
              onAction={() => navigate("/create")}
            />
          ) : activeTab === "posts" ? (
            <div className="space-y-4">
              {pinnedPost ? (
                <div className="relative rounded-2xl border border-purple-200 p-2 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] dark:border-purple-500/40">
                  <span className="absolute left-4 top-4 z-10 rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-2 py-0.5 text-[10px] font-semibold text-white">
                    📌 Pinned
                  </span>
                  <PostCard
                    post={pinnedPost}
                    onDeleted={(postId) => {
                      setPosts((prev) => prev.filter((item) => item.id !== postId));
                      setPinnedPost(null);
                    }}
                  />
                </div>
              ) : null}

              {gridPosts.length > 0 ? (
                <div className="grid grid-cols-3 gap-2">
                  {gridPosts.map((post) => {
                    const mediaList =
                      post.media && post.media.length > 0
                        ? post.media
                        : post.mediaUrl
                        ? [{ url: post.mediaUrl, type: post.mediaType || "image" }]
                        : [];
                    const first = mediaList[0];
                    const isMulti = mediaList.length > 1;
                    const isVideo = first?.type === "video";

                    return (
                      <div
                        key={post.id}
                        className="relative aspect-square overflow-hidden rounded-2xl bg-slate-100 dark:bg-slate-800"
                      >
                        <button
                          type="button"
                          onClick={() => navigate(`/post/${post.id}`)}
                          className="h-full w-full"
                        >
                          <img
                            src={first?.thumbUrl || first?.url || post.mediaUrl}
                            alt={post.text}
                            className="h-full w-full object-cover"
                          />
                        </button>
                        {isVideo ? (
                          <span className="absolute left-2 top-2 rounded bg-black/60 px-1.5 py-0.5 text-[10px] text-white">
                            ▶
                          </span>
                        ) : isMulti ? (
                          <span className="absolute left-2 top-2 rounded bg-black/60 px-1.5 py-0.5 text-[10px] text-white">
                            ⧉
                          </span>
                        ) : null}
                        <button
                          type="button"
                          onClick={() => setDeleteTarget(post)}
                          className="absolute right-2 top-2 flex h-7 w-7 items-center justify-center rounded-full bg-white/90 text-xs text-slate-600 shadow transition-all duration-200 hover:scale-105 hover:text-red-500 dark:bg-slate-800/90 dark:text-slate-200"
                          aria-label="Delete post"
                        >
                          ✕
                        </button>
                      </div>
                    );
                  })}
                </div>
              ) : null}
            </div>
          ) : savedLoading ? (
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
              title="No saved posts"
              description="Bookmark posts you love to find them later"
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
                return (
                  <button
                    key={post.id}
                    type="button"
                    onClick={() => navigate(`/post/${post.id}`)}
                    className="relative aspect-square overflow-hidden rounded-2xl bg-slate-100 dark:bg-slate-800"
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
        ) : null}
      </main>

      {deleteTarget ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-sm rounded-2xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)] dark:bg-slate-800">
            <h3 className="text-base font-semibold text-slate-900 dark:text-white">
              Delete Post
            </h3>
            <p className="mt-2 text-sm text-slate-600 dark:text-slate-300">
              Are you sure you want to delete this post? This action cannot be
              undone.
            </p>
            <div className="mt-5 flex items-center justify-end gap-3">
              <button
                type="button"
                onClick={() => setDeleteTarget(null)}
                className="rounded-full px-4 py-2 text-sm font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
              >
                Cancel
              </button>
              <button
                type="button"
                disabled={deleting}
                onClick={async () => {
                  if (!deleteTarget) return;
                  setDeleting(true);
                  await deletePost(deleteTarget.id);
                  if (pinnedPost?.id === deleteTarget.id) {
                    await unpinPost(user.uid);
                    setPinnedPost(null);
                  }
                  setPosts((prev) =>
                    prev.filter((item) => item.id !== deleteTarget.id)
                  );
                  const updatedStats = await getUserStats(user.uid);
                  setStats(updatedStats);
                  setDeleteTarget(null);
                  showToast("Post deleted", "success");
                  setDeleting(false);
                }}
                className="rounded-full bg-red-500 px-4 py-2 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
              >
                {deleting ? "Deleting..." : "Delete"}
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {modalTitle ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-md rounded-3xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)] dark:bg-slate-800">
            <div className="flex items-center justify-between">
              <h3 className="text-base font-semibold text-slate-900 dark:text-white">
                {modalTitle}
              </h3>
              <button
                type="button"
                onClick={() => {
                  setModalTitle(null);
                  setModalUsers([]);
                }}
                className="text-sm text-slate-500 hover:text-slate-700 dark:text-slate-300"
              >
                Close
              </button>
            </div>
            <div className="mt-4 space-y-3">
              {modalUsers.length === 0 ? (
                <p className="text-center text-sm text-slate-500 dark:text-slate-300">
                  No users yet
                </p>
              ) : (
                modalUsers.map((profile) => (
                  <UserCard
                    key={profile.id}
                    user={profile}
                    currentUid={user.uid}
                  />
                ))
              )}
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
