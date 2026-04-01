import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  query,
  setDoc,
  where,
  writeBatch,
  collectionGroup,
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

async function deleteSubcollection(parentPath: string, subcollection: string): Promise<void> {
  const ref = collection(db, parentPath, subcollection);
  const snapshot = await getDocs(ref);
  if (snapshot.empty) return;
  const chunkSize = 450;
  for (let i = 0; i < snapshot.docs.length; i += chunkSize) {
    const batch = writeBatch(db);
    snapshot.docs.slice(i, i + chunkSize).forEach((d) => batch.delete(d.ref));
    await batch.commit();
  }
}

async function deleteCollectionGroupDocs(collectionName: string, field: string, value: string): Promise<void> {
  const q = query(collectionGroup(db, collectionName), where(field, "==", value));
  const snapshot = await getDocs(q);
  if (snapshot.empty) return;
  const chunkSize = 450;
  for (let i = 0; i < snapshot.docs.length; i += chunkSize) {
    const batch = writeBatch(db);
    snapshot.docs.slice(i, i + chunkSize).forEach((d) => batch.delete(d.ref));
    await batch.commit();
  }
}

export async function deleteAccount(userId: string): Promise<void> {
  // Delete user's posts (each post cascades its own likes/comments/tags)
  const posts = await getPostsByUser(userId);
  for (const post of posts) {
    await deletePost(post.id);
  }

  // Delete user's owned pets (each pet cascades its own subcollections)
  const pets = await getPetsByOwner(userId);
  for (const pet of pets) {
    await deletePet(pet.id);
  }

  // Clean up user's notifications
  const notificationsQuery = query(
    collection(db, "notifications"),
    where("userId", "==", userId)
  );
  const notifSnap = await getDocs(notificationsQuery);
  if (!notifSnap.empty) {
    const batch = writeBatch(db);
    notifSnap.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
  }

  // Clean up user's comments across all posts
  await deleteCollectionGroupDocs("comments", "authorId", userId);

  // Clean up user's likes across all posts
  await deleteCollectionGroupDocs("likes", "userId", userId);

  // Clean up user's checkins across all locations
  await deleteCollectionGroupDocs("checkins", "userId", userId);

  // Clean up user's reviews across all locations
  await deleteCollectionGroupDocs("reviews", "userId", userId);

  // Clean up user's meetup participations
  await deleteCollectionGroupDocs("participants", "userId", userId);

  // Clean up user's pet family memberships (where user is a member, not owner)
  await deleteCollectionGroupDocs("family", "userId", userId);

  // Clean up user subcollections
  await deleteSubcollection(`users/${userId}`, "bookmarks");
  await deleteSubcollection(`users/${userId}`, "followingPets");
  await deleteSubcollection(`users/${userId}`, "followers");
  await deleteSubcollection(`users/${userId}`, "following");
  await deleteSubcollection(`users/${userId}`, "blockedUsers");

  // Delete settings and user document
  await deleteDoc(settingsRef(userId));
  await deleteDoc(doc(db, "users", userId));

  // Delete Firebase Auth account
  if (auth.currentUser && auth.currentUser.uid === userId) {
    await deleteUser(auth.currentUser);
  }
}
