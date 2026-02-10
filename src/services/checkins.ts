import {
  collection,
  collectionGroup,
  doc,
  getDocs,
  increment,
  limit,
  orderBy,
  query,
  runTransaction,
  serverTimestamp,
  where,
} from "firebase/firestore";
import { db } from "./firebase";
import { removeUndefined } from "../utils/removeUndefined";

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
  if (typeof value === "object" && "toDate" in (value as { toDate: () => Date })) {
    return (value as { toDate: () => Date }).toDate();
  }
  return null;
};

const isSameDay = (a: Date, b: Date) =>
  a.getFullYear() === b.getFullYear() &&
  a.getMonth() === b.getMonth() &&
  a.getDate() === b.getDate();

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
  const locationRef = doc(db, "locations", locationId);
  const checkinsRef = collection(db, "locations", locationId, "checkins");
  const checkinRef = doc(checkinsRef);

  await runTransaction(db, async (transaction) => {
    const snapshot = await transaction.get(locationRef);
    const currentTotal = snapshot.exists()
      ? ((snapshot.data().totalCheckins as number | undefined) ?? 0)
      : 0;
    const nextTotal = currentTotal + 1;

    transaction.set(
      checkinRef,
      removeUndefined({
        ...data,
        createdAt: serverTimestamp(),
      })
    );

    transaction.set(
      locationRef,
      {
        totalCheckins: increment(1),
        verifiedByCheckins: nextTotal >= 3,
      },
      { merge: true }
    );
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
  const ref = collection(db, "locations", locationId, "checkins");
  const snapshot = await getDocs(
    query(ref, where("userId", "==", userId), orderBy("createdAt", "desc"), limit(1))
  );
  if (snapshot.empty) return false;
  const data = snapshot.docs[0].data();
  const created = toDate(data.createdAt);
  if (!created) return false;
  return isSameDay(created, new Date());
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
