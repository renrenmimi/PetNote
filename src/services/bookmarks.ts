import {
  collection,
  deleteDoc,
  doc,
  documentId,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  serverTimestamp,
  setDoc,
  startAfter,
  type QueryConstraint,
  type QueryDocumentSnapshot,
  where,
} from "firebase/firestore";
import { db } from "./firebase";
import { toPost, type Post } from "./posts";

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

export async function getBookmarks(
  userId: string,
  options?: { limitCount?: number; lastDoc?: QueryDocumentSnapshot }
): Promise<{
  ids: string[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  const limitCount = options?.limitCount ?? 50;
  const bookmarksRef = collection(db, "users", userId, "bookmarks");
  const constraints: QueryConstraint[] = [
    orderBy("createdAt", "desc"),
    limit(limitCount),
  ];
  if (options?.lastDoc) {
    constraints.push(startAfter(options.lastDoc));
  }
  const snapshot = await getDocs(query(bookmarksRef, ...constraints));
  const ids = snapshot.docs.map((docSnap) => docSnap.id);
  const nextLast =
    (snapshot.docs[snapshot.docs.length - 1] as
      | QueryDocumentSnapshot
      | undefined) ?? null;
  return {
    ids,
    lastDoc: nextLast,
    hasMore: snapshot.docs.length === limitCount,
  };
}

export async function getBookmarkedPosts(
  userId: string,
  options?: { limitCount?: number; lastDoc?: QueryDocumentSnapshot }
): Promise<{
  posts: Post[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  const { ids, lastDoc, hasMore } = await getBookmarks(userId, options);
  if (ids.length === 0) {
    return { posts: [], lastDoc, hasMore };
  }

  const postsRef = collection(db, "posts");
  const chunkSize = 10;
  const posts: Post[] = [];
  for (let i = 0; i < ids.length; i += chunkSize) {
    const chunk = ids.slice(i, i + chunkSize);
    const postsQuery = query(postsRef, where(documentId(), "in", chunk));
    const snapshot = await getDocs(postsQuery);
    snapshot.docs.forEach((docSnap) => {
      posts.push(toPost(docSnap.id, docSnap.data()));
    });
  }

  const postsById = new Map(posts.map((post) => [post.id, post]));
  const ordered = ids
    .map((id) => postsById.get(id))
    .filter(Boolean) as Post[];
  return { posts: ordered, lastDoc, hasMore };
}
