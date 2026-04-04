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
import { db } from "./firebase";
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
  // All Firestore cleanup runs WHILE the user is still authenticated.
  // deleteUser() is called LAST because it invalidates the auth token.

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

  // Clean up notifications received by user (rules: userId == auth.uid)
  const receivedNotifQuery = query(
    collection(db, "notifications"),
    where("userId", "==", userId)
  );
  const receivedNotifSnap = await getDocs(receivedNotifQuery);
  if (!receivedNotifSnap.empty) {
    const batch = writeBatch(db);
    receivedNotifSnap.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
  }

  // Clean up notifications sent by user (rules: fromUserId == auth.uid)
  const sentNotifQuery = query(
    collection(db, "notifications"),
    where("fromUserId", "==", userId)
  );
  const sentNotifSnap = await getDocs(sentNotifQuery);
  if (!sentNotifSnap.empty) {
    const batch = writeBatch(db);
    sentNotifSnap.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
  }

  // Clean up user's comments across all posts (rules: collection group read allowed)
  await deleteCollectionGroupDocs("comments", "authorId", userId);

  // Clean up user's likes across all posts (rules: collection group read allowed)
  await deleteCollectionGroupDocs("likes", "userId", userId);

  // Clean up user's checkins across all locations (rules: collection group read allowed)
  await deleteCollectionGroupDocs("checkins", "userId", userId);

  // Clean up user's reviews across all locations (rules: collection group read allowed)
  await deleteCollectionGroupDocs("reviews", "userId", userId);

  // Clean up user's meetup participations (rules: collection group read allowed)
  await deleteCollectionGroupDocs("participants", "userId", userId);

  // Clean up user's pet family memberships (rules: collection group read allowed)
  await deleteCollectionGroupDocs("family", "userId", userId);

  // Clean up meetups organized by user (rules: meetups readable by all, deletable by organizer)
  const meetupsQuery = query(
    collection(db, "meetups"),
    where("organizerId", "==", userId)
  );
  const meetupsSnap = await getDocs(meetupsQuery);
  for (const meetupDoc of meetupsSnap.docs) {
    await deleteSubcollection(`meetups/${meetupDoc.id}`, "participants");
    await deleteDoc(meetupDoc.ref);
  }

  // Clean up reports submitted by user (rules: reporterId == auth.uid can read/delete)
  const reportsQuery = query(
    collection(db, "reports"),
    where("reporterId", "==", userId)
  );
  const reportsSnap = await getDocs(reportsQuery);
  if (!reportsSnap.empty) {
    const batch = writeBatch(db);
    reportsSnap.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
  }

  // Clean up feedback submitted by user (rules: userId == auth.uid can read/delete)
  const feedbackQuery = query(
    collection(db, "feedback"),
    where("userId", "==", userId)
  );
  const feedbackSnap = await getDocs(feedbackQuery);
  if (!feedbackSnap.empty) {
    const batch = writeBatch(db);
    feedbackSnap.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
  }

  // Clean up user subcollections (rules: owner can read/write own subcollections)
  await deleteSubcollection(`users/${userId}`, "bookmarks");
  await deleteSubcollection(`users/${userId}`, "followingPets");
  await deleteSubcollection(`users/${userId}`, "followers");
  await deleteSubcollection(`users/${userId}`, "following");
  await deleteSubcollection(`users/${userId}`, "blockedUsers");

  // Delete settings (owner can write own settings)
  await deleteDoc(settingsRef(userId));

  // User document deletion and Auth account deletion are handled by
  // the deleteUserAccount Cloud Function (callable), which uses admin SDK
  // to bypass the admin-only delete rule and ensure atomicity.
  const { getFunctions, httpsCallable } = await import("firebase/functions");
  const functions = getFunctions();
  await httpsCallable(functions, "deleteUserAccount")({ userId });
}
