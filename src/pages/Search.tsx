import { useEffect, useMemo, useState } from "react";
import { BottomNav } from "../components/BottomNav";
import { Navbar } from "../components/Navbar";
import { PostCard } from "../components/PostCard";
import { UserCard } from "../components/UserCard";
import { useAuth } from "../hooks/useAuth";
import {
  getTrendingTags,
  searchByTag,
  searchByText,
  searchUsers,
} from "../services/search";
import { type Post } from "../services/posts";
import { type UserProfile } from "../services/users";

export function Search() {
  const { user } = useAuth();
  const [query, setQuery] = useState("");
  const [posts, setPosts] = useState<Post[]>([]);
  const [users, setUsers] = useState<UserProfile[]>([]);
  const [loading, setLoading] = useState(false);
  const [trendingTags, setTrendingTags] = useState<string[]>([]);

  const normalizedQuery = useMemo(() => query.trim(), [query]);

  useEffect(() => {
    let ignore = false;
    const loadTags = async () => {
      const tags = await getTrendingTags();
      if (!ignore) setTrendingTags(tags);
    };
    void loadTags();
    return () => {
      ignore = true;
    };
  }, []);

  useEffect(() => {
    if (!normalizedQuery) {
      setPosts([]);
      setUsers([]);
      return;
    }

    const handle = window.setTimeout(async () => {
      setLoading(true);
      const keyword = normalizedQuery.startsWith("#")
        ? normalizedQuery.slice(1)
        : normalizedQuery;

      try {
        if (normalizedQuery.startsWith("#")) {
          const results = await searchByTag(keyword.toLowerCase());
          setPosts(results);
          setUsers([]);
        } else {
          const [postResults, userResults] = await Promise.all([
            searchByText(keyword),
            searchUsers(keyword),
          ]);
          setPosts(postResults);
          setUsers(userResults);
        }
      } finally {
        setLoading(false);
      }
    }, 300);

    return () => window.clearTimeout(handle);
  }, [normalizedQuery]);

  const hasResults = posts.length > 0 || users.length > 0;

  return (
    <div className="min-h-screen bg-slate-50 pb-20">
      <Navbar />

      <main className="mx-auto w-full max-w-md space-y-4 px-4 py-4">
        <div className="rounded-2xl bg-white px-4 py-3 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100">
          <div className="flex items-center gap-2">
            <span className="text-lg">🔍</span>
            <input
              type="text"
              placeholder="Search pets, tags, users..."
              className="flex-1 bg-transparent text-sm text-slate-700 outline-none placeholder:text-slate-400"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
            {query ? (
              <button
                type="button"
                onClick={() => setQuery("")}
                className="text-sm text-slate-400 transition-all duration-200 hover:text-purple-500"
              >
                ✕
              </button>
            ) : null}
          </div>
        </div>

        <section className="rounded-2xl bg-white px-4 py-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100">
          <div className="flex items-center justify-between">
            <h2 className="text-sm font-semibold text-slate-900">
              Trending Tags 🔥
            </h2>
          </div>
          <div className="mt-3 flex flex-wrap gap-2">
            {trendingTags.map((tag) => (
              <button
                key={tag}
                type="button"
                onClick={() => setQuery(`#${tag}`)}
                className="rounded-full bg-purple-50 px-3 py-1 text-xs font-semibold text-purple-600 transition-all duration-200 hover:scale-105 hover:bg-purple-100"
              >
                #{tag}
              </button>
            ))}
          </div>
        </section>

        {loading ? (
          <div className="rounded-2xl bg-white p-6 text-center text-sm text-slate-400 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)]">
            Searching...
          </div>
        ) : null}

        {!loading && normalizedQuery && !hasResults ? (
          <div className="rounded-2xl bg-white p-6 text-center text-sm text-slate-500 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)]">
            No results found for "{normalizedQuery}"
          </div>
        ) : null}

        {users.length > 0 ? (
          <section className="space-y-2">
            <h3 className="text-sm font-semibold text-slate-900">Users</h3>
            <div className="space-y-3">
              {users.map((profile) => (
                <UserCard
                  key={profile.id}
                  user={profile}
                  currentUid={user?.uid ?? null}
                />
              ))}
            </div>
          </section>
        ) : null}

        {posts.length > 0 ? (
          <section className="space-y-3">
            <h3 className="text-sm font-semibold text-slate-900">Posts</h3>
            <div className="grid gap-4 sm:grid-cols-2">
              {posts.map((post) => (
                <PostCard key={post.id} post={post} />
              ))}
            </div>
          </section>
        ) : null}
      </main>

      <BottomNav />
    </div>
  );
}
