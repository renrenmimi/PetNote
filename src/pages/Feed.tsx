import { useEffect, useMemo, useState } from "react";
import { BottomNav } from "../components/BottomNav";
import { Navbar } from "../components/Navbar";
import { PostCard } from "../components/PostCard";
import { usePosts } from "../hooks/usePosts";
import { type Post } from "../services/posts";

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

const mockStories = [
  { id: "s1", name: "Luna", avatar: "https://i.pravatar.cc/150?img=11" },
  { id: "s2", name: "Milo", avatar: "https://i.pravatar.cc/150?img=12" },
  { id: "s3", name: "Coco", avatar: "https://i.pravatar.cc/150?img=13" },
  { id: "s4", name: "Rocky", avatar: "https://i.pravatar.cc/150?img=14" },
  { id: "s5", name: "Bella", avatar: "https://i.pravatar.cc/150?img=15" },
  { id: "s6", name: "Ollie", avatar: "https://i.pravatar.cc/150?img=16" },
];

function FeedSkeleton() {
  return (
    <div className="space-y-4">
      {[1, 2, 3].map((item) => (
        <div
          key={item}
          className="animate-pulse overflow-hidden rounded-2xl bg-white p-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100"
        >
          <div className="flex items-center gap-3">
            <div className="h-10 w-10 rounded-full bg-slate-200" />
            <div className="space-y-2">
              <div className="h-3 w-24 rounded bg-slate-200" />
              <div className="h-3 w-16 rounded bg-slate-200" />
            </div>
          </div>
          <div className="mt-4 h-48 w-full rounded-xl bg-slate-200" />
          <div className="mt-4 space-y-2">
            <div className="h-3 w-32 rounded bg-slate-200" />
            <div className="h-3 w-2/3 rounded bg-slate-200" />
          </div>
        </div>
      ))}
    </div>
  );
}

export function Feed() {
  const { posts, loading, error } = usePosts();
  const useMock = false;
  const [localPosts, setLocalPosts] = useState<Post[]>([]);

  useEffect(() => {
    if (!useMock) {
      setLocalPosts(posts);
    }
  }, [posts, useMock]);

  const displayPosts = useMemo(
    () => (useMock ? mockPosts : localPosts),
    [useMock, localPosts],
  );

  return (
    <div className="min-h-screen bg-slate-50 pb-20">
      <Navbar />

      <main className="mx-auto w-full max-w-md space-y-4 px-4 py-4">
        <p className="text-center text-xs text-slate-400">Pull to refresh</p>

        <section className="rounded-2xl bg-white px-4 py-3 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 transition-all duration-200">
          <div className="flex items-center justify-between">
            <h2 className="text-sm font-semibold text-slate-900">Stories</h2>
            <button
              type="button"
              className="text-xs font-semibold text-purple-600 transition-all duration-200 hover:scale-105"
            >
              See all
            </button>
          </div>
          <div className="mt-3 flex gap-4 overflow-x-auto pb-1">
            {mockStories.map((story) => (
              <button
                key={story.id}
                type="button"
                className="flex flex-col items-center gap-2 transition-all duration-200 hover:scale-105"
              >
                <span className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 p-[2px]">
                  <img
                    src={story.avatar}
                    alt={story.name}
                    className="h-14 w-14 rounded-full border-2 border-white object-cover"
                  />
                </span>
                <span className="text-xs text-slate-600">{story.name}</span>
              </button>
            ))}
          </div>
        </section>

        {loading && !useMock ? <FeedSkeleton /> : null}

        {!loading && error ? (
          <div className="rounded-2xl bg-white p-6 text-center text-sm text-red-500 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)]">
            {error}
          </div>
        ) : null}

        {!loading && displayPosts.length === 0 ? (
          <div className="rounded-2xl bg-white p-8 text-center text-sm text-slate-500 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)]">
            No posts yet, be the first to share your pet! 🐾
          </div>
        ) : null}

        {displayPosts.map((post) => (
          <PostCard
            key={post.id}
            post={post}
            useMock={useMock}
            onDeleted={(postId) =>
              setLocalPosts((prev) => prev.filter((item) => item.id !== postId))
            }
          />
        ))}
      </main>

      <BottomNav />
    </div>
  );
}
