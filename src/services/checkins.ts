import {
  collection,
  collectionGroup,
  doc,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  startAfter,
  where,
  type QueryConstraint,
  type QueryDocumentSnapshot,
} from "firebase/firestore";
import { httpsCallable } from "firebase/functions";
import { db, functions } from "./firebase";

export type Checkin = {
  id: string;
  locationId: string;
  userId: string;
  userName: string;
  userAvatar: string;
  photoUrl: string;
  caption?: string;
  petId?: string;
  petName?: string;
  createdAt?: unknown;
};

const getUtcDayKey = (date = new Date()) => date.toISOString().slice(0, 10);

export async function checkIn(
  locationId: string,
  data: {
    userId: string;
    userName: string;
    userAvatar: string;
    photoUrl: string;
    caption?: string;
    petId?: string;
    petName?: string;
  }
): Promise<void> {
  await httpsCallable<
    {
      locationId: string;
      photoUrl: string;
      caption?: string;
      petId?: string;
    },
    { id: string }
  >(functions, "checkInCallable")({
    locationId,
    photoUrl: data.photoUrl,
    caption: data.caption,
    petId: data.petId,
  });
}

export async function getCheckins(
  locationId: string,
  limitCount = 5
): Promise<Checkin[]> {
  const ref = collection(db, "locations", locationId, "checkins");
  const snapshot = await getDocs(
    query(ref, orderBy("createdAt", "desc"), limit(limitCount))
  );
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    locationId,
    ...(docSnap.data() as Omit<Checkin, "id" | "locationId">),
  }));
}

export async function hasUserCheckedIn(
  locationId: string,
  userId: string
): Promise<boolean> {
  const checkinRef = doc(
    db,
    "locations",
    locationId,
    "checkins",
    `${userId}_${getUtcDayKey()}`
  );
  const snapshot = await getDoc(checkinRef);
  return snapshot.exists();
}

export async function getUserCheckins(
  userId: string,
  options?: { limitCount?: number; lastDoc?: QueryDocumentSnapshot }
): Promise<{
  checkins: Checkin[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  const limitCount = options?.limitCount ?? 100;
  const constraints: QueryConstraint[] = [
    where("userId", "==", userId),
    orderBy("createdAt", "desc"),
    limit(limitCount),
  ];
  if (options?.lastDoc) {
    constraints.push(startAfter(options.lastDoc));
  }
  const snapshot = await getDocs(
    query(collectionGroup(db, "checkins"), ...constraints)
  );
  const checkins = snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    locationId: docSnap.ref.parent.parent?.id || "",
    ...(docSnap.data() as Omit<Checkin, "id" | "locationId">),
  }));
  const nextLast =
    (snapshot.docs[snapshot.docs.length - 1] as
      | QueryDocumentSnapshot
      | undefined) ?? null;
  return {
    checkins,
    lastDoc: nextLast,
    hasMore: snapshot.docs.length === limitCount,
  };
}

export async function getCheckinsByPet(
  petId: string,
  options?: { limitCount?: number; lastDoc?: QueryDocumentSnapshot }
): Promise<{
  checkins: Checkin[];
  lastDoc: QueryDocumentSnapshot | null;
  hasMore: boolean;
}> {
  if (!petId) return { checkins: [], lastDoc: null, hasMore: false };
  const limitCount = options?.limitCount ?? 50;
  // Order on the server with a (petId ASC, createdAt DESC) collection-group
  // index so we get the *latest* N rather than an unordered slice that we
  // then sort locally. Without orderBy, `.limit(50)` could return any 50
  // matching docs and miss recent check-ins for prolific pets.
  const constraints: QueryConstraint[] = [
    where("petId", "==", petId),
    orderBy("createdAt", "desc"),
    limit(limitCount),
  ];
  if (options?.lastDoc) {
    constraints.push(startAfter(options.lastDoc));
  }
  const snapshot = await getDocs(
    query(collectionGroup(db, "checkins"), ...constraints)
  );
  const checkins = snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    locationId: docSnap.ref.parent.parent?.id || "",
    ...(docSnap.data() as Omit<Checkin, "id" | "locationId">),
  }));
  const nextLast =
    (snapshot.docs[snapshot.docs.length - 1] as
      | QueryDocumentSnapshot
      | undefined) ?? null;
  return {
    checkins,
    lastDoc: nextLast,
    hasMore: snapshot.docs.length === limitCount,
  };
}
