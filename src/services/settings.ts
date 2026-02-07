import {
  deleteDoc,
  doc,
  getDoc,
  setDoc,
} from "firebase/firestore";
import { deleteUser } from "firebase/auth";
import { auth, db } from "./firebase";
import { deletePost, getPostsByUser } from "./posts";
import { deletePet, getPetsByOwner } from "./pets";

export type UserSettings = {
  likeNotifications: boolean;
  commentNotifications: boolean;
  followNotifications: boolean;
  privateAccount: boolean;
};

const defaultSettings: UserSettings = {
  likeNotifications: true,
  commentNotifications: true,
  followNotifications: true,
  privateAccount: false,
};

const settingsRef = (userId: string) =>
  doc(db, "users", userId, "settings", "preferences");

export async function getSettings(userId: string): Promise<UserSettings> {
  const snapshot = await getDoc(settingsRef(userId));
  if (!snapshot.exists()) {
    return defaultSettings;
  }
  return {
    ...defaultSettings,
    ...(snapshot.data() as Partial<UserSettings>),
  };
}

export async function updateSettings(
  userId: string,
  settings: Partial<UserSettings>
): Promise<void> {
  await setDoc(settingsRef(userId), settings, { merge: true });
}

export async function deleteAccount(userId: string): Promise<void> {
  const posts = await getPostsByUser(userId);
  for (const post of posts) {
    await deletePost(post.id);
  }

  const pets = await getPetsByOwner(userId);
  for (const pet of pets) {
    await deletePet(pet.id);
  }

  await deleteDoc(settingsRef(userId));
  await deleteDoc(doc(db, "users", userId));

  if (auth.currentUser && auth.currentUser.uid === userId) {
    await deleteUser(auth.currentUser);
  }
}
