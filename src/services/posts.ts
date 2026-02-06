import {
  addDoc,
  collection,
  doc,
  getDoc,
  getDocs,
  increment,
  orderBy,
  query,
  runTransaction,
  serverTimestamp,
  where,
  writeBatch,
} from "firebase/firestore";
import { db } from "./firebase";
import { decrementTag, incrementTag } from "./hashtags";
import { createNotification } from "./notifications";
import { getUserProfile } from "./users";

export interface PostData {
  authorId: string;
  authorName: string;
  authorAvatar: string;
  text: string;
  mediaUrl: string;
  mediaType: "image" | "video";
  createdAt: any;
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
};

export type CreatePostInput = Omit<
  PostData,
  "createdAt" | "likeCount" | "commentCount"
>;

const normalizeTags = (tags: string[]) => {
  const set = new Set(
    tags
      .map((tag) => tag.trim().toLowerCase().replace(/^#/, ""))
      .filter(Boolean)
  );
  return Array.from(set);
};

export async function createPost(data: CreatePostInput): Promise<string> {
  const postsRef = collection(db, "posts");
  const tags = normalizeTags(data.tags);
  const payload = {
    ...data,
    tags,
    createdAt: serverTimestamp(),
    likeCount: 0,
    commentCount: 0,
  };
  const result = await addDoc(postsRef, payload);
  await Promise.all(tags.map((tag) => incrementTag(tag)));
  return result.id;
}

export async function getPosts(): Promise<Post[]> {
  const postsRef = collection(db, "posts");
  const postsQuery = query(postsRef, orderBy("createdAt", "desc"));
  const snapshot = await getDocs(postsQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as PostData),
  }));
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

export async function likePost(postId: string, userId: string): Promise<void> {
  const postRef = doc(db, "posts", postId);
  const likeRef = doc(db, "posts", postId, "likes", userId);
  const postSnap = await getDoc(postRef);
  if (!postSnap.exists()) {
    return;
  }
  const postData = postSnap.data() as PostData;
  let didLike = false;

  await runTransaction(db, async (transaction) => {
    const likeSnap = await transaction.get(likeRef);
    if (likeSnap.exists()) {
      return;
    }

    transaction.set(likeRef, {
      userId,
      createdAt: serverTimestamp(),
    });
    transaction.update(postRef, {
      likeCount: increment(1),
    });
    didLike = true;
  });

  if (didLike && postData.authorId !== userId) {
    const profile = await getUserProfile(userId);
    await createNotification({
      userId: postData.authorId,
      type: "like",
      fromUserId: userId,
      fromUserName: profile?.displayName || "PetNote User",
      fromUserAvatar:
        profile?.avatarUrl || "https://i.pravatar.cc/150?img=12",
      postId,
      postImage: postData.mediaUrl,
      message: "liked your post",
    });
  }
}

export async function unlikePost(postId: string, userId: string): Promise<void> {
  const postRef = doc(db, "posts", postId);
  const likeRef = doc(db, "posts", postId, "likes", userId);

  await runTransaction(db, async (transaction) => {
    const likeSnap = await transaction.get(likeRef);
    if (!likeSnap.exists()) {
      return;
    }

    transaction.delete(likeRef);
    transaction.update(postRef, {
      likeCount: increment(-1),
    });
  });
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
  const commentsRef = collection(db, "posts", postId, "comments");
  const payload = {
    ...comment,
    createdAt: comment.createdAt ?? serverTimestamp(),
  };
  const postRef = doc(db, "posts", postId);
  const postSnap = await getDoc(postRef);
  if (!postSnap.exists()) {
    return "";
  }
  const postData = postSnap.data() as PostData;
  const result = await runTransaction(db, async (transaction) => {
    const newCommentRef = doc(commentsRef);
    transaction.set(newCommentRef, payload);
    transaction.update(postRef, {
      commentCount: increment(1),
    });
    return newCommentRef.id;
  });
  if (result && postData.authorId !== comment.authorId) {
    await createNotification({
      userId: postData.authorId,
      type: "comment",
      fromUserId: comment.authorId,
      fromUserName: comment.authorName || "PetNote User",
      fromUserAvatar:
        comment.authorAvatar || "https://i.pravatar.cc/150?img=12",
      postId,
      postImage: postData.mediaUrl,
      message: "commented on your post",
    });
  }
  return result;
}

export async function deletePost(postId: string): Promise<void> {
  const postRef = doc(db, "posts", postId);
  const postSnap = await getDoc(postRef);
  if (!postSnap.exists()) return;
  const postData = postSnap.data() as PostData;

  const likesRef = collection(db, "posts", postId, "likes");
  const commentsRef = collection(db, "posts", postId, "comments");
  const [likesSnap, commentsSnap] = await Promise.all([
    getDocs(likesRef),
    getDocs(commentsRef),
  ]);

  const deleteInChunks = async (docs: typeof likesSnap.docs) => {
    const chunkSize = 450;
    for (let i = 0; i < docs.length; i += chunkSize) {
      const batch = writeBatch(db);
      docs.slice(i, i + chunkSize).forEach((docSnap) => {
        batch.delete(docSnap.ref);
      });
      await batch.commit();
    }
  };

  await deleteInChunks(likesSnap.docs);
  await deleteInChunks(commentsSnap.docs);

  const finalBatch = writeBatch(db);
  finalBatch.delete(postRef);
  await finalBatch.commit();

  await Promise.all(postData.tags.map((tag) => decrementTag(tag)));
}

export async function getComments(postId: string): Promise<Comment[]> {
  const commentsRef = collection(db, "posts", postId, "comments");
  const commentsQuery = query(commentsRef, orderBy("createdAt", "desc"));
  const snapshot = await getDocs(commentsQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Comment, "id">),
  }));
}

export async function getPostsByUser(userId: string): Promise<Post[]> {
  const postsRef = collection(db, "posts");
  const postsQuery = query(
    postsRef,
    where("authorId", "==", userId),
    orderBy("createdAt", "desc")
  );
  const snapshot = await getDocs(postsQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as PostData),
  }));
}

export async function getUserStats(userId: string): Promise<{
  postCount: number;
  totalLikes: number;
}> {
  const posts = await getPostsByUser(userId);
  const totalLikes = posts.reduce(
    (sum, post) => sum + (post.likeCount ?? 0),
    0
  );
  return { postCount: posts.length, totalLikes };
}
