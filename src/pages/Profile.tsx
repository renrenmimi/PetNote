import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { UserCard } from "../components/UserCard";
import { getFollowers, getFollowing } from "../services/follow";
import { deletePost, getPostsByUser, getUserStats, type Post } from "../services/posts";
import { getUserProfile, getUsersByIds, type UserProfile } from "../services/users";

export function Profile() {
  const navigate = useNavigate();
  const { user, signOut } = useAuth();
  const [posts, setPosts] = useState<Post[]>([]);
  const [stats, setStats] = useState({ postCount: 0, totalLikes: 0 });
  const [loading, setLoading] = useState(true);
  const [selectedPost, setSelectedPost] = useState<Post | null>(null);
  const [profileName, setProfileName] = useState<string | null>(null);
  const [profileAvatar, setProfileAvatar] = useState<string | null>(null);
  const [profileBio, setProfileBio] = useState<string | null>(null);
  const [followCounts, setFollowCounts] = useState({
    followerCount: 0,
    followingCount: 0,
  });
  const [modalTitle, setModalTitle] = useState<string | null>(null);
  const [modalUsers, setModalUsers] = useState<UserProfile[]>([]);
  const [deleteTarget, setDeleteTarget] = useState<Post | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [toast, setToast] = useState<string | null>(null);

  useEffect(() => {
    let ignore = false;
    if (!user) return;

    const load = async () => {
      setLoading(true);
      try {
        const [postList, userStats, profile] = await Promise.all([
          getPostsByUser(user.uid),
          getUserStats(user.uid),
          getUserProfile(user.uid),
        ]);
        if (ignore) return;
        setPosts(postList);
        setStats(userStats);
        setProfileName(profile?.displayName || null);
        setProfileAvatar(profile?.avatarUrl || null);
        setProfileBio(profile?.bio || null);
        setFollowCounts({
          followerCount: profile?.followerCount ?? 0,
          followingCount: profile?.followingCount ?? 0,
        });
      } finally {
        if (!ignore) setLoading(false);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [user]);

  const joinedDate = useMemo(() => {
    const created = user?.metadata?.creationTime;
    if (!created) return "Unknown";
    return new Date(created).toLocaleDateString(undefined, {
      year: "numeric",
      month: "short",
      day: "numeric",
    });
  }, [user]);

  if (!user) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-white">
        <div className="text-center">
          <p className="text-sm text-slate-500">Please log in to view profile.</p>
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
          <h1 className="text-base font-semibold text-slate-900">Profile</h1>
          <div className="w-6" />
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-6 px-4 py-6">
        <section className="rounded-3xl bg-white p-6 shadow-sm ring-1 ring-slate-100">
          <div className="flex flex-col items-center text-center">
            <div className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 p-1">
              <img
                src={
                  profileAvatar ||
                  user.photoURL ||
                  "https://i.pravatar.cc/150?img=12"
                }
                alt={profileName || user.displayName || "User"}
                className="h-24 w-24 rounded-full border-4 border-white object-cover"
              />
            </div>
            <h2 className="mt-4 text-xl font-semibold text-slate-900">
              {profileName || user.displayName || "PetNote User"}
            </h2>
            <p className="text-sm text-slate-400">{user.email}</p>
            {profileBio ? (
              <p className="mt-2 text-sm text-slate-600">{profileBio}</p>
            ) : null}

            <div className="mt-4 flex w-full items-center justify-center gap-3">
              <button
                type="button"
                onClick={() => navigate("/edit-profile")}
                className="rounded-full border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-700 transition-all duration-200 hover:scale-105 hover:border-purple-300 hover:text-purple-600"
              >
                Edit Profile
              </button>
              <button
                type="button"
                onClick={async () => {
                  await signOut();
                  navigate("/login", { replace: true });
                }}
                className="rounded-full px-4 py-2 text-sm font-semibold text-red-500 transition-all duration-200 hover:scale-105 hover:bg-red-50"
              >
                Sign Out
              </button>
            </div>
          </div>

          <div className="mt-6 grid grid-cols-3 gap-4 text-center">
            <div>
              <p className="text-lg font-semibold text-slate-900">
                {stats.postCount}
              </p>
              <p className="text-xs text-slate-400">Posts</p>
            </div>
            <button
              type="button"
              onClick={async () => {
                const ids = await getFollowers(user.uid);
                const profiles = await getUsersByIds(ids);
                setModalTitle("Followers");
                setModalUsers(profiles);
              }}
            >
              <p className="text-lg font-semibold text-slate-900">
                {followCounts.followerCount}
              </p>
              <p className="text-xs text-slate-400">Followers</p>
            </button>
            <button
              type="button"
              onClick={async () => {
                const ids = await getFollowing(user.uid);
                const profiles = await getUsersByIds(ids);
                setModalTitle("Following");
                setModalUsers(profiles);
              }}
            >
              <p className="text-lg font-semibold text-slate-900">
                {followCounts.followingCount}
              </p>
              <p className="text-xs text-slate-400">Following</p>
            </button>
          </div>
          <div className="mt-4 grid grid-cols-2 gap-4 text-center">
            <div>
              <p className="text-lg font-semibold text-slate-900">
                {stats.totalLikes}
              </p>
              <p className="text-xs text-slate-400">Likes</p>
            </div>
            <div>
              <p className="text-lg font-semibold text-slate-900">
                {joinedDate}
              </p>
              <p className="text-xs text-slate-400">Joined</p>
            </div>
          </div>
        </section>

        <section className="space-y-3">
          <div className="flex items-center justify-between">
            <h3 className="text-base font-semibold text-slate-900">My Posts</h3>
          </div>

          {loading ? (
            <div className="grid grid-cols-3 gap-2">
              {[1, 2, 3].map((item) => (
                <div
                  key={item}
                  className="aspect-square animate-pulse rounded-2xl bg-slate-200"
                />
              ))}
            </div>
          ) : posts.length === 0 ? (
            <div className="rounded-2xl border border-slate-100 bg-slate-50 p-6 text-center text-sm text-slate-500">
              No posts yet
            </div>
          ) : (
            <div className="grid grid-cols-3 gap-2">
              {posts.map((post) => (
                <div
                  key={post.id}
                  className="relative aspect-square overflow-hidden rounded-2xl bg-slate-100"
                >
                  <button
                    type="button"
                    onClick={() => setSelectedPost(post)}
                    className="h-full w-full"
                  >
                    <img
                      src={post.mediaUrl}
                      alt={post.text}
                      className="h-full w-full object-cover"
                    />
                  </button>
                  <button
                    type="button"
                    onClick={() => setDeleteTarget(post)}
                    className="absolute right-2 top-2 flex h-7 w-7 items-center justify-center rounded-full bg-white/90 text-xs text-slate-600 shadow transition-all duration-200 hover:scale-105 hover:text-red-500"
                    aria-label="Delete post"
                  >
                    ✕
                  </button>
                </div>
              ))}
            </div>
          )}
        </section>
      </main>

      {selectedPost ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4">
          <div className="relative w-full max-w-md overflow-hidden rounded-3xl bg-white">
            <button
              type="button"
              onClick={() => setSelectedPost(null)}
              className="absolute right-4 top-4 rounded-full bg-white/90 px-3 py-1 text-sm text-slate-600 shadow"
            >
              Close
            </button>
            <img
              src={selectedPost.mediaUrl}
              alt={selectedPost.text}
              className="h-full w-full object-cover"
            />
            <div className="p-4 text-sm text-slate-700">
              <span className="font-semibold text-slate-900">
                {selectedPost.authorName}
              </span>{" "}
              {selectedPost.text}
            </div>
          </div>
        </div>
      ) : null}

      {deleteTarget ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-sm rounded-2xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)]">
            <h3 className="text-base font-semibold text-slate-900">
              Delete Post
            </h3>
            <p className="mt-2 text-sm text-slate-600">
              Are you sure you want to delete this post? This action cannot be
              undone.
            </p>
            <div className="mt-5 flex items-center justify-end gap-3">
              <button
                type="button"
                onClick={() => setDeleteTarget(null)}
                className="rounded-full px-4 py-2 text-sm font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-100"
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
                  setPosts((prev) =>
                    prev.filter((item) => item.id !== deleteTarget.id)
                  );
                  const updatedStats = await getUserStats(user.uid);
                  setStats(updatedStats);
                  setDeleteTarget(null);
                  setToast("Post deleted");
                  setTimeout(() => setToast(null), 2000);
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

      {toast ? (
        <div className="fixed bottom-6 left-1/2 z-50 -translate-x-1/2 rounded-full bg-emerald-500 px-4 py-2 text-sm font-semibold text-white shadow-lg">
          {toast}
        </div>
      ) : null}

      {modalTitle ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-md rounded-3xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)]">
            <div className="flex items-center justify-between">
              <h3 className="text-base font-semibold text-slate-900">
                {modalTitle}
              </h3>
              <button
                type="button"
                onClick={() => {
                  setModalTitle(null);
                  setModalUsers([]);
                }}
                className="text-sm text-slate-500 hover:text-slate-700"
              >
                Close
              </button>
            </div>
            <div className="mt-4 space-y-3">
              {modalUsers.length === 0 ? (
                <p className="text-center text-sm text-slate-500">
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
