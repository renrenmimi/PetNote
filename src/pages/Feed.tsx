import { useMemo } from "react";
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

function FeedSkeleton() {
  return (
    <div className="space-y-4">
      {[1, 2, 3].map((item) => (
        <div
          key={item}
          className="animate-pulse overflow-hidden rounded-2xl bg-white p-4 shadow-sm ring-1 ring-slate-100"
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

  const displayPosts = useMemo(
    () => (useMock ? mockPosts : posts),
    [useMock, posts],
  );

  return (
    <div className="min-h-screen bg-slate-50 pb-20">
      <Navbar />

      <main className="mx-auto w-full max-w-md space-y-4 px-4 py-4">
        {loading && !useMock ? <FeedSkeleton /> : null}

        {!loading && error ? (
          <div className="rounded-2xl bg-white p-6 text-center text-sm text-red-500 shadow-sm">
            {error}
          </div>
        ) : null}

        {!loading && displayPosts.length === 0 ? (
          <div className="rounded-2xl bg-white p-8 text-center text-sm text-slate-500 shadow-sm">
            No posts yet, be the first to share your pet! 🐾
          </div>
        ) : null}

        {displayPosts.map((post) => (
          <PostCard key={post.id} post={post} useMock={useMock} />
        ))}
      </main>

      <BottomNav />
    </div>
  );
}
