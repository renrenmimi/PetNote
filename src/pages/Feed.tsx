import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Navbar } from "../components/Navbar";
import { OnboardingFlow } from "../components/OnboardingFlow";
import { PetSpotlight } from "../components/PetSpotlight";
import { EmailVerificationBanner } from "../components/EmailVerificationBanner";
import { BirthdayCelebration } from "../components/BirthdayCelebration";
import { PostCard } from "../components/PostCard";
import { EmptyState } from "../components/EmptyState";
import PawIcon from "../components/PawIcon";
import { SkeletonPostCard } from "../components/SkeletonPostCard";
import { ScrollToTop } from "../components/ScrollToTop";
import { usePosts } from "../hooks/usePosts";
import { useAuth } from "../hooks/useAuth";
import { useBlockedUsers } from "../hooks/useBlockedUsers";
import { batchCheckLikes } from "../hooks/useBatchLikeStatus";
import { batchCheckBookmarks } from "../hooks/useBatchBookmarkStatus";
import { batchCheckFollowingPets } from "../hooks/useBatchFollowingPets";
import { getFollowingPets } from "../services/follow";
import { batchCheckPetBirthdays } from "../services/pets";
import { useToast } from "../contexts/ToastContext";
import { useLanguage } from "../hooks/useLanguage";
import { type Post } from "../services/posts";

export function Feed() {
  const navigate = useNavigate();
  const { t } = useLanguage();
  const { user, profile, profileLoading } = useAuth();
  const [activeTab, setActiveTab] = useState<"all" | "following">("all");
  const { posts, loading, loadingMore, hasMore, loadMore, refresh, error } =
    usePosts(activeTab, user?.uid ?? null);
  const [localPosts, setLocalPosts] = useState<Post[]>([]);
  const [showOnboarding, setShowOnboarding] = useState(false);
  const [onboardingDismissed, setOnboardingDismissed] = useState(false);
  const sentinelRef = useRef<HTMLDivElement | null>(null);
  const startYRef = useRef(0);
  const lastErrorRef = useRef<string | null>(null);
  const [pullDistance, setPullDistance] = useState(0);
  const [refreshing, setRefreshing] = useState(false);
  const [followingCount, setFollowingCount] = useState(0);
  const { blockedUserIds } = useBlockedUsers(user?.uid ?? null);
  const { showToast } = useToast();
  const [likedPosts, setLikedPosts] = useState<Set<string>>(new Set());
  const [bookmarkedPosts, setBookmarkedPosts] = useState<Set<string>>(new Set());
  const [followedPetIds, setFollowedPetIds] = useState<Set<string>>(new Set());
  const [birthdayPetIds, setBirthdayPetIds] = useState<Set<string>>(new Set());
  const checkedLikePostIdsRef = useRef<Set<string>>(new Set());
  const checkedBookmarkPostIdsRef = useRef<Set<string>>(new Set());
  const checkedFollowPetIdsRef = useRef<Set<string>>(new Set());
  const checkedBirthdayPetIdsRef = useRef<Set<string>>(new Set());
  const statusUserIdRef = useRef<string | null>(null);

  useEffect(() => {
    setLocalPosts(posts);
  }, [posts]);

  useEffect(() => {
    if (!error) return;
    if (lastErrorRef.current === error) return;
    lastErrorRef.current = error;
    showToast(error, "error");
  }, [error, showToast]);

  useEffect(() => {
    void refresh();
  }, [activeTab, refresh]);

  useEffect(() => {
    if (!user) {
      setActiveTab("all");
      setOnboardingDismissed(false);
    }
  }, [user]);

  useEffect(() => {
    if (!user || profileLoading) {
      setShowOnboarding(false);
      return;
    }
    setShowOnboarding(
      !onboardingDismissed && !(profile?.onboardingComplete ?? false)
    );
  }, [onboardingDismissed, profile, profileLoading, user]);

  useEffect(() => {
    let ignore = false;
    if (!user || activeTab !== "following") return;
    const loadFollowing = async () => {
      const items = await getFollowingPets(user.uid);
      if (!ignore) setFollowingCount(items.length);
    };
    void loadFollowing();
    return () => {
      ignore = true;
    };
  }, [activeTab, user]);

  useEffect(() => {
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries[0].isIntersecting && hasMore && !loadingMore) {
          void loadMore();
        }
      },
      { threshold: 0.1 }
    );

    const node = sentinelRef.current;
    if (node) observer.observe(node);

    return () => observer.disconnect();
  }, [hasMore, loadMore, loadingMore]);
  const filteredPosts = useMemo(
    () => localPosts.filter((post) => !blockedUserIds.includes(post.authorId)),
    [blockedUserIds, localPosts]
  );
  const filteredPostIdsKey = useMemo(
    () => filteredPosts.map((post) => post.id).join("\n"),
    [filteredPosts]
  );
  const filteredPetIdsKey = useMemo(
    () =>
      Array.from(
        new Set(
          filteredPosts
            .map((post) => post.petId)
            .filter((petId): petId is string => !!petId)
        )
      ).join("\n"),
    [filteredPosts]
  );
  const statusUserId = user?.uid ?? null;

  useEffect(() => {
    if (statusUserIdRef.current === statusUserId) return;
    statusUserIdRef.current = statusUserId;
    checkedLikePostIdsRef.current.clear();
    checkedBookmarkPostIdsRef.current.clear();
    checkedFollowPetIdsRef.current.clear();
    setLikedPosts(new Set());
    setBookmarkedPosts(new Set());
    setFollowedPetIds(new Set());
  }, [statusUserId]);

  useEffect(() => {
    let ignore = false;
    if (!statusUserId || !filteredPostIdsKey) {
      setLikedPosts(new Set());
      setBookmarkedPosts(new Set());
      setFollowedPetIds(new Set());
      checkedLikePostIdsRef.current.clear();
      checkedBookmarkPostIdsRef.current.clear();
      checkedFollowPetIdsRef.current.clear();
      return;
    }
    const ids = filteredPostIdsKey.split("\n");
    const petIds = filteredPetIdsKey ? filteredPetIdsKey.split("\n") : [];
    const uncheckedLikeIds = ids.filter(
      (id) => !checkedLikePostIdsRef.current.has(id)
    );
    const uncheckedBookmarkIds = ids.filter(
      (id) => !checkedBookmarkPostIdsRef.current.has(id)
    );
    const uncheckedFollowPetIds = petIds.filter(
      (id) => !checkedFollowPetIdsRef.current.has(id)
    );
    if (
      uncheckedLikeIds.length === 0 &&
      uncheckedBookmarkIds.length === 0 &&
      uncheckedFollowPetIds.length === 0
    ) {
      return;
    }
    const loadStatus = async () => {
      const [likedSet, bookmarkedSet, followedSet] = await Promise.all([
        uncheckedLikeIds.length > 0
          ? batchCheckLikes(statusUserId, uncheckedLikeIds)
          : Promise.resolve(new Set<string>()),
        uncheckedBookmarkIds.length > 0
          ? batchCheckBookmarks(statusUserId, uncheckedBookmarkIds)
          : Promise.resolve(new Set<string>()),
        uncheckedFollowPetIds.length > 0
          ? batchCheckFollowingPets(statusUserId, uncheckedFollowPetIds)
          : Promise.resolve(new Set<string>()),
      ]);
      if (!ignore) {
        uncheckedLikeIds.forEach((id) => checkedLikePostIdsRef.current.add(id));
        uncheckedBookmarkIds.forEach((id) =>
          checkedBookmarkPostIdsRef.current.add(id)
        );
        uncheckedFollowPetIds.forEach((id) =>
          checkedFollowPetIdsRef.current.add(id)
        );
        setLikedPosts((prev) => {
          const next = new Set(prev);
          uncheckedLikeIds.forEach((id) => next.delete(id));
          likedSet.forEach((id) => next.add(id));
          return next;
        });
        setBookmarkedPosts((prev) => {
          const next = new Set(prev);
          uncheckedBookmarkIds.forEach((id) => next.delete(id));
          bookmarkedSet.forEach((id) => next.add(id));
          return next;
        });
        setFollowedPetIds((prev) => {
          const next = new Set(prev);
          uncheckedFollowPetIds.forEach((id) => next.delete(id));
          followedSet.forEach((id) => next.add(id));
          return next;
        });
      }
    };
    void loadStatus();
    return () => {
      ignore = true;
    };
  }, [filteredPetIdsKey, filteredPostIdsKey, statusUserId]);

  useEffect(() => {
    let ignore = false;
    if (!filteredPetIdsKey) {
      setBirthdayPetIds(new Set());
      checkedBirthdayPetIdsRef.current.clear();
      return;
    }
    const petIds = filteredPetIdsKey.split("\n");
    const uncheckedPetIds = petIds.filter(
      (id) => !checkedBirthdayPetIdsRef.current.has(id)
    );
    if (uncheckedPetIds.length === 0) return;

    const loadBirthdays = async () => {
      const birthdaySet = await batchCheckPetBirthdays(uncheckedPetIds);
      if (!ignore) {
        uncheckedPetIds.forEach((id) => checkedBirthdayPetIdsRef.current.add(id));
        setBirthdayPetIds((prev) => {
          const next = new Set(prev);
          uncheckedPetIds.forEach((id) => next.delete(id));
          birthdaySet.forEach((id) => next.add(id));
          return next;
        });
      }
    };
    void loadBirthdays();
    return () => {
      ignore = true;
    };
  }, [filteredPetIdsKey]);

  const handleLikeChanged = useCallback((postId: string, liked: boolean) => {
    checkedLikePostIdsRef.current.add(postId);
    setLikedPosts((prev) => {
      const next = new Set(prev);
      if (liked) {
        next.add(postId);
      } else {
        next.delete(postId);
      }
      return next;
    });
  }, []);

  const handleBookmarkChanged = useCallback(
    (postId: string, bookmarked: boolean) => {
      checkedBookmarkPostIdsRef.current.add(postId);
      setBookmarkedPosts((prev) => {
        const next = new Set(prev);
        if (bookmarked) {
          next.add(postId);
        } else {
          next.delete(postId);
        }
        return next;
      });
    },
    []
  );

  const handlePetFollowChanged = useCallback(
    (petId: string, following: boolean) => {
      checkedFollowPetIdsRef.current.add(petId);
      setFollowedPetIds((prev) => {
        const next = new Set(prev);
        if (following) {
          next.add(petId);
        } else {
          next.delete(petId);
        }
        return next;
      });
    },
    []
  );

  const pullLabel = refreshing
    ? t("feed.refreshing")
    : pullDistance > 60
    ? t("feed.releaseToRefresh")
    : t("feed.pullToRefresh");

  return (
    <div className="min-h-screen bg-slate-50 pb-20 dark:bg-slate-900">
      <Navbar />

      <main
        className="mx-auto w-full max-w-md space-y-4 px-4 py-4"
        onTouchStart={(event) => {
          if (window.scrollY > 0) return;
          startYRef.current = event.touches[0].clientY;
        }}
        onTouchMove={(event) => {
          if (window.scrollY > 0) return;
          const distance = event.touches[0].clientY - startYRef.current;
          if (distance > 0) {
            setPullDistance(Math.min(distance, 80));
          }
        }}
        onTouchEnd={async () => {
          if (pullDistance > 60) {
            setRefreshing(true);
            await refresh();
            setRefreshing(false);
          }
          setPullDistance(0);
        }}
      >
        <div className="sticky top-[56px] z-10 -mx-4 bg-slate-50 px-4 pb-2 pt-1 dark:bg-slate-900">
          <div
            className={`relative border-b border-slate-200 dark:border-slate-700 ${
              user ? "grid grid-cols-2" : "grid grid-cols-1"
            }`}
          >
            <button
              type="button"
              onClick={() => setActiveTab("all")}
              className={`pb-2 text-sm font-semibold transition-all duration-200 ${
                activeTab === "all"
                  ? "text-slate-900 dark:text-white"
                  : "text-slate-400 hover:text-slate-600 dark:text-slate-500 dark:hover:text-slate-200"
              }`}
            >
              {t("feed.tabForYou")}
            </button>
            {user ? (
              <button
                type="button"
                onClick={() => setActiveTab("following")}
                className={`pb-2 text-sm font-semibold transition-all duration-200 ${
                  activeTab === "following"
                    ? "text-slate-900 dark:text-white"
                    : "text-slate-400 hover:text-slate-600 dark:text-slate-500 dark:hover:text-slate-200"
                }`}
              >
                {t("feed.tabFollowing")}
              </button>
            ) : null}
            <span
              className={`absolute bottom-0 h-0.5 rounded-full bg-gradient-to-r from-purple-500 to-pink-500 transition-all duration-300 ${
                user ? "w-1/2" : "w-full"
              } ${activeTab === "following" && user ? "translate-x-full" : "translate-x-0"}`}
            />
          </div>
        </div>

        <p className="text-center text-xs text-slate-400 dark:text-slate-500">
          {pullLabel}
        </p>

        <EmailVerificationBanner />
        <BirthdayCelebration ownerId={user?.uid ?? null} />
        <PetSpotlight />

        {loading ? (
          <div className="space-y-4">
            {[1, 2, 3].map((item) => (
              <SkeletonPostCard key={item} />
            ))}
          </div>
        ) : null}

        {!loading && filteredPosts.length === 0 ? (
          activeTab === "following" && user && followingCount === 0 ? (
            <EmptyState
              icon="👥"
              title={t("feed.emptyFollowingTitle")}
              description={t("feed.emptyFollowingDescription")}
              actionText={t("feed.discoverPets")}
              onAction={() => navigate("/search")}
            />
          ) : (
            <div className="rounded-2xl bg-white p-6 text-center shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
              <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-2xl bg-gradient-to-br from-purple-500 to-pink-500">
                <PawIcon size={36} />
              </div>
              <p className="mt-4 text-base font-semibold text-slate-900 dark:text-white">
                {t("feed.welcomeTitle")}
              </p>
              <p className="mt-2 text-sm text-slate-500 dark:text-slate-400">
                {t("feed.welcomeDescription")}
              </p>
              <div className="mt-4 flex flex-col gap-2">
                <button
                  type="button"
                  onClick={() => navigate("/create")}
                  className="w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white"
                >
                  {t("feed.createPost")}
                </button>
                <button
                  type="button"
                  onClick={() => navigate("/search")}
                  className="text-xs font-semibold text-purple-600"
                >
                  {t("feed.exploreOthers")}
                </button>
              </div>
            </div>
          )
        ) : null}

        {filteredPosts.map((post, index) => (
          <PostCard
            key={post.id}
            post={post}
            index={index}
            initialLiked={likedPosts.has(post.id)}
            initialBookmarked={bookmarkedPosts.has(post.id)}
            initialFollowingPet={
              post.petId ? followedPetIds.has(post.petId) : undefined
            }
            initialBirthday={
              post.petId ? birthdayPetIds.has(post.petId) : undefined
            }
            onLikeChanged={handleLikeChanged}
            onBookmarkChanged={handleBookmarkChanged}
            onPetFollowChanged={handlePetFollowChanged}
            onDeleted={(postId) =>
              setLocalPosts((prev) => prev.filter((item) => item.id !== postId))
            }
          />
        ))}

        <div ref={sentinelRef} className="flex justify-center py-4">
          {loadingMore ? (
            <span className="h-6 w-6 animate-spin rounded-full border-2 border-purple-500 border-t-transparent" />
          ) : !hasMore && filteredPosts.length > 0 ? (
            <p className="text-xs text-slate-400 dark:text-slate-500">
              {t("feed.endOfFeed")}
            </p>
          ) : null}
        </div>
      </main>

      <ScrollToTop />

      {user && !profileLoading && showOnboarding ? (
        <OnboardingFlow
          userId={user.uid}
          onComplete={() => {
            setOnboardingDismissed(true);
            setShowOnboarding(false);
          }}
        />
      ) : null}
    </div>
  );
}
