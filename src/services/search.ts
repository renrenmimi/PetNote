import {
  collection,
  getDocs,
  limit,
  orderBy,
  query,
  where,
} from "firebase/firestore";
import { db } from "./firebase";
import { toPost, type Post } from "./posts";
import { type UserProfile } from "./users";
import { type Pet } from "./pets";

export async function searchByTag(tag: string): Promise<Post[]> {
  if (!tag) return [];
  const postsRef = collection(db, "posts");
  const postsQuery = query(
    postsRef,
    where("tags", "array-contains", tag.toLowerCase()),
    orderBy("createdAt", "desc"),
    limit(20)
  );
  const snapshot = await getDocs(postsQuery);
  return snapshot.docs.map((docSnap) => toPost(docSnap.id, docSnap.data()));
}

export async function searchByText(text: string): Promise<Post[]> {
  if (!text) return [];
  const keyword = text.trim().toLowerCase();
  if (!keyword) return [];

  // Firestore doesn't support full-text search natively.
  // Search by tag if input looks like a hashtag, otherwise search by tag match
  // as a best-effort structured search.
  const postsRef = collection(db, "posts");
  const tagQuery = query(
    postsRef,
    where("tags", "array-contains", keyword.replace(/^#/, "")),
    orderBy("createdAt", "desc"),
    limit(20)
  );
  const snapshot = await getDocs(tagQuery);
  return snapshot.docs.map((docSnap) => toPost(docSnap.id, docSnap.data()));
}

export async function searchUsers(name: string): Promise<UserProfile[]> {
  if (!name) return [];
  const keyword = name.trim().toLowerCase();
  if (!keyword) return [];
  const usersRef = collection(db, "users");
  const snapshot = await getDocs(
    query(
      usersRef,
      orderBy("displayNameLower"),
      where("displayNameLower", ">=", keyword),
      where("displayNameLower", "<=", `${keyword}\uf8ff`),
      limit(10)
    )
  );
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<UserProfile, "id">),
  }));
}

export async function searchPets(name: string): Promise<Pet[]> {
  if (!name) return [];
  const needle = name.trim();
  const keyword = name.trim().toLowerCase();
  if (!keyword) return [];
  const petsRef = collection(db, "pets");
  const [lowerSnapshot, snapshot] = await Promise.all([
    getDocs(
      query(
        petsRef,
        orderBy("nameLower"),
        where("nameLower", ">=", keyword),
        where("nameLower", "<=", `${keyword}\uf8ff`),
        limit(10)
      )
    ),
    getDocs(
      query(
        petsRef,
        orderBy("name"),
        where("name", ">=", needle),
        where("name", "<=", `${needle}\uf8ff`),
        limit(10)
      )
    ),
  ]);

  const merged = new Map<string, Pet>();
  lowerSnapshot.docs.forEach((docSnap) => {
    merged.set(docSnap.id, {
      id: docSnap.id,
      ...(docSnap.data() as Omit<Pet, "id">),
    });
  });
  snapshot.docs.forEach((docSnap) => {
    if (!merged.has(docSnap.id)) {
      merged.set(docSnap.id, {
        id: docSnap.id,
        ...(docSnap.data() as Omit<Pet, "id">),
      });
    }
  });

  return Array.from(merged.values()).slice(0, 10);
}

export async function getTrendingTags(): Promise<string[]> {
  return [
    "cat",
    "dog",
    "puppy",
    "kitten",
    "cute",
    "funny",
    "golden",
    "husky",
  ];
}
