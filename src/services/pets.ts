import {
  collection,
  collectionGroup,
  doc,
  documentId,
  getAggregateFromServer,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  startAfter,
  sum,
  type QueryConstraint,
  type QueryDocumentSnapshot,
  where,
} from "firebase/firestore";
import { httpsCallable } from "firebase/functions";
import { getDocumentLanguage, isChineseLanguage } from "../i18n/config";
import { db, functions } from "./firebase";
import { toPost, type Post } from "./posts";
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
  birthdayMonth?: number;
  birthdayDay?: number;
  age?: string;
  gender: PetGender;
  bio: string;
  avatarUrl: string;
  followerCount?: number;
  postCount?: number;
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

const PET_CACHE_MS = 60_000;
const PET_CACHE_MAX_ENTRIES = 500;
const DOCUMENT_ID_BATCH_SIZE = 10;
const petCache = new Map<string, { pet: Pet | null; expiresAt: number }>();
const petRequestCache = new Map<string, Promise<Pet | null>>();

function setPetCacheEntry(petId: string, pet: Pet | null): void {
  const now = Date.now();
  for (const [key, value] of petCache) {
    if (value.expiresAt <= now) {
      petCache.delete(key);
    }
  }
  while (petCache.size >= PET_CACHE_MAX_ENTRIES) {
    const oldestKey = petCache.keys().next().value;
    if (!oldestKey) break;
    petCache.delete(oldestKey);
  }
  petCache.set(petId, {
    pet,
    expiresAt: now + PET_CACHE_MS,
  });
}

export function clearPetCache(petId?: string): void {
  if (petId) {
    petCache.delete(petId);
    petRequestCache.delete(petId);
    return;
  }
  petCache.clear();
  petRequestCache.clear();
}

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

// Timezone-safe birthday match. Prefer the canonical month/day fields the
// callable now writes so a pet with birthday stored as 2020-06-01T00:00:00Z
// is recognised on 6/1 in every viewer's local timezone — not 5/31 in
// negative-UTC zones because of the toDate() conversion.
//
// Accepts either:
//   - a Pet-like object with optional birthdayMonth/birthdayDay numbers
//     plus a fallback `birthday` Timestamp/Date for legacy pets;
//   - a bare birthday value (legacy callers).
export const isBirthdayToday = (
  input: unknown,
  fallbackBirthday?: unknown
): boolean => {
  let month: number | null = null;
  let day: number | null = null;
  let legacyBirthday = fallbackBirthday;

  if (input && typeof input === "object") {
    const record = input as {
      birthday?: unknown;
      birthdayMonth?: unknown;
      birthdayDay?: unknown;
    };
    if (
      typeof record.birthdayMonth === "number" &&
      typeof record.birthdayDay === "number"
    ) {
      month = Math.floor(record.birthdayMonth);
      day = Math.floor(record.birthdayDay);
    } else if (record.birthday !== undefined) {
      legacyBirthday = record.birthday;
    }
  }

  if (month === null || day === null) {
    const date = toDate(legacyBirthday ?? input);
    if (!date) return false;
    // Use UTC fields on the legacy Timestamp so behaviour matches what the
    // callable now derives at write time.
    month = date.getUTCMonth() + 1;
    day = date.getUTCDate();
  }

  const today = new Date();
  return today.getMonth() + 1 === month && today.getDate() === day;
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
        birthdayMonth?: number;
        birthdayDay?: number;
        gender: PetGender;
        bio: string;
        avatarUrl: string;
        relationship: PetFamilyRelationship;
        customRelationship?: string;
      },
      { id: string }
    >(functions, "createPetCallable");

    // Send month/day from the picker's local Date so timezone math doesn't
    // shift the birthday (a UTC+14 user picking "June 1" produces a Date
    // whose UTC fields are May 31; deriving server-side from UTC would lose
    // a day).
    const result = await createPetCallable({
      name: data.name,
      species: data.species,
      breed: data.breed,
      birthdayMillis: birthdayDate?.getTime(),
      birthdayMonth: birthdayDate ? birthdayDate.getMonth() + 1 : undefined,
      birthdayDay: birthdayDate ? birthdayDate.getDate() : undefined,
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
  data: Partial<Omit<Pet, "id" | "ownerId">> & { clearBirthday?: boolean }
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

  // The callable distinguishes "field omitted, leave alone" from
  // "field present and empty, delete it" by checking explicit null on
  // birthdayMillis. We send null when the caller asks to clear (edit
  // mode resetting the date input); otherwise we send a positive
  // millis so the canonical month/day get rewritten too.
  await httpsCallable<
    {
      petId: string;
      name?: string;
      species?: PetSpecies;
      breed?: string;
      birthdayMillis?: number | null;
      birthdayMonth?: number | null;
      birthdayDay?: number | null;
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
    ...(birthdayDate
      ? {
          birthdayMillis: birthdayDate.getTime(),
          // Local-timezone month/day so the canonical fields stay aligned
          // with what the user picked, regardless of their UTC offset.
          birthdayMonth: birthdayDate.getMonth() + 1,
          birthdayDay: birthdayDate.getDate(),
        }
      : data.clearBirthday
        ? {
            birthdayMillis: null,
            birthdayMonth: null,
            birthdayDay: null,
          }
        : {}),
    ...(data.gender ? { gender: data.gender } : {}),
    ...(typeof data.bio === "string" ? { bio: data.bio } : {}),
    ...(typeof data.avatarUrl === "string" ? { avatarUrl: data.avatarUrl } : {}),
  });
  clearPetCache(petId);
}

export async function deletePet(petId: string): Promise<void> {
  await httpsCallable<{ petId: string }, { success: boolean }>(
    functions,
    "deletePetCallable"
  )({ petId });
  clearPetCache(petId);
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
  // Single collectionGroup read for family memberships, then chunked
  // documentId() "in" reads for the pet docs themselves. Previously we
  // issued one getDoc per family record (N+1).
  const familyQuery = query(
    collectionGroup(db, "family"),
    where("userId", "==", userId)
  );
  const familySnapshot = await getDocs(familyQuery);

  const familyByPetId = new Map<string, FamilyMember>();
  familySnapshot.docs.forEach((familyDoc) => {
    const petId = familyDoc.ref.parent.parent?.id;
    if (petId) {
      familyByPetId.set(petId, familyDoc.data() as FamilyMember);
    }
  });

  const petIds = Array.from(familyByPetId.keys());
  if (petIds.length === 0) return [];

  const petsRef = collection(db, "pets");
  const fetched = new Map<string, Pet>();
  for (let i = 0; i < petIds.length; i += DOCUMENT_ID_BATCH_SIZE) {
    const chunk = petIds.slice(i, i + DOCUMENT_ID_BATCH_SIZE);
    const snapshot = await getDocs(
      query(petsRef, where(documentId(), "in", chunk))
    );
    snapshot.docs.forEach((d) => {
      fetched.set(d.id, { id: d.id, ...(d.data() as Omit<Pet, "id">) });
    });
  }

  const result: Pet[] = [];
  familyByPetId.forEach((familyData, petId) => {
    const pet = fetched.get(petId);
    if (pet) {
      result.push({
        ...pet,
        relationship: familyData.relationship,
        customRelationship: familyData.customRelationship,
        role: familyData.role,
      });
    }
  });
  return result;
}

export async function getUserPetCounts(userIds: string[]): Promise<Record<string, number>> {
  const uniqueIds = Array.from(new Set(userIds.filter(Boolean)));
  const counts: Record<string, number> = {};
  uniqueIds.forEach((id) => {
    counts[id] = 0;
  });
  if (uniqueIds.length === 0) return counts;

  for (let i = 0; i < uniqueIds.length; i += DOCUMENT_ID_BATCH_SIZE) {
    const chunk = uniqueIds.slice(i, i + DOCUMENT_ID_BATCH_SIZE);
    const familyQuery = query(
      collectionGroup(db, "family"),
      where("userId", "in", chunk)
    );
    const snapshot = await getDocs(familyQuery);
    snapshot.docs.forEach((docSnap) => {
      const userId = docSnap.data().userId;
      if (typeof userId === "string" && userId in counts) {
        counts[userId] += 1;
      }
    });
  }

  return counts;
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
  const cached = petCache.get(petId);
  if (cached && cached.expiresAt > Date.now()) {
    petCache.delete(petId);
    petCache.set(petId, cached);
    return cached.pet;
  }
  if (cached) {
    petCache.delete(petId);
  }

  const pending = petRequestCache.get(petId);
  if (pending) return pending;

  const request = (async () => {
    const petRef = doc(db, "pets", petId);
    const snapshot = await getDoc(petRef);
    if (!snapshot.exists()) {
      setPetCacheEntry(petId, null);
      return null;
    }
    const pet = {
      id: snapshot.id,
      ...(snapshot.data() as Omit<Pet, "id">),
    };
    setPetCacheEntry(petId, pet);
    return pet;
  })().finally(() => {
    petRequestCache.delete(petId);
  });

  petRequestCache.set(petId, request);
  return request;
}

export async function batchCheckPetBirthdays(
  petIds: string[]
): Promise<Set<string>> {
  const birthdayPetIds = new Set<string>();
  const unique = Array.from(new Set(petIds.filter(Boolean)));
  if (unique.length === 0) return birthdayPetIds;

  const petsRef = collection(db, "pets");
  for (let i = 0; i < unique.length; i += DOCUMENT_ID_BATCH_SIZE) {
    const chunk = unique.slice(i, i + DOCUMENT_ID_BATCH_SIZE);
    if (chunk.length === 0) continue;

    try {
      const snapshot = await getDocs(
        query(petsRef, where(documentId(), "in", chunk))
      );
      snapshot.docs.forEach((docSnap) => {
        const pet = {
          id: docSnap.id,
          ...(docSnap.data() as Omit<Pet, "id">),
        };
        setPetCacheEntry(docSnap.id, pet);
        if (isBirthdayToday(pet)) {
          birthdayPetIds.add(docSnap.id);
        }
      });
    } catch {
      // ignore chunk failures so feed cards can still render
    }
  }

  return birthdayPetIds;
}

export async function getPostsByPet(
  petId: string,
  options?: { limitCount?: number; lastDoc?: QueryDocumentSnapshot }
): Promise<{
  posts: Post[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  const limitCount = options?.limitCount ?? 20;
  const postsRef = collection(db, "posts");
  const constraints: QueryConstraint[] = [
    where("petId", "==", petId),
    orderBy("createdAt", "desc"),
    limit(limitCount),
  ];
  if (options?.lastDoc) {
    constraints.push(startAfter(options.lastDoc));
  }
  const snapshot = await getDocs(query(postsRef, ...constraints));
  const posts = snapshot.docs.map((docSnap) => toPost(docSnap.id, docSnap.data()));
  const nextLast =
    (snapshot.docs[snapshot.docs.length - 1] as
      | QueryDocumentSnapshot
      | undefined) ?? null;
  return {
    posts,
    lastDoc: nextLast,
    hasMore: snapshot.docs.length === limitCount,
  };
}

export async function getBirthdayPets(ownerId: string): Promise<Pet[]> {
  const pets = await getUserPets(ownerId);
  return pets.filter((pet) => isBirthdayToday(pet));
}

export async function getPetTotalLikes(petId: string): Promise<number> {
  // Aggregate sum query keeps this O(1) reads even for prolific pets that
  // would otherwise require scanning every post they're tagged in.
  if (!petId) return 0;
  const postsRef = collection(db, "posts");
  const petPostsQuery = query(postsRef, where("petId", "==", petId));
  const aggSnap = await getAggregateFromServer(petPostsQuery, {
    totalLikes: sum("likeCount"),
  });
  const total = aggSnap.data().totalLikes;
  return typeof total === "number" ? total : 0;
}
