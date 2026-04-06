import {
  collection,
  doc,
  getDoc,
  getDocs,
  setDoc,
} from "firebase/firestore";
import { httpsCallable } from "firebase/functions";
import { db, functions } from "./firebase";

export type FollowingPet = {
  id: string;
  petId: string;
  petName: string;
  petAvatar: string;
  followedAt?: unknown;
};

export type PetFollower = {
  id: string;
  userId: string;
  userName: string;
  userAvatar: string;
  followedAt?: unknown;
};

export async function followPet(_userId: string, petId: string): Promise<void> {
  if (!petId) return;
  await httpsCallable<{ petId: string }, { success: boolean }>(
    functions,
    "followPetCallable"
  )({ petId });
}

export async function unfollowPet(_userId: string, petId: string): Promise<void> {
  if (!petId) return;
  await httpsCallable<{ petId: string }, { success: boolean }>(
    functions,
    "unfollowPetCallable"
  )({ petId });
}

export async function checkIfFollowingPet(
  userId: string,
  petId: string
): Promise<boolean> {
  if (!userId || !petId) return false;
  const followingRef = doc(db, "users", userId, "followingPets", petId);
  const snapshot = await getDoc(followingRef);
  return snapshot.exists();
}

export async function getFollowingPets(userId: string): Promise<FollowingPet[]> {
  if (!userId) return [];
  const followingRef = collection(db, "users", userId, "followingPets");
  const snapshot = await getDocs(followingRef);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<FollowingPet, "id">),
  }));
}

export async function getPetFollowers(petId: string): Promise<PetFollower[]> {
  if (!petId) return [];
  const followersRef = collection(db, "pets", petId, "followers");
  const snapshot = await getDocs(followersRef);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<PetFollower, "id">),
  }));
}

export async function ensureUserDoc(
  uid: string,
  payload?: Record<string, unknown>
): Promise<void> {
  const userRef = doc(db, "users", uid);
  await setDoc(
    userRef,
    { ...payload },
    { merge: true }
  );
}
