import {
  collection,
  doc,
  getDoc,
  getDocs,
  increment,
  runTransaction,
  serverTimestamp,
  setDoc,
} from "firebase/firestore";
import { db } from "./firebase";
import { createNotification } from "./notifications";
import { getPetById, getPetFamily } from "./pets";
import { getUserProfile } from "./users";

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

export async function followPet(userId: string, petId: string): Promise<void> {
  if (!userId || !petId) return;

  const [pet, profile] = await Promise.all([
    getPetById(petId),
    getUserProfile(userId),
  ]);
  if (!pet) return;

  const userRef = doc(db, "users", userId);
  const petRef = doc(db, "pets", petId);
  const followingRef = doc(db, "users", userId, "followingPets", petId);
  const followerRef = doc(db, "pets", petId, "followers", userId);
  let created = false;

  await runTransaction(db, async (transaction) => {
    const existing = await transaction.get(followingRef);
    if (existing.exists()) return;

    transaction.set(followingRef, {
      petId,
      petName: pet.name,
      petAvatar: pet.avatarUrl || "",
      followedAt: serverTimestamp(),
    });
    transaction.set(followerRef, {
      userId,
      userName: profile?.displayName || "PetNote User",
      userAvatar:
        profile?.avatarUrl ||
        `https://api.dicebear.com/7.x/thumbs/svg?seed=${userId}`,
      followedAt: serverTimestamp(),
    });
    transaction.set(userRef, { followingPetsCount: increment(1) }, { merge: true });
    transaction.set(petRef, { followerCount: increment(1) }, { merge: true });
    created = true;
  });

  if (!created) return;

  const familyMembers = await getPetFamily(petId);
  const recipientIds = Array.from(
    new Set(
      familyMembers
        .map((member) => member.userId)
        .filter((memberId) => !!memberId && memberId !== userId)
    )
  );
  if (recipientIds.length === 0) return;

  await Promise.all(
    recipientIds.map((recipientId) =>
      createNotification({
        userId: recipientId,
        type: "pet_follow",
        fromUserId: userId,
        fromUserName: profile?.displayName || "PetNote User",
        fromUserAvatar:
          profile?.avatarUrl ||
          `https://api.dicebear.com/7.x/thumbs/svg?seed=${userId}`,
        message: `started following ${pet.name}`,
      })
    )
  );
}

export async function unfollowPet(userId: string, petId: string): Promise<void> {
  if (!userId || !petId) return;

  const userRef = doc(db, "users", userId);
  const petRef = doc(db, "pets", petId);
  const followingRef = doc(db, "users", userId, "followingPets", petId);
  const followerRef = doc(db, "pets", petId, "followers", userId);

  await runTransaction(db, async (transaction) => {
    const existing = await transaction.get(followingRef);
    if (!existing.exists()) return;

    transaction.delete(followingRef);
    transaction.delete(followerRef);
    transaction.set(
      userRef,
      { followingPetsCount: increment(-1) },
      { merge: true }
    );
    transaction.set(petRef, { followerCount: increment(-1) }, { merge: true });
  });
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
    { followingPetsCount: 0, followerCount: 0, followingCount: 0, ...payload },
    { merge: true }
  );
}

