import { useEffect, useMemo, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { BottomNav } from "../components/BottomNav";
import { Navbar } from "../components/Navbar";
import { PostCard } from "../components/PostCard";
import { UserCard } from "../components/UserCard";
import { EmptyState } from "../components/EmptyState";
import { SkeletonPostCard } from "../components/SkeletonPostCard";
import { useAuth } from "../hooks/useAuth";
import { useBlockedUsers } from "../hooks/useBlockedUsers";
import {
  getPostsByTag,
  getTrendingTags,
  searchTags,
  type Hashtag,
} from "../services/hashtags";
import { searchByText, searchUsers } from "../services/search";
import { type Post } from "../services/posts";
import { type UserProfile } from "../services/users";

export function Search() {
  const { user } = useAuth();
  const [searchParams, setSearchParams] = useSearchParams();
  const [query, setQuery] = useState("");
  const [posts, setPosts] = useState<Post[]>([]);
  const [users, setUsers] = useState<UserProfile[]>([]);
  const [loading, setLoading] = useState(false);
  const [trendingTags, setTrendingTags] = useState<Hashtag[]>([]);
  const [tagResults, setTagResults] = useState<Hashtag[]>([]);
  const [selectedTag, setSelectedTag] = useState<Hashtag | null>(null);
  const { blockedUserIds } = useBlockedUsers(user?.uid ?? null);

  const normalizedQuery = useMemo(() => query.trim(), [query]);

  useEffect(() => {
    let ignore = false;
    const loadTags = async () => {
      const tags = await getTrendingTags(8);
      if (!ignore) setTrendingTags(tags);
    };
    void loadTags();
    return () => {
      ignore = true;
    };
  }, []);

  useEffect(() => {
    const tagParam = searchParams.get("tag");
    if (tagParam) {
      setQuery(`#${tagParam}`);
      setSelectedTag({ name: tagParam, postCount: 0, lastUsed: null });
    }
  }, [searchParams]);

  useEffect(() => {
    if (!normalizedQuery) {
      setPosts([]);
      setUsers([]);
      setTagResults([]);
      setSelectedTag(null);
      return;
    }

    const handle = window.setTimeout(async () => {
      setLoading(true);
      const keyword = normalizedQuery.replace(/^#/, "").toLowerCase();

      try {
        const tags = await searchTags(keyword);
        setTagResults(tags);
        const exactTag = tags.find((tag) => tag.name === keyword);

        if (normalizedQuery.startsWith("#") || exactTag) {
          const postsByTag = await getPostsByTag(keyword);
          setSelectedTag(
            exactTag ?? { name: keyword, postCount: postsByTag.length, lastUsed: null }
          );
          setPosts(postsByTag);
          setUsers([]);
        } else {
          setSelectedTag(null);
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

  const filteredPosts = useMemo(
    () => posts.filter((post) => !blockedUserIds.includes(post.authorId)),
    [blockedUserIds, posts]
  );
  const hasResults = filteredPosts.length > 0 || users.length > 0;

  return (
    <div className="min-h-screen bg-slate-50 pb-20 dark:bg-slate-900">
      <Navbar />

      <main className="mx-auto w-full max-w-md space-y-4 px-4 py-4">
        <div className="rounded-2xl bg-white px-4 py-3 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <div className="flex items-center gap-2">
            <span className="text-lg">🔍</span>
            <input
              type="text"
              placeholder="Search pets, tags, users..."
              className="flex-1 bg-transparent text-sm text-slate-700 outline-none placeholder:text-slate-400 dark:text-slate-200 dark:placeholder:text-slate-500"
              value={query}
              onChange={(event) => {
                const next = event.target.value;
                setQuery(next);
                if (next.startsWith("#")) {
                  const tagName = next.replace(/^#/, "");
                  setSearchParams(tagName ? { tag: tagName } : {});
                } else {
                  setSearchParams({});
                }
              }}
            />
            {query ? (
              <button
                type="button"
                onClick={() => setQuery("")}
                className="text-sm text-slate-400 transition-all duration-200 hover:text-purple-500 dark:text-slate-500"
              >
                ✕
              </button>
            ) : null}
          </div>
        </div>

        <section className="rounded-2xl bg-white px-4 py-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <div className="flex items-center justify-between">
            <h2 className="text-sm font-semibold text-slate-900 dark:text-white">
              Trending Tags 🔥
            </h2>
          </div>
          <div className="mt-3 flex flex-wrap gap-2">
            {trendingTags.map((tag) => (
              <button
                key={tag.name}
                type="button"
                onClick={() => {
                  setQuery(`#${tag.name}`);
                  setSearchParams({ tag: tag.name });
                }}
                className="rounded-full bg-gradient-to-r from-purple-100 to-pink-100 px-3 py-1 text-xs font-semibold text-purple-600 transition-all duration-200 hover:scale-105 dark:from-purple-500/20 dark:to-pink-500/20 dark:text-purple-200"
              >
                #{tag.name}
              </button>
            ))}
          </div>
        </section>

        {tagResults.length > 0 && !selectedTag ? (
          <section className="rounded-2xl bg-white px-4 py-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
            <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
              Tags
            </h3>
            <div className="mt-3 space-y-2">
              {tagResults.map((tag) => (
                <button
                  key={tag.name}
                  type="button"
                  onClick={() => {
                    setQuery(`#${tag.name}`);
                    setSearchParams({ tag: tag.name });
                  }}
                  className="flex w-full items-center justify-between rounded-xl bg-slate-50 px-3 py-2 text-left text-sm text-slate-700 transition-all duration-200 hover:scale-[1.01] dark:bg-slate-900/40 dark:text-slate-200"
                >
                  <span className="font-semibold text-purple-600">
                    #{tag.name}
                  </span>
                  <span className="text-xs text-slate-400 dark:text-slate-500">
                    {tag.postCount} posts
                  </span>
                </button>
              ))}
            </div>
          </section>
        ) : null}

        {loading ? (
          <div className="space-y-4">
            {[1, 2, 3].map((item) => (
              <SkeletonPostCard key={item} />
            ))}
          </div>
        ) : null}

        {!loading && normalizedQuery && !hasResults ? (
          <EmptyState
            icon="🔍"
            title="No results found"
            description="Try different keywords or tags"
          />
        ) : null}

        {selectedTag ? (
          <div className="rounded-2xl bg-white px-4 py-3 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] dark:bg-slate-800">
            <h3 className="text-base font-semibold text-slate-900 dark:text-white">
              #{selectedTag.name} · {selectedTag.postCount || filteredPosts.length} posts
            </h3>
          </div>
        ) : null}

        {users.length > 0 ? (
          <section className="space-y-2">
            <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
              Users
            </h3>
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

        {filteredPosts.length > 0 ? (
          <section className="space-y-3">
            <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
              Posts
            </h3>
            <div className="grid gap-4 sm:grid-cols-2">
              {filteredPosts.map((post) => (
                <PostCard
                  key={post.id}
                  post={post}
                  onDeleted={(postId) =>
                    setPosts((prev) => prev.filter((item) => item.id !== postId))
                  }
                />
              ))}
            </div>
          </section>
        ) : null}
      </main>

      <BottomNav />
    </div>
  );
}
