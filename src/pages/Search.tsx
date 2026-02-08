import { useEffect, useMemo, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { BottomNav } from "../components/BottomNav";
import { Navbar } from "../components/Navbar";
import { PostCard } from "../components/PostCard";
import { UserCard } from "../components/UserCard";
import { EmptyState } from "../components/EmptyState";
import { SkeletonPostCard } from "../components/SkeletonPostCard";
import Avatar from "../components/Avatar";
import { useAuth } from "../hooks/useAuth";
import { useBlockedUsers } from "../hooks/useBlockedUsers";
import {
  getPostsByTag,
  getTrendingTags,
  searchTags,
  type Hashtag,
} from "../services/hashtags";
import { searchUsers, searchPets } from "../services/search";
import {
  getPopularPets,
  getSuggestedUsers,
  getTopRatedPlaces,
  getTrendingPosts,
  getUpcomingMeetupPreview,
} from "../services/explore";
import { type Post } from "../services/posts";
import { type UserProfile } from "../services/users";
import { type Pet } from "../services/pets";
import { type Location } from "../services/locations";
import { type Meetup } from "../services/meetups";
import { useFollow } from "../hooks/useFollow";
import { timeAgo } from "../utils/timeAgo";

type SearchTab = "explore" | "tags" | "people" | "pets";

type PopularPet = Pet & { postCount: number };

const petSpeciesEmoji: Record<string, string> = {
  dog: "🐕",
  cat: "🐱",
  bird: "🐦",
  rabbit: "🐰",
  hamster: "🐹",
  fish: "🐠",
  reptile: "🦎",
  other: "🐾",
};

function SuggestedUserCard({ user, currentUid }: { user: UserProfile; currentUid: string | null }) {
  const { isFollowing, toggleFollow, loading } = useFollow(user.id);
  const navigate = useNavigate();
  const isSelf = user.id === currentUid;

  return (
    <div className="min-w-[140px] rounded-2xl bg-white p-3 text-center shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
      <button
        type="button"
        onClick={() => navigate(`/profile/${user.id}`)}
        className="flex w-full flex-col items-center gap-2"
      >
        <Avatar
          src={user.avatarUrl || undefined}
          alt={user.displayName || "User"}
          userId={user.id}
          size={56}
          className="h-14 w-14"
        />
        <div>
          <p className="text-xs font-semibold text-slate-900 dark:text-white">
            {user.displayName || "PetNote User"}
          </p>
          <p className="text-[10px] text-slate-400 dark:text-slate-500">
            {user.followerCount || 0} followers
          </p>
        </div>
      </button>
      {!isSelf ? (
        <button
          type="button"
          onClick={toggleFollow}
          disabled={loading}
          className={`mt-2 w-full rounded-full px-3 py-1 text-[11px] font-semibold transition-all duration-200 hover:scale-105 ${
            isFollowing
              ? "border border-slate-200 text-slate-500 dark:border-slate-700 dark:text-slate-300"
              : "bg-gradient-to-r from-purple-500 to-pink-500 text-white"
          }`}
        >
          {isFollowing ? "Following" : "Follow"}
        </button>
      ) : null}
    </div>
  );
}

function PetResultCard({ pet }: { pet: Pet }) {
  const navigate = useNavigate();
  const emoji = petSpeciesEmoji[pet.species] || "🐾";
  return (
    <button
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
      <div>
        <p className="text-sm font-semibold text-slate-900 dark:text-white">
          {pet.name} {emoji}
        </p>
        <p className="text-xs text-slate-400 dark:text-slate-500">
          {pet.breed || "Pet friend"}
        </p>
      </div>
    </button>
  );
}

export function Search() {
  const { user } = useAuth();
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const [tab, setTab] = useState<SearchTab>("explore");
  const [query, setQuery] = useState("");
  const [posts, setPosts] = useState<Post[]>([]);
  const [users, setUsers] = useState<UserProfile[]>([]);
  const [pets, setPets] = useState<Pet[]>([]);
  const [loading, setLoading] = useState(false);
  const [trendingTags, setTrendingTags] = useState<Hashtag[]>([]);
  const [tagResults, setTagResults] = useState<Hashtag[]>([]);
  const [selectedTag, setSelectedTag] = useState<Hashtag | null>(null);
  const [trendingPosts, setTrendingPosts] = useState<Post[]>([]);
  const [suggestedUsers, setSuggestedUsers] = useState<UserProfile[]>([]);
  const [popularPets, setPopularPets] = useState<PopularPet[]>([]);
  const [topPlaces, setTopPlaces] = useState<Location[]>([]);
  const [upcomingMeetups, setUpcomingMeetups] = useState<Meetup[]>([]);
  const [exploreLoading, setExploreLoading] = useState(false);
  const { blockedUserIds } = useBlockedUsers(user?.uid ?? null);

  const normalizedQuery = useMemo(() => query.trim(), [query]);
  const hasQuery = normalizedQuery.length > 0;

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
      setTab("tags");
    }
  }, [searchParams]);

  useEffect(() => {
    if (!hasQuery) {
      setTab("explore");
      setPosts([]);
      setUsers([]);
      setPets([]);
      setTagResults([]);
      setSelectedTag(null);
      return;
    }

    if (normalizedQuery.startsWith("#")) {
      setTab("tags");
    } else if (tab === "explore") {
      setTab("people");
    }
  }, [hasQuery, normalizedQuery, tab]);

  useEffect(() => {
    if (!hasQuery) return;
    const handle = window.setTimeout(async () => {
      setLoading(true);
      const keyword = normalizedQuery.replace(/^#/, "").toLowerCase();

      try {
        if (tab === "tags") {
          const tags = await searchTags(keyword);
          setTagResults(tags);
          const exactTag = tags.find((tag) => tag.name === keyword);
          if (normalizedQuery.startsWith("#") || exactTag) {
            const postsByTag = await getPostsByTag(keyword);
            setSelectedTag(
              exactTag ?? { name: keyword, postCount: postsByTag.length, lastUsed: null }
            );
            setPosts(postsByTag);
          } else {
            setSelectedTag(null);
            setPosts([]);
          }
          setUsers([]);
          setPets([]);
        } else if (tab === "people") {
          const userResults = await searchUsers(keyword);
          setUsers(userResults);
          setPosts([]);
          setPets([]);
          setSelectedTag(null);
        } else if (tab === "pets") {
          const petResults = await searchPets(keyword);
          setPets(petResults);
          setPosts([]);
          setUsers([]);
          setSelectedTag(null);
        }
      } finally {
        setLoading(false);
      }
    }, 300);

    return () => window.clearTimeout(handle);
  }, [normalizedQuery, tab, hasQuery]);

  useEffect(() => {
    if (tab !== "explore" || hasQuery) return;
    let ignore = false;
    const loadExplore = async () => {
      setExploreLoading(true);
      try {
        const [trending, suggested, popular, places, meetups] = await Promise.all([
          getTrendingPosts(6),
          user ? getSuggestedUsers(user.uid, 8) : getSuggestedUsers("", 8),
          getPopularPets(8),
          getTopRatedPlaces(5),
          getUpcomingMeetupPreview(3),
        ]);
        if (!ignore) {
          setTrendingPosts(trending);
          setSuggestedUsers(suggested);
          setPopularPets(popular);
          setTopPlaces(places);
          setUpcomingMeetups(meetups);
        }
      } finally {
        if (!ignore) setExploreLoading(false);
      }
    };
    void loadExplore();
    return () => {
      ignore = true;
    };
  }, [tab, hasQuery, user]);

  const filteredPosts = useMemo(
    () => posts.filter((post) => !blockedUserIds.includes(post.authorId)),
    [blockedUserIds, posts]
  );
  const filteredTrending = useMemo(
    () => trendingPosts.filter((post) => !blockedUserIds.includes(post.authorId)),
    [blockedUserIds, trendingPosts]
  );

  const hasResults =
    filteredPosts.length > 0 || users.length > 0 || pets.length > 0;

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

        <div className="flex items-center gap-4 border-b border-slate-200 text-sm dark:border-slate-800">
          {([
            { key: "explore", label: "Explore" },
            { key: "tags", label: "Tags" },
            { key: "people", label: "People" },
            { key: "pets", label: "Pets" },
          ] as const).map((item) => (
            <button
              key={item.key}
              type="button"
              onClick={() => setTab(item.key)}
              className={`pb-2 text-sm font-semibold transition-all duration-200 ${
                tab === item.key
                  ? "text-slate-900 dark:text-white"
                  : "text-slate-400 dark:text-slate-500"
              }`}
            >
              {item.label}
              {tab === item.key ? (
                <span className="mt-2 block h-0.5 w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500" />
              ) : null}
            </button>
          ))}
        </div>

        {tab === "explore" && !hasQuery ? (
          <div className="space-y-5">
            <section className="rounded-2xl bg-white px-4 py-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
              <h2 className="text-sm font-semibold text-slate-900 dark:text-white">
                Trending Tags 🔥
              </h2>
              <div className="mt-3 flex flex-wrap gap-2">
                {trendingTags.map((tag) => (
                  <button
                    key={tag.name}
                    type="button"
                    onClick={() => {
                      setQuery(`#${tag.name}`);
                      setSearchParams({ tag: tag.name });
                      setTab("tags");
                    }}
                    className="rounded-full bg-gradient-to-r from-purple-100 to-pink-100 px-3 py-1 text-xs font-semibold text-purple-600 transition-all duration-200 hover:scale-105 dark:from-purple-500/20 dark:to-pink-500/20 dark:text-purple-200"
                  >
                    #{tag.name}
                  </button>
                ))}
              </div>
            </section>

            <section>
              <div className="flex items-center justify-between">
                <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
                  🔥 Trending Posts
                </h3>
              </div>
              {exploreLoading ? (
                <div className="mt-3 grid grid-cols-3 gap-1">
                  {[1, 2, 3, 4, 5, 6].map((item) => (
                    <div
                      key={item}
                      className="aspect-square animate-pulse rounded-lg bg-slate-200 dark:bg-slate-700"
                    />
                  ))}
                </div>
              ) : (
                <div className="mt-3 grid grid-cols-3 gap-1">
                  {filteredTrending.map((post) => {
                    const media = post.media?.[0] ||
                      (post.mediaUrl
                        ? { url: post.mediaUrl, type: post.mediaType || "image" }
                        : null);
                    return (
                      <button
                        key={post.id}
                        type="button"
                        onClick={() => navigate(`/post/${post.id}`)}
                        className="relative aspect-square overflow-hidden rounded-lg bg-slate-100"
                      >
                        {media ? (
                          <img
                            src={media.url}
                            alt={post.text}
                            className="h-full w-full object-cover"
                          />
                        ) : null}
                        {post.media?.length && post.media.length > 1 ? (
                          <span className="absolute right-2 top-2 rounded-full bg-black/60 px-1.5 py-0.5 text-[10px] text-white">
                            📚
                          </span>
                        ) : null}
                        {media?.type === "video" ? (
                          <span className="absolute right-2 top-2 rounded-full bg-black/60 px-1.5 py-0.5 text-[10px] text-white">
                            ▶
                          </span>
                        ) : null}
                      </button>
                    );
                  })}
                </div>
              )}
            </section>

            <section>
              <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
                👥 Suggested for You
              </h3>
              <div className="mt-3 flex gap-3 overflow-x-auto pb-1">
                {suggestedUsers.map((profile) => (
                  <SuggestedUserCard key={profile.id} user={profile} currentUid={user?.uid ?? null} />
                ))}
              </div>
            </section>

            <section>
              <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
                🐾 Popular Pets
              </h3>
              <div className="mt-3 flex gap-3 overflow-x-auto pb-1">
                {popularPets.map((pet) => (
                  <button
                    key={pet.id}
                    type="button"
                    onClick={() => navigate(`/pet/${pet.id}`)}
                    className="min-w-[140px] rounded-2xl bg-white p-3 text-center shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700"
                  >
                    <Avatar
                      src={pet.avatarUrl || undefined}
                      alt={pet.name}
                      userId={pet.id}
                      size={56}
                      className="mx-auto h-14 w-14"
                    />
                    <p className="mt-2 text-xs font-semibold text-slate-900 dark:text-white">
                      {pet.name}
                    </p>
                    <p className="text-[10px] text-slate-400 dark:text-slate-500">
                      {pet.breed || "Pet friend"}
                    </p>
                    <p className="mt-1 text-[10px] text-slate-400 dark:text-slate-500">
                      {pet.postCount} posts
                    </p>
                  </button>
                ))}
              </div>
            </section>

            <section>
              <div className="flex items-center justify-between">
                <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
                  📍 Top Rated Places
                </h3>
                <button
                  type="button"
                  onClick={() => navigate("/places")}
                  className="text-xs font-semibold text-purple-600"
                >
                  See All Places →
                </button>
              </div>
              <div className="mt-3 space-y-2">
                {topPlaces.map((place) => (
                  <button
                    key={place.id}
                    type="button"
                    onClick={() => navigate(`/location/${place.id}`)}
                    className="flex w-full items-center gap-3 rounded-2xl bg-white px-4 py-3 text-left shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700"
                  >
                    {place.photos?.[0] ? (
                      <img
                        src={place.photos[0]}
                        alt={place.name}
                        className="h-12 w-12 rounded-xl object-cover"
                      />
                    ) : (
                      <div className="flex h-12 w-12 items-center justify-center rounded-xl bg-gradient-to-br from-purple-400 to-pink-400 text-white">
                        📍
                      </div>
                    )}
                    <div>
                      <p className="text-sm font-semibold text-slate-900 dark:text-white">
                        {place.name}
                      </p>
                      <p className="text-xs text-amber-500">
                        ⭐ {place.averageRating.toFixed(1)} ({place.totalRatings})
                      </p>
                    </div>
                  </button>
                ))}
              </div>
            </section>

            <section>
              <div className="flex items-center justify-between">
                <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
                  🤝 Upcoming Meetups
                </h3>
                <button
                  type="button"
                  onClick={() => navigate("/meetups")}
                  className="text-xs font-semibold text-purple-600"
                >
                  See All Meetups →
                </button>
              </div>
              <div className="mt-3 space-y-2">
                {upcomingMeetups.map((meetup) => (
                  <button
                    key={meetup.id}
                    type="button"
                    onClick={() => navigate(`/meetups/${meetup.id}`)}
                    className="flex w-full flex-col gap-1 rounded-2xl bg-white px-4 py-3 text-left shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700"
                  >
                    <p className="text-sm font-semibold text-slate-900 dark:text-white">
                      {meetup.title}
                    </p>
                    <p className="text-xs text-slate-400 dark:text-slate-500">
                      {timeAgo(meetup.date as unknown as Date)} · {meetup.location?.name || "Meetup"}
                    </p>
                  </button>
                ))}
              </div>
            </section>
          </div>
        ) : null}

        {tab === "tags" ? (
          <>
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
                      <span className="font-semibold text-purple-600">#{tag.name}</span>
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

            {!loading && hasQuery && !hasResults ? (
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

            {filteredPosts.length > 0 ? (
              <section className="space-y-3">
                <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
                  Posts
                </h3>
                <div className="grid gap-4 sm:grid-cols-2">
                  {filteredPosts.map((post, index) => (
                    <PostCard
                      key={post.id}
                      post={post}
                      index={index}
                      onDeleted={(postId) =>
                        setPosts((prev) => prev.filter((item) => item.id !== postId))
                      }
                    />
                  ))}
                </div>
              </section>
            ) : null}
          </>
        ) : null}

        {tab === "people" ? (
          <>
            {loading ? (
              <div className="space-y-4">
                {[1, 2, 3].map((item) => (
                  <SkeletonPostCard key={item} />
                ))}
              </div>
            ) : null}

            {!loading && hasQuery && users.length === 0 ? (
              <EmptyState
                icon="🔍"
                title="No people found"
                description="Try different names"
              />
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
          </>
        ) : null}

        {tab === "pets" ? (
          <>
            {loading ? (
              <div className="space-y-4">
                {[1, 2, 3].map((item) => (
                  <SkeletonPostCard key={item} />
                ))}
              </div>
            ) : null}

            {!loading && hasQuery && pets.length === 0 ? (
              <EmptyState
                icon="🐾"
                title="No pets found"
                description="Try different names or breeds"
              />
            ) : null}

            {pets.length > 0 ? (
              <section className="space-y-3">
                <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
                  Pets
                </h3>
                <div className="space-y-3">
                  {pets.map((pet) => (
                    <PetResultCard key={pet.id} pet={pet} />
                  ))}
                </div>
              </section>
            ) : null}
          </>
        ) : null}
      </main>

      <BottomNav />
    </div>
  );
}
