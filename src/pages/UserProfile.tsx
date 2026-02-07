import { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { PostCard } from "../components/PostCard";
import { UserCard } from "../components/UserCard";
import Avatar from "../components/Avatar";
import { useAuth } from "../hooks/useAuth";
import { useBlockedUsers } from "../hooks/useBlockedUsers";
import { unblockUser } from "../services/block";
import { useFollow } from "../hooks/useFollow";
import { getFollowers, getFollowing } from "../services/follow";
import { getPostById, getPostsByUser, getUserStats, type Post } from "../services/posts";
import { getUserProfile, getUsersByIds, type UserProfile } from "../services/users";

export function UserProfile() {
  const navigate = useNavigate();
  const { userId } = useParams();
  const { user } = useAuth();
  const { isBlocked } = useBlockedUsers(user?.uid ?? null);
  const [profile, setProfile] = useState<UserProfile | null>(null);
  const [posts, setPosts] = useState<Post[]>([]);
  const [pinnedPost, setPinnedPost] = useState<Post | null>(null);
  const [stats, setStats] = useState({ postCount: 0, totalLikes: 0 });
  const [loading, setLoading] = useState(true);
  const [modalTitle, setModalTitle] = useState<string | null>(null);
  const [modalUsers, setModalUsers] = useState<UserProfile[]>([]);

  const { isFollowing, toggleFollow, followerCount } = useFollow(userId ?? "");

  useEffect(() => {
    let ignore = false;
    if (!userId) return;

    const load = async () => {
      setLoading(true);
      try {
        const [postList, userStats, profileData] = await Promise.all([
          getPostsByUser(userId),
          getUserStats(userId),
          getUserProfile(userId),
        ]);
        if (ignore) return;
        setPosts(postList);
        setStats(userStats);
        setProfile(profileData);
        if (profileData?.pinnedPostId) {
          const pinned =
            postList.find((item) => item.id === profileData.pinnedPostId) ??
            (await getPostById(profileData.pinnedPostId));
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
  }, [userId]);

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
  const gridPosts = useMemo(() => {
    if (!pinnedPost) return posts;
    return posts.filter((post) => post.id !== pinnedPost.id);
  }, [pinnedPost, posts]);

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
              Unblock to view their profile and posts again.
            </p>
            <button
              type="button"
              onClick={async () => {
                if (!user) return;
                await unblockUser(user.uid, userId);
              }}
              className="mt-4 rounded-full border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-700 transition-all duration-200 hover:scale-105 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-200"
            >
              Unblock
            </button>
          </section>
        ) : null}

        {!blocked ? (
        <section className="rounded-3xl bg-white p-6 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <div className="flex flex-col items-center text-center">
            <div className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 p-1">
              <Avatar
                src={profile?.avatarUrl || undefined}
                alt={profile?.displayName || "User"}
                userId={profile?.id}
                size={96}
                className="h-24 w-24 border-4 border-white dark:border-slate-800"
              />
            </div>
            <h2 className="mt-4 text-xl font-semibold text-slate-900 dark:text-white">
              {profile?.displayName || "PetNote User"}
            </h2>
            <p className="text-sm text-slate-400 dark:text-slate-500">{profile?.email}</p>

            {user?.uid !== userId ? (
              <div className="mt-4">
                <button
                  type="button"
                  onClick={toggleFollow}
                  className={`rounded-full px-6 py-2 text-sm font-semibold transition-all duration-200 hover:scale-105 ${
                    isFollowing
                      ? "border border-slate-200 text-slate-500 dark:border-slate-700 dark:text-slate-300"
                      : "bg-gradient-to-r from-purple-500 to-pink-500 text-white shadow-[0_10px_25px_-15px_rgba(168,85,247,0.7)]"
                  }`}
                >
                  {isFollowing ? "Following" : "Follow"}
                </button>
              </div>
            ) : null}
          </div>

          <div className="mt-6 grid grid-cols-3 gap-4 text-center">
            <div>
              <p className="text-lg font-semibold text-slate-900 dark:text-white">
                {stats.postCount}
              </p>
              <p className="text-xs text-slate-400 dark:text-slate-500">Posts</p>
            </div>
            <button
              type="button"
              onClick={async () => {
                const ids = await getFollowers(userId);
                const profiles = await getUsersByIds(ids);
                setModalTitle("Followers");
                setModalUsers(profiles);
              }}
            >
              <p className="text-lg font-semibold text-slate-900 dark:text-white">
                {followerCount}
              </p>
              <p className="text-xs text-slate-400 dark:text-slate-500">Followers</p>
            </button>
            <button
              type="button"
              onClick={async () => {
                const ids = await getFollowing(userId);
                const profiles = await getUsersByIds(ids);
                setModalTitle("Following");
                setModalUsers(profiles);
              }}
            >
              <p className="text-lg font-semibold text-slate-900 dark:text-white">
                {profile?.followingCount ?? 0}
              </p>
              <p className="text-xs text-slate-400 dark:text-slate-500">Following</p>
            </button>
          </div>
          <div className="mt-4 grid grid-cols-2 gap-4 text-center">
            <div>
              <p className="text-lg font-semibold text-slate-900 dark:text-white">
                {stats.totalLikes}
              </p>
              <p className="text-xs text-slate-400 dark:text-slate-500">Likes</p>
            </div>
            <div>
              <p className="text-lg font-semibold text-slate-900 dark:text-white">
                {joinedDate}
              </p>
              <p className="text-xs text-slate-400 dark:text-slate-500">Joined</p>
            </div>
          </div>
        </section>
        ) : null}

        {!blocked ? (
          <section className="space-y-3">
            <div className="flex items-center justify-between">
              <h3 className="text-base font-semibold text-slate-900 dark:text-white">
                Posts
              </h3>
            </div>

            {loading ? (
              <div className="grid grid-cols-3 gap-2">
                {[1, 2, 3].map((item) => (
                  <div
                    key={item}
                    className="aspect-square animate-pulse rounded-2xl bg-slate-200 dark:bg-slate-700"
                  />
                ))}
              </div>
            ) : posts.length === 0 && !pinnedPost ? (
              <div className="rounded-2xl border border-slate-100 bg-slate-50 p-6 text-center text-sm text-slate-500 dark:border-slate-700 dark:bg-slate-800 dark:text-slate-300">
                No posts yet
              </div>
            ) : (
              <div className="space-y-4">
                {pinnedPost ? (
                  <div className="relative rounded-2xl border border-purple-200 p-2 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] dark:border-purple-500/40">
                    <span className="absolute left-4 top-4 z-10 rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-2 py-0.5 text-[10px] font-semibold text-white">
                      📌 Pinned
                    </span>
                    <PostCard post={pinnedPost} />
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
                ) : null}
              </div>
            )}
          </section>
        ) : null}
      </main>

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
                modalUsers.map((profileItem) => (
                  <UserCard
                    key={profileItem.id}
                    user={profileItem}
                    currentUid={user?.uid ?? null}
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
