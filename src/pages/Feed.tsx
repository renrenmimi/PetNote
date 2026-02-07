import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { BottomNav } from "../components/BottomNav";
import { Navbar } from "../components/Navbar";
import { OnboardingFlow } from "../components/OnboardingFlow";
import { PetSpotlight } from "../components/PetSpotlight";
import { PostCard } from "../components/PostCard";
import { EmptyState } from "../components/EmptyState";
import { SkeletonPostCard } from "../components/SkeletonPostCard";
import { ScrollToTop } from "../components/ScrollToTop";
import { usePosts } from "../hooks/usePosts";
import { useAuth } from "../hooks/useAuth";
import { useBlockedUsers } from "../hooks/useBlockedUsers";
import { getFollowing } from "../services/follow";
import { type Post } from "../services/posts";
import { useToast } from "../contexts/ToastContext";

const mockPosts: Post[] = [
  {
    id: "1",
    authorId: "user1",
    authorName: "Sarah",
    authorAvatar: "https://i.pravatar.cc/150?img=1",
    text: "My cute puppy enjoying the sunshine! ☀️",
    mediaUrl:
      "https://images.unsplash.com/photo-1587300003388-59208cc962cb?w=600",
    mediaType: "image",
    createdAt: new Date(Date.now() - 2 * 60 * 60 * 1000),
    likeCount: 42,
    commentCount: 5,
    tags: ["puppy", "sunshine", "happy"],
  },
  {
    id: "2",
    authorId: "user2",
    authorName: "Mike",
    authorAvatar: "https://i.pravatar.cc/150?img=2",
    text: "Meet my new kitten! 🐱",
    mediaUrl:
      "https://images.unsplash.com/photo-1574158622682-e40e69881006?w=600",
    mediaType: "image",
    createdAt: new Date(Date.now() - 5 * 60 * 60 * 1000),
    likeCount: 128,
    commentCount: 23,
    tags: ["kitten", "cute", "newpet"],
  },
  {
    id: "3",
    authorId: "user3",
    authorName: "Emma",
    authorAvatar: "https://i.pravatar.cc/150?img=3",
    text: "Beach day with my golden retriever! 🏖️",
    mediaUrl: "https://images.unsplash.com/photo-1552053831-71594a27632d?w=600",
    mediaType: "image",
    createdAt: new Date(Date.now() - 24 * 60 * 60 * 1000),
    likeCount: 89,
    commentCount: 12,
    tags: ["goldenretriever", "beach", "summer"],
  },
];


export function Feed() {
  const navigate = useNavigate();
  const { user, profile, profileLoading } = useAuth();
  const [activeTab, setActiveTab] = useState<"all" | "following">("all");
  const { posts, loading, loadingMore, hasMore, loadMore, refresh, error } =
    usePosts(activeTab, user?.uid ?? null);
  const useMock = false;
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

  useEffect(() => {
    if (!useMock) {
      setLocalPosts(posts);
    }
  }, [posts, useMock]);

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
      const ids = await getFollowing(user.uid);
      if (!ignore) setFollowingCount(ids.length);
    };
    void loadFollowing();
    return () => {
      ignore = true;
    };
  }, [activeTab, user]);

  useEffect(() => {
    if (useMock) return;
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
  }, [hasMore, loadMore, loadingMore, useMock]);

  const displayPosts = useMemo(
    () => (useMock ? mockPosts : localPosts),
    [useMock, localPosts],
  );
  const filteredPosts = useMemo(
    () =>
      displayPosts.filter((post) => !blockedUserIds.includes(post.authorId)),
    [blockedUserIds, displayPosts]
  );

  const pullLabel = refreshing
    ? "Refreshing..."
    : pullDistance > 60
    ? "Release to refresh"
    : "Pull to refresh";

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
              For You
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
                Following
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

        <PetSpotlight />

        {loading && !useMock ? (
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
              title="No posts from friends"
              description="Follow pet lovers to see their posts here"
              actionText="Discover People"
              onAction={() => navigate("/search")}
            />
          ) : (
            <EmptyState
              icon="📷"
              title="No posts yet"
              description="Be the first to share your pet!"
              actionText="Create Post"
              onAction={() => navigate("/create")}
            />
          )
        ) : null}

        {filteredPosts.map((post) => (
          <PostCard
            key={post.id}
            post={post}
            useMock={useMock}
            onDeleted={(postId) =>
              setLocalPosts((prev) => prev.filter((item) => item.id !== postId))
            }
          />
        ))}

        {!useMock ? (
          <div ref={sentinelRef} className="flex justify-center py-4">
            {loadingMore ? (
              <span className="h-6 w-6 animate-spin rounded-full border-2 border-purple-500 border-t-transparent" />
            ) : !hasMore && filteredPosts.length > 0 ? (
              <p className="text-xs text-slate-400 dark:text-slate-500">
                You&apos;ve seen all posts 🐾
              </p>
            ) : null}
          </div>
        ) : null}
      </main>

      <BottomNav />
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
