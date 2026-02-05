import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { getPostsByUser, getUserStats, type Post } from "../services/posts";
import { getUserProfile } from "../services/users";

export function Profile() {
  const navigate = useNavigate();
  const { user, signOut } = useAuth();
  const [posts, setPosts] = useState<Post[]>([]);
  const [stats, setStats] = useState({ postCount: 0, totalLikes: 0 });
  const [loading, setLoading] = useState(true);
  const [selectedPost, setSelectedPost] = useState<Post | null>(null);
  const [profileName, setProfileName] = useState<string | null>(null);

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
                src={user.photoURL || "https://i.pravatar.cc/150?img=12"}
                alt={user.displayName || "User"}
                className="h-24 w-24 rounded-full border-4 border-white object-cover"
              />
            </div>
            <h2 className="mt-4 text-xl font-semibold text-slate-900">
              {profileName || user.displayName || "PetNote User"}
            </h2>
            <p className="text-sm text-slate-400">{user.email}</p>

            <div className="mt-4 flex w-full items-center justify-center gap-3">
              <button
                type="button"
                className="rounded-full border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-700 hover:border-purple-300 hover:text-purple-600"
              >
                Edit Profile
              </button>
              <button
                type="button"
                onClick={async () => {
                  await signOut();
                  navigate("/login", { replace: true });
                }}
                className="rounded-full px-4 py-2 text-sm font-semibold text-red-500 hover:bg-red-50"
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
                <button
                  key={post.id}
                  type="button"
                  onClick={() => setSelectedPost(post)}
                  className="aspect-square overflow-hidden rounded-2xl bg-slate-100"
                >
                  <img
                    src={post.mediaUrl}
                    alt={post.text}
                    className="h-full w-full object-cover"
                  />
                </button>
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
    </div>
  );
}
