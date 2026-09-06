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

/** What getPetCheckinsCallable returns. Deliberately no user identity. */
export type PetCheckin = {
  id: string;
  locationId: string;
  petId: string;
  petName: string;
  photoUrl: string;
  caption: string;
  createdAt: Date | null;
};

/**
 * A pet's check-in history, through a callable rather than a direct query.
 *
 * This used to be a collection-group query filtered by petId. That query is no
 * longer permitted: the checkins collection group is scoped to the requesting
 * user's own check-ins, because left open it let anyone harvest a person's
 * whole movement timeline — by userId directly, or by petId via the
 * world-readable pets/{petId}.ownerId, which is why closing only the userId
 * path would have been pointless.
 *
 * Still public, no login required. The callable caps the row count and applies
 * the usual rate limit, and returns no userId / userName / userAvatar, none of
 * which this page ever rendered.
 */
export async function getCheckinsByPet(
  petId: string,
  options?: { limitCount?: number }
): Promise<{ checkins: PetCheckin[] }> {
  if (!petId) return { checkins: [] };

  const getPetCheckins = httpsCallable<
    { petId: string; limitCount?: number },
    {
      checkins: Array<{
        id: string;
        locationId: string;
        petId: string;
        petName: string;
        photoUrl: string;
        caption: string;
        createdAtMillis: number | null;
      }>;
    }
  >(functions, "getPetCheckinsCallable");

  const { data } = await getPetCheckins({
    petId,
    ...(options?.limitCount ? { limitCount: options.limitCount } : {}),
  });

  return {
    checkins: (data.checkins ?? []).map((item) => ({
      ...item,
      // Timestamps do not survive the callable boundary, so the server sends
      // millis and the Date is rebuilt here.
      createdAt: item.createdAtMillis ? new Date(item.createdAtMillis) : null,
    })),
  };
}
