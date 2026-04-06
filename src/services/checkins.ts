import {
  collection,
  collectionGroup,
  doc,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  where,
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

export async function getUserCheckins(userId: string): Promise<Checkin[]> {
  const snapshot = await getDocs(
    query(collectionGroup(db, "checkins"), where("userId", "==", userId), orderBy("createdAt", "desc"))
  );
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    locationId: docSnap.ref.parent.parent?.id || "",
    ...(docSnap.data() as Omit<Checkin, "id" | "locationId">),
  }));
}

export async function getCheckinsByPet(
  petId: string,
  limitCount = 50
): Promise<Checkin[]> {
  if (!petId) return [];
  const snapshot = await getDocs(
    query(
      collectionGroup(db, "checkins"),
      where("petId", "==", petId),
      limit(limitCount)
    )
  );
  const rows = snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    locationId: docSnap.ref.parent.parent?.id || "",
    ...(docSnap.data() as Omit<Checkin, "id" | "locationId">),
  }));
  rows.sort((a, b) => {
    const aDate = toDate(a.createdAt)?.getTime() ?? 0;
    const bDate = toDate(b.createdAt)?.getTime() ?? 0;
    return bDate - aDate;
  });
  return rows;
}
