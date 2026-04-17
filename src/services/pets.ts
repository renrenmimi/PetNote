import {
  collection,
  collectionGroup,
  doc,
  getDoc,
  getDocs,
  orderBy,
  query,
  where,
} from "firebase/firestore";
import { httpsCallable } from "firebase/functions";
import { getDocumentLanguage, isChineseLanguage } from "../i18n/config";
import { db, functions } from "./firebase";
import type { PostData, Post } from "./posts";
import { getUserProfile } from "./users";
import type { PetGender, PetSpecies } from "../utils/petHelpers";

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
  nameLower?: string;
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

const relationshipLabelMapZh: Record<PetFamilyRelationship, string> = {
  mom: "妈妈",
  dad: "爸爸",
  brother: "哥哥",
  sister: "姐姐",
  grandma: "奶奶",
  grandpa: "爷爷",
  auntie: "阿姨",
  uncle: "叔叔",
  best_friend: "好朋友",
  caretaker: "照护者",
  other: "其他",
};

export const getRelationshipLabel = (
  relationship?: PetFamilyRelationship,
  customRelationship?: string
): string => {
  const isZh = isChineseLanguage(getDocumentLanguage());
  if (!relationship) {
    return isZh ? "家人" : "Family";
  }
  if (relationship === "other" && customRelationship?.trim()) {
    return customRelationship.trim();
  }
  const labelMap = isZh ? relationshipLabelMapZh : relationshipLabelMap;
  return labelMap[relationship] || (isZh ? "家人" : "Family");
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
    const relationshipData = sanitizeRelationship(relationship, customRelationship);
    const birthdayValue = data.birthday;
    const birthdayDate =
      birthdayValue instanceof Date
        ? birthdayValue
        : typeof birthdayValue === "object" &&
            birthdayValue !== null &&
            "toDate" in birthdayValue &&
            typeof (birthdayValue as { toDate: () => Date }).toDate === "function"
          ? (birthdayValue as { toDate: () => Date }).toDate()
          : null;

    const createPetCallable = httpsCallable<
      {
        name: string;
        species: PetSpecies;
        breed?: string;
        birthdayMillis?: number;
        gender: PetGender;
        bio: string;
        avatarUrl: string;
        relationship: PetFamilyRelationship;
        customRelationship?: string;
      },
      { id: string }
    >(functions, "createPetCallable");

    const result = await createPetCallable({
      name: data.name,
      species: data.species,
      breed: data.breed,
      birthdayMillis: birthdayDate?.getTime(),
      gender: data.gender,
      bio: data.bio,
      avatarUrl: data.avatarUrl,
      relationship: relationshipData.relationship,
      customRelationship: relationshipData.customRelationship,
    });

    return result.data.id;
  } catch (error) {
    console.error("Failed to create pet. ownerId:", ownerId, error);
    throw error;
  }
}

export async function updatePet(
  petId: string,
  data: Partial<Omit<Pet, "id" | "ownerId">>
): Promise<void> {
  const birthdayValue = data.birthday;
  const birthdayDate =
    birthdayValue instanceof Date
      ? birthdayValue
      : typeof birthdayValue === "object" &&
          birthdayValue !== null &&
          "toDate" in birthdayValue &&
          typeof (birthdayValue as { toDate: () => Date }).toDate === "function"
        ? (birthdayValue as { toDate: () => Date }).toDate()
        : undefined;

  await httpsCallable<
    {
      petId: string;
      name?: string;
      species?: PetSpecies;
      breed?: string;
      birthdayMillis?: number;
      gender?: PetGender;
      bio?: string;
      avatarUrl?: string;
    },
    { success: boolean }
  >(functions, "updatePetCallable")({
    petId,
    ...(data.name ? { name: data.name } : {}),
    ...(data.species ? { species: data.species } : {}),
    ...(typeof data.breed === "string" ? { breed: data.breed } : {}),
    ...(birthdayDate ? { birthdayMillis: birthdayDate.getTime() } : {}),
    ...(data.gender ? { gender: data.gender } : {}),
    ...(typeof data.bio === "string" ? { bio: data.bio } : {}),
    ...(typeof data.avatarUrl === "string" ? { avatarUrl: data.avatarUrl } : {}),
  });
}

export async function deletePet(petId: string): Promise<void> {
  await httpsCallable<{ petId: string }, { success: boolean }>(
    functions,
    "deletePetCallable"
  )({ petId });
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
  const members = snapshot.docs.map((docSnap) => ({
    userId: docSnap.id,
    ...(docSnap.data() as Omit<FamilyMember, "userId">),
  }));

  return Promise.all(
    members.map(async (member) => {
      const profile = await getUserProfile(member.userId);
      return {
        ...member,
        userName:
          profile?.displayName?.trim() || member.userName || "PetNote User",
        userAvatar:
          profile?.avatarUrl?.trim() ||
          member.userAvatar ||
          `https://api.dicebear.com/7.x/thumbs/svg?seed=${member.userId}`,
      };
    })
  );
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
  await httpsCallable<
    { petId: string; targetUserId: string },
    { success: boolean }
  >(functions, "removeFamilyMemberCallable")({ petId, targetUserId });
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
