import {
  addDoc,
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  increment,
  orderBy,
  query,
  runTransaction,
  serverTimestamp,
} from "firebase/firestore";
import { db } from "./firebase";

export type Post = {
  id: string;
  authorId: string;
  authorName: string;
  authorAvatar: string;
  text: string;
  mediaUrl: string;
  mediaType: "image" | "video";
  createdAt: unknown;
  likeCount: number;
  commentCount: number;
  tags: string[];
};

export type Comment = {
  id?: string;
  authorId: string;
  authorName: string;
  authorAvatar?: string;
  text: string;
  createdAt?: unknown;
};

export async function getPosts(): Promise<Post[]> {
  const postsRef = collection(db, "posts");
  const postsQuery = query(postsRef, orderBy("createdAt", "desc"));
  const snapshot = await getDocs(postsQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Post, "id">),
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
    ...(snapshot.data() as Omit<Post, "id">),
  };
}

export async function likePost(postId: string, userId: string): Promise<void> {
  const postRef = doc(db, "posts", postId);
  const likeRef = doc(db, "posts", postId, "likes", userId);

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
  });
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
  const result = await addDoc(commentsRef, payload);
  return result.id;
}

export async function getComments(postId: string): Promise<Comment[]> {
  const commentsRef = collection(db, "posts", postId, "comments");
  const commentsQuery = query(commentsRef, orderBy("createdAt", "asc"));
  const snapshot = await getDocs(commentsQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Comment, "id">),
  }));
}
