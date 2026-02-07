import {
  addDoc,
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  orderBy,
  query,
  serverTimestamp,
  setDoc,
  where,
} from "firebase/firestore";
import { db } from "./firebase";
import type { PostData, Post } from "./posts";
import type { PetGender, PetSpecies } from "../utils/petHelpers";

export type Pet = {
  id: string;
  ownerId: string;
  name: string;
  species: PetSpecies;
  breed?: string;
  birthday?: unknown;
  age?: string;
  gender: PetGender;
  bio: string;
  avatarUrl: string;
  createdAt?: unknown;
};

const toDate = (value: unknown): Date | null => {
  if (!value) return null;
  if (value instanceof Date) return value;
  if (
    typeof value === "object" &&
    value !== null &&
    "toDate" in value &&
    typeof (value as { toDate: () => Date }).toDate === "function"
  ) {
    return (value as { toDate: () => Date }).toDate();
  }
  return null;
};

export const isBirthdayToday = (birthday: unknown): boolean => {
  const date = toDate(birthday);
  if (!date) return false;
  const today = new Date();
  return (
    date.getMonth() === today.getMonth() &&
    date.getDate() === today.getDate()
  );
};

export async function createPet(
  ownerId: string,
  data: Omit<Pet, "id" | "ownerId" | "createdAt">
): Promise<string> {
  const petsRef = collection(db, "pets");
  const ownerQuery = query(petsRef, where("ownerId", "==", ownerId));
  const snapshot = await getDocs(ownerQuery);
  if (snapshot.size >= 5) {
    throw new Error("Maximum 5 pets allowed");
  }
  const result = await addDoc(petsRef, {
    ...data,
    ownerId,
    createdAt: serverTimestamp(),
  });
  return result.id;
}

export async function updatePet(
  petId: string,
  data: Partial<Omit<Pet, "id" | "ownerId">>
): Promise<void> {
  const petRef = doc(db, "pets", petId);
  await setDoc(petRef, data, { merge: true });
}

export async function deletePet(petId: string): Promise<void> {
  const petRef = doc(db, "pets", petId);
  await deleteDoc(petRef);
}

export async function getPetsByOwner(ownerId: string): Promise<Pet[]> {
  const petsRef = collection(db, "pets");
  const petsQuery = query(
    petsRef,
    where("ownerId", "==", ownerId),
    orderBy("createdAt", "desc")
  );
  const snapshot = await getDocs(petsQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Pet, "id">),
  }));
}

export async function getPetById(petId: string): Promise<Pet | null> {
  const petRef = doc(db, "pets", petId);
  const snapshot = await getDoc(petRef);
  if (!snapshot.exists()) return null;
  return {
    id: snapshot.id,
    ...(snapshot.data() as Omit<Pet, "id">),
  };
}

export async function getPostsByPet(petId: string): Promise<Post[]> {
  const postsRef = collection(db, "posts");
  const postsQuery = query(
    postsRef,
    where("petId", "==", petId),
    orderBy("createdAt", "desc")
  );
  const snapshot = await getDocs(postsQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as PostData),
  }));
}

export async function getBirthdayPets(ownerId: string): Promise<Pet[]> {
  const pets = await getPetsByOwner(ownerId);
  return pets.filter((pet) => isBirthdayToday(pet.birthday));
}
