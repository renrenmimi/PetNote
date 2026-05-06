import {
  collection,
  count,
  deleteDoc,
  doc,
  getAggregateFromServer,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  runTransaction,
  serverTimestamp,
  sum,
  Timestamp,
  startAfter,
  type QueryConstraint,
  type QueryDocumentSnapshot,
  where,
} from "firebase/firestore";
import { httpsCallable } from "firebase/functions";
import { db, functions } from "./firebase";
// Tag counting handled by onPostWritten Cloud Function
import { getFollowingPets } from "./follow";

export type MediaItem = {
  url: string;
  type: "image" | "video";
  thumbUrl?: string;
};

export interface PostData {
  authorId: string;
  authorName: string;
  authorAvatar: string;
  text: string;
  mediaUrl?: string;
  mediaType?: "image" | "video";
  media?: MediaItem[];
  petId?: string;
  petName?: string;
  petAvatarUrl?: string;
  createdAt: Timestamp;
  likeCount: number;
  commentCount: number;
  tags: string[];
}

export type Post = PostData & { id: string };

export type Comment = {
  id?: string;
  authorId: string;
  authorName: string;
  authorAvatar?: string;
  text: string;
  createdAt?: unknown;
  replyTo?: {
    commentId: string;
    authorName: string;
  };
};

export type CreatePostInput = Omit<
  PostData,
  | "createdAt"
  | "likeCount"
  | "commentCount"
  | "mediaUrl"
  | "mediaType"
  | "petId"
  | "petName"
  | "petAvatarUrl"
> & {
  media: MediaItem[];
  petId: string;
  petName: string;
  petAvatarUrl: string;
};

export type UpdatePostInput = {
  text: string;
  tags: string[];
  petId?: string | null;
  petName?: string;
  petAvatarUrl?: string;
};

export async function createPost(data: CreatePostInput): Promise<string> {
  if (!data.petId) {
    throw new Error("Please select a pet before posting.");
  }
  const result = await httpsCallable<
    { text: string; tags: string[]; media: MediaItem[]; petId: string },
    { id: string }
  >(functions, "createPostCallable")({
    text: data.text,
    tags: data.tags,
    media: data.media,
    petId: data.petId,
  });
  return result.data.id;
}

export async function updatePost(
  postId: string,
  data: UpdatePostInput
): Promise<void> {
  await httpsCallable<
    { postId: string; text: string; tags: string[]; petId?: string | null },
    { success: boolean }
  >(functions, "updatePostCallable")({
    postId,
    text: data.text,
    tags: data.tags,
    petId: data.petId ?? null,
  });
}

export async function getPosts(
  limitCount = 10,
  lastDoc?: QueryDocumentSnapshot
): Promise<{
  posts: Post[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  const postsRef = collection(db, "posts");
  const constraints: QueryConstraint[] = [
    orderBy("createdAt", "desc"),
    limit(limitCount),
  ];
  if (lastDoc) {
    constraints.push(startAfter(lastDoc));
  }
  const postsQuery = query(postsRef, ...constraints);
  const snapshot = await getDocs(postsQuery);
  const posts = snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as PostData),
  }));
  const nextLastDoc =
    (snapshot.docs[snapshot.docs.length - 1] as QueryDocumentSnapshot | undefined) ?? null;
  const hasMore = snapshot.docs.length === limitCount;
  return { posts, lastDoc: nextLastDoc, hasMore };
}

export async function getPopularPosts(
  limitCount = 10,
  hours = 24
): Promise<Post[]> {
  const postsRef = collection(db, "posts");
  const cutoff = Timestamp.fromDate(
    new Date(Date.now() - hours * 60 * 60 * 1000)
  );
  const postsQuery = query(
    postsRef,
    where("createdAt", ">=", cutoff),
    orderBy("createdAt", "desc"),
    limit(Math.max(limitCount * 10, 50))
  );
  const snapshot = await getDocs(postsQuery);
  return snapshot.docs
    .map((docSnap) => ({
      id: docSnap.id,
      ...(docSnap.data() as PostData),
    }))
    .sort((a, b) => {
      const likeDelta = (b.likeCount ?? 0) - (a.likeCount ?? 0);
      if (likeDelta !== 0) return likeDelta;
      return (b.createdAt?.toMillis?.() ?? 0) - (a.createdAt?.toMillis?.() ?? 0);
    })
    .slice(0, limitCount);
}

export async function getPostById(id: string): Promise<Post | null> {
  const docRef = doc(db, "posts", id);
  const snapshot = await getDoc(docRef);
  if (!snapshot.exists()) {
    return null;
  }

  return {
    id: snapshot.id,
    ...(snapshot.data() as PostData),
  };
}

export async function getFollowingPosts(
  userId: string,
  limitCount = 10,
  lastDoc?: QueryDocumentSnapshot
): Promise<{
  posts: Post[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  const followingPets = await getFollowingPets(userId);
  const petIds = Array.from(
    new Set(followingPets.map((item) => item.petId).filter(Boolean))
  );
  if (petIds.length === 0) {
    return { posts: [], lastDoc: null, hasMore: false };
  }

  // Firestore "in" queries support max 30 values; split into chunks and merge.
  // Use a value-based cursor (createdAt < lastSeenCreatedAt) because a
  // DocumentSnapshot cursor is scoped to the specific query that produced it
  // and will return wrong results when reused across different "in" chunks.
  const cursorTimestamp =
    (lastDoc?.data() as PostData | undefined)?.createdAt ?? null;

  const chunkSize = 30;
  const postsRef = collection(db, "posts");
  const allDocs: QueryDocumentSnapshot[] = [];
  // Fetch extra to ensure we have enough after deduplication/merge
  const perChunkLimit = limitCount + 5;

  for (let i = 0; i < petIds.length; i += chunkSize) {
    const chunk = petIds.slice(i, i + chunkSize);
    const constraints: QueryConstraint[] = [
      where("petId", "in", chunk),
      ...(cursorTimestamp
        ? [where("createdAt", "<", cursorTimestamp)]
        : []),
      orderBy("createdAt", "desc"),
      limit(perChunkLimit),
    ];
    const snapshot = await getDocs(query(postsRef, ...constraints));
    allDocs.push(...(snapshot.docs as QueryDocumentSnapshot[]));
  }

  // Deduplicate by doc ID (in case of overlap), sort by createdAt desc
  const seen = new Set<string>();
  const unique = allDocs.filter((d) => {
    if (seen.has(d.id)) return false;
    seen.add(d.id);
    return true;
  });
  unique.sort((a, b) => {
    const aTime = (a.data() as PostData).createdAt?.toMillis?.() ?? 0;
    const bTime = (b.data() as PostData).createdAt?.toMillis?.() ?? 0;
    return bTime - aTime;
  });

  const limited = unique.slice(0, limitCount);
  const posts = limited.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as PostData),
  }));
  // Use the last doc from the merged result as the cursor for next page
  const nextLastDoc = limited[limited.length - 1] ?? null;
  const hasMore = limited.length === limitCount;
  return { posts, lastDoc: nextLastDoc, hasMore };
}

export async function likePost(postId: string, userId: string): Promise<void> {
  const postRef = doc(db, "posts", postId);
  const likeRef = doc(db, "posts", postId, "likes", userId);
  const postSnap = await getDoc(postRef);
  if (!postSnap.exists()) {
    return;
  }
  let didLike = false;

  // Count increment handled by onLikeCreated Cloud Function.
  await runTransaction(db, async (transaction) => {
    const likeSnap = await transaction.get(likeRef);
    if (likeSnap.exists()) {
      return;
    }

    transaction.set(likeRef, {
      userId,
      createdAt: serverTimestamp(),
    });
    didLike = true;
  });

  if (!didLike) return;
}

export async function unlikePost(postId: string, userId: string): Promise<void> {
  // Only delete the like doc. Count decrement is handled by
  // onLikeDeleted Cloud Function to avoid double-decrement.
  const likeRef = doc(db, "posts", postId, "likes", userId);
  const likeSnap = await getDoc(likeRef);
  if (!likeSnap.exists()) return;
  await deleteDoc(likeRef);
}

export async function checkIfLiked(
  postId: string,
  userId: string
): Promise<boolean> {
  const likeRef = doc(db, "posts", postId, "likes", userId);
  const snapshot = await getDoc(likeRef);
  return snapshot.exists();
}

export async function addComment(
  postId: string,
  comment: Comment
): Promise<string> {
  const result = await httpsCallable<
    { postId: string; text: string; replyToCommentId?: string },
    { id: string }
  >(functions, "createCommentCallable")({
    postId,
    text: comment.text,
    replyToCommentId: comment.replyTo?.commentId,
  });
  return result.data.id;
}

export async function deleteComment(
  postId: string,
  commentId: string
): Promise<void> {
  await httpsCallable<{ postId: string; commentId: string }, { success: boolean }>(
    functions,
    "deleteCommentCallable"
  )({ postId, commentId });
}

export async function deletePost(postId: string): Promise<void> {
  await httpsCallable<{ postId: string }, { success: boolean }>(
    functions,
    "deletePostCallable"
  )({ postId });
}

export async function getComments(
  postId: string,
  options?: { limitCount?: number; lastDoc?: QueryDocumentSnapshot }
): Promise<{
  comments: Comment[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  const limitCount = options?.limitCount ?? 50;
  const commentsRef = collection(db, "posts", postId, "comments");
  const constraints: QueryConstraint[] = [
    orderBy("createdAt", "desc"),
    limit(limitCount),
  ];
  if (options?.lastDoc) {
    constraints.push(startAfter(options.lastDoc));
  }
  const snapshot = await getDocs(query(commentsRef, ...constraints));
  const comments = snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Comment, "id">),
  }));
  const nextLast =
    (snapshot.docs[snapshot.docs.length - 1] as
      | QueryDocumentSnapshot
      | undefined) ?? null;
  return {
    comments,
    lastDoc: nextLast,
    hasMore: snapshot.docs.length === limitCount,
  };
}

export async function getPostsByUser(
  userId: string,
  options?: { limitCount?: number; lastDoc?: QueryDocumentSnapshot }
): Promise<{
  posts: Post[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  const limitCount = options?.limitCount ?? 20;
  const postsRef = collection(db, "posts");
  const constraints: QueryConstraint[] = [
    where("authorId", "==", userId),
    orderBy("createdAt", "desc"),
    limit(limitCount),
  ];
  if (options?.lastDoc) {
    constraints.push(startAfter(options.lastDoc));
  }
  const snapshot = await getDocs(query(postsRef, ...constraints));
  const posts = snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as PostData),
  }));
  const nextLast =
    (snapshot.docs[snapshot.docs.length - 1] as
      | QueryDocumentSnapshot
      | undefined) ?? null;
  return {
    posts,
    lastDoc: nextLast,
    hasMore: snapshot.docs.length === limitCount,
  };
}

export async function getUserStats(userId: string): Promise<{
  postCount: number;
  totalLikes: number;
}> {
  // Aggregate query: Firestore returns count and sum without scanning every
  // document, so this stays cheap even for users with thousands of posts.
  const postsRef = collection(db, "posts");
  const userPostsQuery = query(postsRef, where("authorId", "==", userId));
  const aggSnap = await getAggregateFromServer(userPostsQuery, {
    postCount: count(),
    totalLikes: sum("likeCount"),
  });
  const data = aggSnap.data();
  return {
    postCount: typeof data.postCount === "number" ? data.postCount : 0,
    totalLikes: typeof data.totalLikes === "number" ? data.totalLikes : 0,
  };
}

export async function pinPost(postId: string): Promise<void> {
  await httpsCallable<{ postId: string }, { success: boolean }>(
    functions,
    "setPinnedPostCallable"
  )({ postId });
}

export async function unpinPost(): Promise<void> {
  await httpsCallable<{ postId: null }, { success: boolean }>(
    functions,
    "setPinnedPostCallable"
  )({ postId: null });
}
