import {
  collection,
  doc,
  getDoc,
  getDocs,
  increment,
  limit,
  orderBy,
  query,
  serverTimestamp,
  setDoc,
  updateDoc,
  where,
} from "firebase/firestore";
import { db } from "./firebase";
import { type Post, type PostData } from "./posts";

export type Hashtag = {
  name: string;
  postCount: number;
  lastUsed: unknown;
};

export async function incrementTag(tagName: string): Promise<void> {
  const normalized = tagName.trim().toLowerCase();
  if (!normalized) return;
  const tagRef = doc(db, "hashtags", normalized);
  const tagSnap = await getDoc(tagRef);
  if (!tagSnap.exists()) {
    await setDoc(tagRef, {
      name: normalized,
      postCount: 1,
      lastUsed: serverTimestamp(),
    });
    return;
  }
  await updateDoc(tagRef, {
    postCount: increment(1),
    lastUsed: serverTimestamp(),
  });
}

export async function decrementTag(tagName: string): Promise<void> {
  const normalized = tagName.trim().toLowerCase();
  if (!normalized) return;
  const tagRef = doc(db, "hashtags", normalized);
  const tagSnap = await getDoc(tagRef);
  if (!tagSnap.exists()) return;
  await updateDoc(tagRef, {
    postCount: increment(-1),
    lastUsed: serverTimestamp(),
  });
}

export async function searchTags(queryText: string): Promise<Hashtag[]> {
  const keyword = queryText.trim().toLowerCase();
  if (!keyword) return [];
  const tagsRef = collection(db, "hashtags");
  const snapshot = await getDocs(tagsRef);
  return snapshot.docs
    .map((docSnap) => docSnap.data() as Hashtag)
    .filter((tag) => tag.name.includes(keyword))
    .sort((a, b) => (b.postCount ?? 0) - (a.postCount ?? 0))
    .slice(0, 10);
}

export async function getTrendingTags(limitCount = 8): Promise<Hashtag[]> {
  const tagsRef = collection(db, "hashtags");
  const tagsQuery = query(
    tagsRef,
    orderBy("postCount", "desc"),
    limit(limitCount)
  );
  const snapshot = await getDocs(tagsQuery);
  return snapshot.docs.map((docSnap) => docSnap.data() as Hashtag);
}

export async function getPostsByTag(tagName: string): Promise<Post[]> {
  const normalized = tagName.trim().toLowerCase();
  if (!normalized) return [];
  const postsRef = collection(db, "posts");
  const postsQuery = query(
    postsRef,
    where("tags", "array-contains", normalized),
    orderBy("createdAt", "desc")
  );
  const snapshot = await getDocs(postsQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as PostData),
  }));
}
