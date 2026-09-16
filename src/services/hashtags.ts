import {
  collection,
  getDocs,
  limit,
  orderBy,
  query,
  startAfter,
  where,
  type QueryConstraint,
  type QueryDocumentSnapshot,
} from "firebase/firestore";
import { db } from "./firebase";
import { toPost, type Post } from "./posts";

export type Hashtag = {
  name: string;
  postCount: number;
  lastUsed: unknown;
};

// NOTE: client-side incrementTag/decrementTag were removed — Firestore
// rules only allow admin writes to /hashtags, so any client call would
// reject. Tag counts are maintained by the onPostWritten Cloud Function.

export async function searchTags(queryText: string): Promise<Hashtag[]> {
  const keyword = queryText.trim().toLowerCase();
  if (!keyword) return [];
  const tagsRef = collection(db, "hashtags");
  const tagsQuery = query(
    tagsRef,
    where("name", ">=", keyword),
    where("name", "<=", `${keyword}`),
    orderBy("name"),
    limit(10)
  );
  const snapshot = await getDocs(tagsQuery);
  return snapshot.docs
    .map((docSnap) => docSnap.data() as Hashtag)
    .sort((a, b) => (b.postCount ?? 0) - (a.postCount ?? 0));
}

/**
 * The most-used tags, all time.
 *
 * There is **no time window** here, and the name is older than the query.
 * `postCount` is a lifetime total, so this answers "which tags have been used
 * most since the app existed" — which on a small catalogue means tags with
 * one or two posts. The Search screen therefore does not call the result
 * "trending": see the heading there, which is derived from the actual counts.
 *
 * Adding a window would need a rolling per-tag count, which is a counter
 * design question and not a label fix. Left as it is, named honestly at the
 * point of display.
 */
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

// Paginated. A popular tag (#dogs etc.) can match thousands of posts —
// without a limit, opening Search?tag=dogs would have downloaded the
// entire history on every render. Default page size matches the other
// feed endpoints.
export async function getPostsByTag(
  tagName: string,
  options?: { limitCount?: number; lastDoc?: QueryDocumentSnapshot }
): Promise<{
  posts: Post[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  const normalized = tagName.trim().toLowerCase();
  if (!normalized) return { posts: [], lastDoc: null, hasMore: false };
  const limitCount = options?.limitCount ?? 50;
  const postsRef = collection(db, "posts");
  const constraints: QueryConstraint[] = [
    where("tags", "array-contains", normalized),
    orderBy("createdAt", "desc"),
    limit(limitCount),
  ];
  if (options?.lastDoc) {
    constraints.push(startAfter(options.lastDoc));
  }
  const snapshot = await getDocs(query(postsRef, ...constraints));
  const posts = snapshot.docs.map((docSnap) => toPost(docSnap.id, docSnap.data()));
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
