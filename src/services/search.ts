import {
  collection,
  getDocs,
  limit,
  orderBy,
  query,
  where,
} from "firebase/firestore";
import { db } from "./firebase";
import { type Post } from "./posts";
import { type UserProfile } from "./users";

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
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Post, "id">),
  }));
}

export async function searchByText(text: string): Promise<Post[]> {
  if (!text) return [];
  const postsRef = collection(db, "posts");
  const snapshot = await getDocs(postsRef);
  const keyword = text.toLowerCase();
  return snapshot.docs
    .map((docSnap) => ({
      id: docSnap.id,
      ...(docSnap.data() as Omit<Post, "id">),
    }))
    .filter((post) => post.text?.toLowerCase().includes(keyword))
    .slice(0, 20);
}

export async function searchUsers(name: string): Promise<UserProfile[]> {
  if (!name) return [];
  const usersRef = collection(db, "users");
  const snapshot = await getDocs(usersRef);
  const keyword = name.toLowerCase();
  return snapshot.docs
    .map((docSnap) => ({
      id: docSnap.id,
      ...(docSnap.data() as Omit<UserProfile, "id">),
    }))
    .filter((user) => {
      const display = user.displayName?.toLowerCase() ?? "";
      const email = user.email?.toLowerCase() ?? "";
      return display.includes(keyword) || email.includes(keyword);
    })
    .slice(0, 20);
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
