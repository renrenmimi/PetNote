import { useEffect, useMemo, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { Navbar } from "../components/Navbar";
import { PostCard } from "../components/PostCard";
import { EmptyState } from "../components/EmptyState";
import { ErrorBoundary } from "../components/ErrorBoundary";
import Avatar from "../components/Avatar";
import LazyImage from "../components/LazyImage";
import { useAuth } from "../hooks/useAuth";
import { useBlockedUsers } from "../hooks/useBlockedUsers";
import {
  getPostsByTag,
  getTrendingTags,
  searchTags,
  type Hashtag,
} from "../services/hashtags";
import { searchByText, searchPets, searchUsers } from "../services/search";
import {
  getPopularPets,
  getSuggestedPets,
  getTopRatedPlaces,
  getTrendingPosts,
  getUpcomingMeetupPreview,
} from "../services/explore";
import { type Post } from "../services/posts";
import { type UserProfile } from "../services/users";
import { getUserPetCounts, type Pet } from "../services/pets";
import { type Location } from "../services/locations";
import { type Meetup } from "../services/meetups";
import { useFollowPet } from "../hooks/useFollow";
import { batchCheckFollowingPets } from "../hooks/useBatchFollowingPets";
import { getVideoThumbnail } from "../utils/cloudinaryUrl";

type PopularPet = Pet & { postCount: number };

// Upcoming meetups carry FUTURE dates — timeAgo() on those always yields
// "just now" (negative diff). Show the calendar date instead.
const formatMeetupDate = (value: unknown): string => {
  const date =
    value instanceof Date
      ? value
      : typeof value === "object" &&
          value !== null &&
          "toDate" in value &&
          typeof (value as { toDate: () => Date }).toDate === "function"
        ? (value as { toDate: () => Date }).toDate()
        : null;
  if (!date) return "";
  return date.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
  });
};

type SearchResults = {
  users: UserProfile[];
  pets: Pet[];
  tags: Hashtag[];
  posts: Post[];
};

const EMPTY_USERS: UserProfile[] = [];
const EMPTY_PETS: Pet[] = [];
const EMPTY_TAGS: Hashtag[] = [];

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

const placeCategoryLabel: Record<string, string> = {
  dog_park: "🐕 Dog Park",
  hiking_trail: "🥾 Hiking Trail",
  beach: "🏖️ Beach",
  community_park: "🌳 Park",
  cafe: "☕ Café",
  green_space: "🌿 Green Space",
  pet_store: "🏪 Pet Store",
  vet: "🏥 Vet",
  other: "📍 Other",
};

function SuggestedPetCard({
  pet,
  initialFollowing,
}: {
  pet: PopularPet;
  initialFollowing?: boolean;
}) {
  const { user } = useAuth();
  // Pass initialFollowing so the per-card lookup is skipped — the parent
  // batched the status for every visible suggested pet in one read.
  // fetchFollowerCount stays off because this card only renders the
  // pet's existing follower count from the doc that was already fetched.
  const { isFollowing, toggleFollow, loading } = useFollowPet(pet.id, {
    initialFollowing,
    fetchFollowerCount: false,
  });
  const navigate = useNavigate();

  return (
    <div className="min-w-[140px] rounded-2xl bg-white p-3 text-center shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
      <button
        type="button"
        onClick={() => navigate(`/pet/${pet.id}`)}
        className="flex w-full flex-col items-center gap-2"
      >
        <Avatar
          src={pet.avatarUrl || undefined}
          alt={pet.name}
          userId={pet.id}
          size={56}
          className="h-14 w-14"
        />
        <div>
          <p className="text-xs font-semibold text-slate-900 dark:text-white">
            {pet.name}
          </p>
          <p className="text-[10px] text-slate-400 dark:text-slate-500">
            {pet.followerCount || 0} followers
          </p>
        </div>
      </button>
      {user ? (
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
        {pet.breed ? (
          <p className="text-xs text-slate-400 dark:text-slate-500">
            {pet.breed}
          </p>
        ) : null}
      </div>
    </button>
  );
}

export function Search() {
  const { user } = useAuth();
  const navigate = useNavigate();
  const { blockedUserIds } = useBlockedUsers(user?.uid ?? null);
  const [searchParams, setSearchParams] = useSearchParams();

  const [query, setQuery] = useState("");
  const [searching, setSearching] = useState(false);
  const [searchResults, setSearchResults] = useState<SearchResults | null>(null);
  const [showAllPeople, setShowAllPeople] = useState(false);
  const [showAllPets, setShowAllPets] = useState(false);
  const [peoplePetCounts, setPeoplePetCounts] = useState<Record<string, number>>(
    {}
  );

  const [trendingTags, setTrendingTags] = useState<Hashtag[]>([]);
  const [trendingPosts, setTrendingPosts] = useState<Post[]>([]);
  const [suggestedPets, setSuggestedPets] = useState<PopularPet[]>([]);
  const [followedSuggestedIds, setFollowedSuggestedIds] = useState<
    Set<string>
  >(new Set());
  const [popularPets, setPopularPets] = useState<PopularPet[]>([]);
  const [topPlaces, setTopPlaces] = useState<Location[]>([]);
  const [upcomingMeetups, setUpcomingMeetups] = useState<Meetup[]>([]);
  const [exploreLoading, setExploreLoading] = useState(false);

  const normalizedQuery = useMemo(() => query.trim(), [query]);
  const hasQuery = normalizedQuery.length > 0;

  const handleQueryChange = (value: string) => {
    setQuery(value);
  };

  const handleTagClick = (tag: string) => {
    setSearchResults(null);
    setQuery(`#${tag}`);
    setSearchParams({ tag });
  };

  const handleClear = () => {
    setQuery("");
    setSearchResults(null);
    setSearchParams({});
  };

  useEffect(() => {
    const tagParam = searchParams.get("tag");
    if (tagParam) {
      setQuery((prev) => (prev ? prev : `#${tagParam}`));
    }
  }, [searchParams]);

  useEffect(() => {
    // replace:true — these are effect-driven URL syncs, not navigations.
    // Pushing per keystroke polluted history (Back needed N presses) and the
    // mount-time run also strips+re-adds an incoming ?tag= deep link.
    if (!normalizedQuery) {
      setSearchParams({}, { replace: true });
      return;
    }

    if (normalizedQuery.startsWith("#")) {
      const tagName = normalizedQuery.replace(/^#/, "");
      if (tagName) {
        setSearchParams({ tag: tagName }, { replace: true });
      } else {
        setSearchParams({}, { replace: true });
      }
    } else {
      setSearchParams({}, { replace: true });
    }
  }, [normalizedQuery, setSearchParams]);

  useEffect(() => {
    let ignore = false;
    const loadTags = async () => {
      try {
        const tags = await getTrendingTags(12);
        if (!ignore) setTrendingTags(tags);
      } catch {
        // Trending tags are a non-critical discovery enhancement; on failure
        // leave the section empty instead of surfacing an unhandled rejection.
      }
    };
    void loadTags();
    return () => {
      ignore = true;
    };
  }, []);

  useEffect(() => {
    if (hasQuery) return;
    let ignore = false;
    const loadExplore = async () => {
      setExploreLoading(true);
      try {
        const [trending, suggested, popular, places, meetups] = await Promise.all([
          getTrendingPosts(9),
          getSuggestedPets(user?.uid ?? "", 8),
          getPopularPets(8),
          getTopRatedPlaces(5),
          getUpcomingMeetupPreview(3),
        ]);
        if (!ignore) {
          setTrendingPosts(trending);
          setSuggestedPets(suggested);
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
  }, [hasQuery, user]);

  useEffect(() => {
    setShowAllPeople(false);
    setShowAllPets(false);
  }, [normalizedQuery]);

  // Batch the viewer's follow status for every suggested pet so each
  // SuggestedPetCard can skip its own checkIfFollowingPet getDoc.
  useEffect(() => {
    let ignore = false;
    if (!user?.uid || suggestedPets.length === 0) {
      setFollowedSuggestedIds(new Set());
      return;
    }
    const load = async () => {
      const followed = await batchCheckFollowingPets(
        user.uid,
        suggestedPets.map((pet) => pet.id)
      );
      if (!ignore) {
        setFollowedSuggestedIds(followed);
      }
    };
    void load();
    return () => {
      ignore = true;
    };
  }, [suggestedPets, user?.uid]);

  useEffect(() => {
    if (!hasQuery) {
      setSearchResults(null);
      setSearching(false);
      return;
    }

    let ignore = false;
    const handle = window.setTimeout(async () => {
      setSearching(true);
      const keyword = normalizedQuery.replace(/^#/, "").toLowerCase();
      try {
        const isTagQuery = normalizedQuery.startsWith("#");
        const [userResults, petResults, tagResults, postResults] = await Promise.all([
          searchUsers(keyword),
          searchPets(keyword),
          searchTags(keyword),
          isTagQuery
            ? getPostsByTag(keyword).then((result) => result.posts)
            : searchByText(keyword),
        ]);
        if (ignore) return;
        setSearchResults({
          users: userResults,
          pets: petResults,
          tags: tagResults,
          posts: postResults,
        });
      } catch {
        if (!ignore) {
          setSearchResults({ users: [], pets: [], tags: [], posts: [] });
        }
      } finally {
        if (!ignore) {
          setSearching(false);
        }
      }
    }, 300);

    return () => {
      ignore = true;
      window.clearTimeout(handle);
    };
  }, [hasQuery, normalizedQuery]);

  const filteredSearchPosts = useMemo(() => {
    const posts = searchResults?.posts ?? [];
    return posts.filter((post) => !blockedUserIds.includes(post.authorId));
  }, [blockedUserIds, searchResults]);

  const filteredTrending = useMemo(() => {
    return trendingPosts.filter((post) => !blockedUserIds.includes(post.authorId));
  }, [blockedUserIds, trendingPosts]);

  const peopleResults = searchResults?.users ?? EMPTY_USERS;
  const petResults = searchResults?.pets ?? EMPTY_PETS;
  const tagResults = searchResults?.tags ?? EMPTY_TAGS;

  useEffect(() => {
    let ignore = false;
    if (peopleResults.length === 0) {
      setPeoplePetCounts((prev) =>
        Object.keys(prev).length === 0 ? prev : {}
      );
      return;
    }
    const loadCounts = async () => {
      const map = await getUserPetCounts(peopleResults.map((person) => person.id));
      if (ignore) return;
      setPeoplePetCounts(map);
    };
    void loadCounts();
    return () => {
      ignore = true;
    };
  }, [peopleResults]);

  const hasAnyResult =
    peopleResults.length > 0 ||
    petResults.length > 0 ||
    tagResults.length > 0 ||
    filteredSearchPosts.length > 0;

  return (
    <div className="min-h-screen bg-slate-50 pb-20 dark:bg-slate-900">
      <Navbar />

      <main className="mx-auto w-full max-w-md space-y-4 px-4 py-4">
        <div className="sticky top-16 z-10">
          <div className="rounded-2xl bg-white px-4 py-3 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
            <div className="flex items-center gap-2">
              <span className="text-lg">🔍</span>
              <input
                type="text"
                placeholder="Search people, pets, tags..."
                className="flex-1 bg-transparent text-sm text-slate-700 outline-none placeholder:text-slate-400 dark:text-slate-200 dark:placeholder:text-slate-500"
                value={query}
                onChange={(event) => handleQueryChange(event.target.value)}
              />
              {query ? (
                <button
                  type="button"
                  onClick={handleClear}
                  className="text-sm text-slate-400 transition-all duration-200 hover:text-purple-500 dark:text-slate-500"
                >
                  ✕
                </button>
              ) : null}
            </div>
          </div>
        </div>

        {!hasQuery ? (
          <div className="space-y-5">
            {trendingTags.length > 0 ? (
              <section>
                <h2 className="text-sm font-semibold text-slate-900 dark:text-white">
                  Trending Tags 🔥
                </h2>
                <div className="mt-3 flex gap-2 overflow-x-auto pb-1">
                  {trendingTags.map((tag) => (
                    <button
                      key={tag.name}
                      type="button"
                      onClick={() => handleTagClick(tag.name)}
                      className="whitespace-nowrap rounded-full bg-gradient-to-r from-purple-100 to-pink-100 px-3 py-1 text-xs font-semibold text-purple-600 transition-all duration-200 hover:scale-105 dark:from-purple-500/20 dark:to-pink-500/20 dark:text-purple-200"
                    >
                      #{tag.name} · {tag.postCount} posts
                    </button>
                  ))}
                </div>
              </section>
            ) : null}

            {filteredTrending.length > 0 || exploreLoading ? (
              <section>
                <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
                  🔥 Trending Posts
                </h3>
                {exploreLoading ? (
                  <div className="mt-3 grid grid-cols-3 gap-1">
                    {Array.from({ length: 9 }).map((_, idx) => (
                      <div
                        key={idx}
                        className="aspect-square animate-pulse rounded-lg bg-slate-200 dark:bg-slate-700"
                      />
                    ))}
                  </div>
                ) : (
                  <div className="mt-3 grid grid-cols-3 gap-1">
                    {filteredTrending.map((post) => {
                      const media =
                        post.media?.[0] ||
                        (post.mediaUrl
                          ? { url: post.mediaUrl, type: post.mediaType || "image" }
                          : null);
                      const thumbSrc = media
                        ? media.type === "video"
                          ? getVideoThumbnail(media.url, "thumbnail")
                          : ("thumbUrl" in media ? media.thumbUrl : undefined) ||
                            media.url
                        : null;
                      return (
                        <button
                          key={post.id}
                          type="button"
                          onClick={() => navigate(`/post/${post.id}`)}
                          className="relative aspect-square overflow-hidden rounded-lg bg-slate-100"
                        >
                          {thumbSrc ? (
                            <LazyImage
                              src={thumbSrc}
                              alt={post.text}
                              className="h-full w-full"
                              cloudinarySize="thumbnail"
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
            ) : null}

            {suggestedPets.length > 0 ? (
              <section>
                <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
                  🐾 Suggested Pets
                </h3>
                <div className="mt-3 flex gap-3 overflow-x-auto pb-1">
                  {suggestedPets.map((pet) => (
                    <SuggestedPetCard
                      key={pet.id}
                      pet={pet}
                      initialFollowing={followedSuggestedIds.has(pet.id)}
                    />
                  ))}
                </div>
              </section>
            ) : null}

            {popularPets.length > 0 ? (
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
                      {pet.breed ? (
                        <p className="text-[10px] text-slate-400 dark:text-slate-500">
                          {pet.breed}
                        </p>
                      ) : null}
                      <p className="mt-1 text-[10px] text-slate-400 dark:text-slate-500">
                        {pet.postCount} posts
                      </p>
                    </button>
                  ))}
                </div>
              </section>
            ) : null}

            {topPlaces.length > 0 ? (
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
                        <LazyImage
                          src={place.photos[0]}
                          alt={place.name}
                          className="h-12 w-12 rounded-xl"
                          cloudinarySize="small"
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
                        <p className="text-xs text-slate-400 dark:text-slate-500">
                          {placeCategoryLabel[place.category] || "📍 Place"}
                        </p>
                        <p className="text-xs text-amber-500">
                          ⭐ {place.averageRating.toFixed(1)} ({place.totalRatings})
                        </p>
                      </div>
                    </button>
                  ))}
                </div>
              </section>
            ) : null}

            {upcomingMeetups.length > 0 ? (
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
                        {formatMeetupDate(meetup.date)} · {meetup.location?.name || "Meetup"}
                      </p>
                    </button>
                  ))}
                </div>
              </section>
            ) : null}
          </div>
        ) : null}

        {hasQuery ? (
          <div className="space-y-5">
            {searching ? (
              <div className="flex items-center justify-center py-8">
                <div className="h-6 w-6 animate-spin rounded-full border-2 border-purple-500 border-t-transparent" />
              </div>
            ) : null}

            {!searching && !hasAnyResult ? (
              <EmptyState
                icon="🔍"
                title={`No results for "${normalizedQuery}"`}
                description="Try different keywords"
              />
            ) : null}

            {!searching && peopleResults.length > 0 ? (
              <section className="space-y-3">
                <div className="flex items-center justify-between">
                  <p className="text-xs font-semibold uppercase tracking-[0.2em] text-slate-400">
                    People
                  </p>
                  {peopleResults.length > 3 ? (
                    <button
                      type="button"
                      onClick={() => setShowAllPeople((prev) => !prev)}
                      className="text-xs font-semibold text-purple-600"
                    >
                      {showAllPeople ? "Show less" : "See all people →"}
                    </button>
                  ) : null}
                </div>
                <div className="space-y-3">
                  {(showAllPeople ? peopleResults : peopleResults.slice(0, 3)).map(
                    (profile) => {
                      const isSelf = profile.id === user?.uid;
                      return (
                        <button
                          key={profile.id}
                          type="button"
                          onClick={() => navigate(`/profile/${profile.id}`)}
                          className="flex w-full items-center justify-between rounded-2xl bg-white px-4 py-3 text-left shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 transition-all duration-200 hover:-translate-y-0.5 dark:bg-slate-800 dark:ring-slate-700"
                        >
                          <div className="flex items-center gap-3">
                            <Avatar
                              src={profile.avatarUrl || undefined}
                              alt={profile.displayName || "User"}
                              userId={profile.id}
                              size={44}
                              className="h-11 w-11"
                            />
                            <div>
                              <p className="text-sm font-semibold text-slate-900 dark:text-white">
                                {profile.displayName || "PetNote User"}
                              </p>
                              <p className="line-clamp-1 text-xs text-slate-400 dark:text-slate-500">
                                {profile.bio || "Pet lover"}
                              </p>
                              <p className="text-[11px] text-slate-400 dark:text-slate-500">
                                {peoplePetCounts[profile.id] ?? 0} pets
                              </p>
                            </div>
                          </div>
                          {!isSelf ? (
                            <span className="text-xs font-semibold text-purple-600">
                              View
                            </span>
                          ) : (
                            <span className="text-xs font-semibold text-slate-400">
                              You
                            </span>
                          )}
                        </button>
                      );
                    }
                  )}
                </div>
              </section>
            ) : null}

            {!searching && petResults.length > 0 ? (
              <section className="space-y-3">
                <div className="flex items-center justify-between">
                  <p className="text-xs font-semibold uppercase tracking-[0.2em] text-slate-400">
                    Pets
                  </p>
                  {petResults.length > 3 ? (
                    <button
                      type="button"
                      onClick={() => setShowAllPets((prev) => !prev)}
                      className="text-xs font-semibold text-purple-600"
                    >
                      {showAllPets ? "Show less" : "See all pets →"}
                    </button>
                  ) : null}
                </div>
                <div className="space-y-3">
                  {(showAllPets ? petResults : petResults.slice(0, 3)).map(
                    (pet) => (
                      <PetResultCard key={pet.id} pet={pet} />
                    )
                  )}
                </div>
              </section>
            ) : null}

            {!searching && tagResults.length > 0 ? (
              <section className="space-y-3">
                <p className="text-xs font-semibold uppercase tracking-[0.2em] text-slate-400">
                  Tags
                </p>
                <div className="space-y-2">
                  {tagResults.slice(0, 5).map((tag) => (
                    <button
                      key={tag.name}
                      type="button"
                      onClick={() => handleTagClick(tag.name)}
                      className="flex w-full items-center justify-between rounded-xl bg-white px-3 py-2 text-left text-sm text-slate-700 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 transition-all duration-200 hover:scale-[1.01] dark:bg-slate-800 dark:text-slate-200 dark:ring-slate-700"
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

            {!searching && filteredSearchPosts.length > 0 ? (
              <section className="space-y-3">
                <p className="text-xs font-semibold uppercase tracking-[0.2em] text-slate-400">
                  Posts
                </p>
                <div className="space-y-4">
                  {filteredSearchPosts.slice(0, 5).map((post, index) => (
                    <ErrorBoundary
                      key={post.id}
                      fallback={
                        <div className="rounded-2xl bg-white p-4 text-center text-xs text-slate-400 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] dark:bg-slate-800 dark:text-slate-500">
                          This post couldn&apos;t be displayed.
                        </div>
                      }
                    >
                      <PostCard
                        post={post}
                        index={index}
                        onDeleted={(postId) =>
                          setSearchResults((prev) =>
                            prev
                              ? {
                                  ...prev,
                                  posts: prev.posts.filter((item) => item.id !== postId),
                                }
                              : prev
                          )
                        }
                      />
                    </ErrorBoundary>
                  ))}
                </div>
              </section>
            ) : null}

          </div>
        ) : null}
      </main>

    </div>
  );
}
