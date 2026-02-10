import {
  addDoc,
  collection,
  collectionGroup,
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
import { getUserProfile } from "./users";
import { removeUndefined } from "../utils/removeUndefined";

export type PetFamilyRelationship =
  | "mom"
  | "dad"
  | "brother"
  | "sister"
  | "grandma"
  | "grandpa"
  | "auntie"
  | "uncle"
  | "best_friend"
  | "caretaker"
  | "other";

export type PetFamilyRole = "primary" | "member";

export type Pet = {
  id: string;
  ownerId: string;
  primaryOwnerId?: string;
  name: string;
  species: PetSpecies;
  breed?: string;
  birthday?: unknown;
  age?: string;
  gender: PetGender;
  bio: string;
  avatarUrl: string;
  followerCount?: number;
  createdAt?: unknown;
  relationship?: PetFamilyRelationship;
  customRelationship?: string;
  role?: PetFamilyRole;
};

export type FamilyMember = {
  userId: string;
  userName: string;
  userAvatar: string;
  relationship: PetFamilyRelationship;
  customRelationship?: string;
  role: PetFamilyRole;
  joinedAt?: unknown;
};

export const PET_FAMILY_RELATIONSHIP_OPTIONS: Array<{
  value: PetFamilyRelationship;
  label: string;
  emoji: string;
}> = [
  { value: "mom", label: "Mom", emoji: "👩" },
  { value: "dad", label: "Dad", emoji: "👨" },
  { value: "sister", label: "Sister", emoji: "👧" },
  { value: "brother", label: "Brother", emoji: "👦" },
  { value: "grandma", label: "Grandma", emoji: "👵" },
  { value: "grandpa", label: "Grandpa", emoji: "👴" },
  { value: "auntie", label: "Auntie", emoji: "🧓" },
  { value: "uncle", label: "Uncle", emoji: "🧔" },
  { value: "best_friend", label: "Best Friend", emoji: "👫" },
  { value: "caretaker", label: "Caretaker", emoji: "🤝" },
  { value: "other", label: "Other", emoji: "📝" },
];

const relationshipLabelMap: Record<PetFamilyRelationship, string> = {
  mom: "Mom",
  dad: "Dad",
  brother: "Brother",
  sister: "Sister",
  grandma: "Grandma",
  grandpa: "Grandpa",
  auntie: "Auntie",
  uncle: "Uncle",
  best_friend: "Best Friend",
  caretaker: "Caretaker",
  other: "Other",
};

export const getRelationshipLabel = (
  relationship?: PetFamilyRelationship,
  customRelationship?: string
): string => {
  if (!relationship) {
    return "Family";
  }
  if (relationship === "other" && customRelationship?.trim()) {
    return customRelationship.trim();
  }
  return relationshipLabelMap[relationship] || "Family";
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

const sanitizeRelationship = (
  relationship: PetFamilyRelationship,
  customRelationship?: string
) => {
  if (relationship !== "other") {
    return { relationship, customRelationship: undefined as string | undefined };
  }
  return {
    relationship,
    customRelationship: customRelationship?.trim() || undefined,
  };
};

export async function createPet(
  ownerId: string,
  data: Omit<Pet, "id" | "ownerId" | "primaryOwnerId" | "createdAt">,
  relationship: PetFamilyRelationship = "other",
  customRelationship?: string
): Promise<string> {
  try {
    const petsRef = collection(db, "pets");
    const ownerQuery = query(petsRef, where("ownerId", "==", ownerId));
    const snapshot = await getDocs(ownerQuery);
    if (snapshot.size >= 5) {
      throw new Error("Maximum 5 pets allowed");
    }

    const result = await addDoc(
      petsRef,
      removeUndefined({
        ...data,
        ownerId,
        primaryOwnerId: ownerId,
        followerCount: 0,
        createdAt: serverTimestamp(),
      })
    );

    const creatorProfile = await getUserProfile(ownerId);
    const relationshipData = sanitizeRelationship(relationship, customRelationship);

    await setDoc(doc(db, `pets/${result.id}/family/${ownerId}`), {
      userId: ownerId,
      userName: creatorProfile?.displayName || "User",
      userAvatar:
        creatorProfile?.avatarUrl ||
        `https://api.dicebear.com/7.x/thumbs/svg?seed=${ownerId}`,
      relationship: relationshipData.relationship,
      ...(relationshipData.customRelationship
        ? { customRelationship: relationshipData.customRelationship }
        : {}),
      role: "primary",
      joinedAt: serverTimestamp(),
    });

    return result.id;
  } catch (error) {
    console.error("Failed to create pet. ownerId:", ownerId, error);
    throw error;
  }
}

export async function updatePet(
  petId: string,
  data: Partial<Omit<Pet, "id" | "ownerId">>
): Promise<void> {
  const petRef = doc(db, "pets", petId);
  await setDoc(petRef, removeUndefined(data), { merge: true });
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

export async function getUserPets(userId: string): Promise<Pet[]> {
  const familyQuery = query(
    collectionGroup(db, "family"),
    where("userId", "==", userId)
  );
  const familySnapshot = await getDocs(familyQuery);

  const petEntries = await Promise.all(
    familySnapshot.docs.map(async (familyDoc) => {
      const petId = familyDoc.ref.parent.parent?.id;
      if (!petId) return null;
      const petSnap = await getDoc(doc(db, "pets", petId));
      if (!petSnap.exists()) return null;
      const familyData = familyDoc.data() as FamilyMember;
      return {
        id: petSnap.id,
        ...(petSnap.data() as Omit<Pet, "id">),
        relationship: familyData.relationship,
        customRelationship: familyData.customRelationship,
        role: familyData.role,
      } as Pet;
    })
  );

  const filtered: Pet[] = [];
  for (const entry of petEntries) {
    if (entry) {
      filtered.push(entry);
    }
  }
  return filtered;
}

export async function getPetFamily(petId: string): Promise<FamilyMember[]> {
  const familyRef = collection(db, `pets/${petId}/family`);
  const familyQuery = query(familyRef, orderBy("joinedAt", "asc"));
  const snapshot = await getDocs(familyQuery);
  return snapshot.docs.map((docSnap) => docSnap.data() as FamilyMember);
}

export async function isFamilyMember(
  petId: string,
  userId: string
): Promise<boolean> {
  const memberRef = doc(db, `pets/${petId}/family/${userId}`);
  const memberSnap = await getDoc(memberRef);
  return memberSnap.exists();
}

export async function removeFamilyMember(
  petId: string,
  targetUserId: string
): Promise<void> {
  await deleteDoc(doc(db, `pets/${petId}/family/${targetUserId}`));
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
  const pets = await getUserPets(ownerId);
  return pets.filter((pet) => isBirthdayToday(pet.birthday));
}

export async function getPetTotalLikes(petId: string): Promise<number> {
  if (!petId) return 0;
  const postsRef = collection(db, "posts");
  const postsQuery = query(postsRef, where("petId", "==", petId));
  const snapshot = await getDocs(postsQuery);
  let total = 0;
  snapshot.docs.forEach((docSnap) => {
    const data = docSnap.data() as { likeCount?: number };
    total += data.likeCount || 0;
  });
  return total;
}
