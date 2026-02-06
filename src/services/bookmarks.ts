import {
  collection,
  deleteDoc,
  doc,
  documentId,
  getDoc,
  getDocs,
  orderBy,
  query,
  serverTimestamp,
  setDoc,
  where,
} from "firebase/firestore";
import { db } from "./firebase";
import type { Post, PostData } from "./posts";

export async function bookmarkPost(
  userId: string,
  postId: string
): Promise<void> {
  const bookmarkRef = doc(db, "users", userId, "bookmarks", postId);
  await setDoc(
    bookmarkRef,
    {
      postId,
      createdAt: serverTimestamp(),
    },
    { merge: true }
  );
}

export async function unbookmarkPost(
  userId: string,
  postId: string
): Promise<void> {
  const bookmarkRef = doc(db, "users", userId, "bookmarks", postId);
  await deleteDoc(bookmarkRef);
}

export async function checkIfBookmarked(
  userId: string,
  postId: string
): Promise<boolean> {
  const bookmarkRef = doc(db, "users", userId, "bookmarks", postId);
  const snapshot = await getDoc(bookmarkRef);
  return snapshot.exists();
}

export async function getBookmarks(userId: string): Promise<string[]> {
  const bookmarksRef = collection(db, "users", userId, "bookmarks");
  const bookmarksQuery = query(bookmarksRef, orderBy("createdAt", "desc"));
  const snapshot = await getDocs(bookmarksQuery);
  return snapshot.docs.map((docSnap) => docSnap.id);
}

export async function getBookmarkedPosts(userId: string): Promise<Post[]> {
  const ids = await getBookmarks(userId);
  if (ids.length === 0) return [];

  const postsRef = collection(db, "posts");
  const chunkSize = 10;
  const posts: Post[] = [];
  for (let i = 0; i < ids.length; i += chunkSize) {
    const chunk = ids.slice(i, i + chunkSize);
    const postsQuery = query(postsRef, where(documentId(), "in", chunk));
    const snapshot = await getDocs(postsQuery);
    snapshot.docs.forEach((docSnap) => {
      posts.push({
        id: docSnap.id,
        ...(docSnap.data() as PostData),
      });
    });
  }

  const postsById = new Map(posts.map((post) => [post.id, post]));
  return ids.map((id) => postsById.get(id)).filter(Boolean) as Post[];
}
