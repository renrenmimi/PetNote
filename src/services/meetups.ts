import {
  addDoc,
  collection,
  collectionGroup,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  increment,
  limit,
  orderBy,
  query,
  serverTimestamp,
  startAfter,
  Timestamp,
  updateDoc,
  where,
  type QueryConstraint,
  type QueryDocumentSnapshot,
  runTransaction,
  setDoc,
} from "firebase/firestore";
import { db } from "./firebase";
import { calculateDistance } from "./location";
import { getUserProfile } from "./users";
import { getUserStats } from "./posts";
import { createNotification } from "./notifications";
import { getOrCreateLocation } from "./locations";
import { getFollowingPets } from "./follow";
import { removeUndefined } from "../utils/removeUndefined";

export type MeetupStatus = "upcoming" | "ongoing" | "completed" | "cancelled";

export type MeetupLocation = {
  name: string;
  address: string;
  lat: number;
  lng: number;
  city?: string;
  state?: string;
};

export type MeetupRequirements = {
  dogSize:
    | "any"
    | "small"
    | "medium"
    | "large"
    | "small_medium"
    | "medium_large";
  petType: "any" | "dog" | "cat" | "any_dog" | "any_cat" | "other";
  customPetType?: string;
  maxPets: number;
  mustHavePosts: boolean;
  mustHavePetProfile: boolean;
  minFollowers: number;
  additionalNotes: string;
};

export type MeetupData = {
  organizerId: string;
  organizerName: string;
  organizerAvatar: string;
  title: string;
  description: string;
  coverImage?: string;
  date: Timestamp;
  duration: number;
  location: MeetupLocation;
  locationId?: string;
  locationVisibility?: "everyone" | "participants_only";
  requirements: MeetupRequirements;
  status: MeetupStatus;
  participantCount: number;
  isRatingOpen?: boolean;
  createdAt?: unknown;
  updatedAt?: unknown;
};

export type Meetup = MeetupData & { id: string };

export type Participant = {
  id?: string;
  meetupId?: string;
  userId: string;
  userName: string;
  userAvatar: string;
  petId: string;
  petName: string;
  petAvatar: string;
  joinedAt?: unknown;
  status: "confirmed" | "pending" | "cancelled";
};

export async function createMeetup(data: MeetupData): Promise<string> {
  const meetupsRef = collection(db, "meetups");
  const isPrivate = (data.locationVisibility ?? "participants_only") === "participants_only";

  // For private meetups: do NOT create a public location with precise coordinates.
  // Full address lives only in the private subcollection.
  let locationId: string | undefined;
  if (!isPrivate) {
    locationId = await getOrCreateLocation({
      name: data.location.name,
      address: data.location.address,
      lat: data.location.lat,
      lng: data.location.lng,
      city: data.location.city || "",
      state: data.location.state || "",
      category: "community_park",
      source: "meetup",
    });
  }

  const publicLocation: MeetupLocation = isPrivate
    ? {
        name: data.location.name,
        address: "",
        lat: 0,
        lng: 0,
        city: data.location.city,
        state: data.location.state,
      }
    : data.location;

  const payload = removeUndefined({
    ...data,
    location: publicLocation,
    ...(locationId ? { locationId } : {}),
    status: data.status ?? "upcoming",
    participantCount: data.participantCount ?? 0,
    locationVisibility: data.locationVisibility ?? "participants_only",
    isRatingOpen: data.isRatingOpen ?? false,
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
  });
  const result = await addDoc(meetupsRef, payload);

  if (isPrivate) {
    await setDoc(doc(db, "meetups", result.id, "private", "address"), {
      address: data.location.address,
      lat: data.location.lat,
      lng: data.location.lng,
      name: data.location.name,
      city: data.location.city || "",
      state: data.location.state || "",
    });
  }

  return result.id;
}

export async function updateMeetup(
  meetupId: string,
  data: Partial<MeetupData>
): Promise<void> {
  const meetupRef = doc(db, "meetups", meetupId);
  await updateDoc(
    meetupRef,
    removeUndefined({ ...data, updatedAt: serverTimestamp() })
  );
}

export async function checkAndUpdateMeetupStatus(
  meetupId: string
): Promise<Meetup | null> {
  const meetupRef = doc(db, "meetups", meetupId);
  const snapshot = await getDoc(meetupRef);
  if (!snapshot.exists()) return null;
  const meetup = { id: snapshot.id, ...(snapshot.data() as MeetupData) };
  if (meetup.status === "cancelled" || meetup.status === "completed") {
    return meetup;
  }
  const dateValue =
    meetup.date instanceof Timestamp ? meetup.date.toDate() : meetup.date;
  const endTime = new Date(
    dateValue.getTime() + (meetup.duration || 0) * 60 * 1000
  );
  if (new Date() >= endTime) {
    await updateDoc(meetupRef, {
      status: "completed",
      isRatingOpen: true,
      updatedAt: serverTimestamp(),
    });
    return { ...meetup, status: "completed", isRatingOpen: true };
  }
  return meetup;
}

export async function cancelMeetup(meetupId: string): Promise<void> {
  const meetupRef = doc(db, "meetups", meetupId);
  const meetupSnap = await getDoc(meetupRef);
  if (!meetupSnap.exists()) return;
  const meetup = { id: meetupSnap.id, ...(meetupSnap.data() as MeetupData) };
  await updateDoc(meetupRef, {
    status: "cancelled",
    updatedAt: serverTimestamp(),
  });
  const participants = await getParticipants(meetupId);
  await Promise.all(
    participants
      .filter((item) => item.userId !== meetup.organizerId)
      .map((item) =>
        createNotification({
          userId: item.userId,
          type: "meetup_cancelled",
          fromUserId: meetup.organizerId,
          fromUserName: meetup.organizerName,
          fromUserAvatar: meetup.organizerAvatar,
          message: `cancelled the meetup ${meetup.title}`,
        })
      )
  );
}

export async function getMeetupById(id: string): Promise<Meetup | null> {
  const meetupRef = doc(db, "meetups", id);
  const snapshot = await getDoc(meetupRef);
  if (!snapshot.exists()) return null;
  return { id: snapshot.id, ...(snapshot.data() as MeetupData) };
}

export async function getMeetupPrivateAddress(
  meetupId: string
): Promise<MeetupLocation | null> {
  try {
    const privateRef = doc(db, "meetups", meetupId, "private", "address");
    const snapshot = await getDoc(privateRef);
    if (!snapshot.exists()) return null;
    return snapshot.data() as MeetupLocation;
  } catch {
    // Permission denied — user is not organizer/participant/admin
    return null;
  }
}

export async function getMeetupsByLocation(
  locationId: string
): Promise<Meetup[]> {
  const meetupsRef = collection(db, "meetups");
  const meetupQuery = query(
    meetupsRef,
    where("locationId", "==", locationId),
    orderBy("date", "desc")
  );
  const snapshot = await getDocs(meetupQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as MeetupData),
  }));
}

export async function getUpcomingMeetups(
  limitCount = 20,
  lastDoc?: QueryDocumentSnapshot
): Promise<{ meetups: Meetup[]; lastDoc: QueryDocumentSnapshot | null; hasMore: boolean }> {
  const meetupsRef = collection(db, "meetups");
  const constraints: QueryConstraint[] = [
    where("status", "in", ["upcoming", "ongoing"]),
    orderBy("date", "asc"),
    limit(limitCount),
  ];
  if (lastDoc) constraints.push(startAfter(lastDoc));
  const meetupQuery = query(meetupsRef, ...constraints);
  const snapshot = await getDocs(meetupQuery);
  const meetups = snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as MeetupData),
  }));
  const nextLast = snapshot.docs[snapshot.docs.length - 1] ?? null;
  return { meetups, lastDoc: nextLast, hasMore: snapshot.docs.length === limitCount };
}

export async function getNearbyMeetups(
  userLat: number,
  userLng: number,
  radiusMiles = 50
): Promise<Meetup[]> {
  const { meetups } = await getUpcomingMeetups(50);
  return meetups
    .map((meetup) => ({
      meetup,
      distance: calculateDistance(
        userLat,
        userLng,
        meetup.location.lat,
        meetup.location.lng
      ),
    }))
    .filter((item) => item.distance <= radiusMiles)
    .sort((a, b) => a.distance - b.distance)
    .map((item) => item.meetup);
}

export async function getThisWeekMeetups(): Promise<Meetup[]> {
  const meetupsRef = collection(db, "meetups");
  const now = new Date();
  const end = new Date();
  end.setDate(now.getDate() + 7);
  const meetupQuery = query(
    meetupsRef,
    where("date", ">=", Timestamp.fromDate(now)),
    where("date", "<=", Timestamp.fromDate(end)),
    orderBy("date", "asc")
  );
  const snapshot = await getDocs(meetupQuery);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as MeetupData),
  }));
}

const fetchMeetupsByIds = async (ids: string[]): Promise<Meetup[]> => {
  if (ids.length === 0) return [];
  const meetupsRef = collection(db, "meetups");
  const chunks: Meetup[] = [];
  const chunkSize = 10;
  for (let i = 0; i < ids.length; i += chunkSize) {
    const slice = ids.slice(i, i + chunkSize);
    const q = query(meetupsRef, where("__name__", "in", slice));
    const snapshot = await getDocs(q);
    chunks.push(
      ...snapshot.docs.map((docSnap) => ({
        id: docSnap.id,
        ...(docSnap.data() as MeetupData),
      }))
    );
  }
  return chunks;
};

export async function getMyMeetups(userId: string): Promise<Meetup[]> {
  const meetupsRef = collection(db, "meetups");
  const organizerQuery = query(
    meetupsRef,
    where("organizerId", "==", userId),
    orderBy("date", "asc")
  );
  const organizerSnap = await getDocs(organizerQuery);
  const organizerMeetups = organizerSnap.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as MeetupData),
  }));

  const participantsQuery = query(
    collectionGroup(db, "participants"),
    where("userId", "==", userId)
  );
  const participantSnap = await getDocs(participantsQuery);
  const participantIds = participantSnap.docs
    .map((docSnap) => {
      const data = docSnap.data() as Participant;
      if (data.meetupId) return data.meetupId;
      return docSnap.ref.parent.parent?.id ?? null;
    })
    .filter(Boolean) as string[];

  const otherMeetups = await fetchMeetupsByIds(
    participantIds.filter((id) => !organizerMeetups.some((m) => m.id === id))
  );

  const combined = [...organizerMeetups, ...otherMeetups];
  combined.sort((a, b) => {
    const aDate =
      a.date instanceof Timestamp ? a.date.toDate().getTime() : 0;
    const bDate =
      b.date instanceof Timestamp ? b.date.toDate().getTime() : 0;
    return aDate - bDate;
  });
  return combined;
}

export async function getParticipants(meetupId: string): Promise<Participant[]> {
  const participantsRef = collection(db, "meetups", meetupId, "participants");
  const q = query(participantsRef, orderBy("joinedAt", "asc"));
  const snapshot = await getDocs(q);
  return snapshot.docs.map((docSnap) => ({
    id: docSnap.id,
    ...(docSnap.data() as Omit<Participant, "id">),
  }));
}

export async function joinMeetup(
  meetupId: string,
  userId: string,
  petData: {
    petId: string;
    petName: string;
    petAvatar: string;
    petSpecies?: string;
  }
): Promise<void> {
  const meetupRef = doc(db, "meetups", meetupId);
  const participantRef = doc(
    db,
    "meetups",
    meetupId,
    "participants",
    userId
  );
  const meetupSnap = await getDoc(meetupRef);
  if (!meetupSnap.exists()) throw new Error("Meetup not found");
  const meetup = meetupSnap.data() as MeetupData;

  let eligibility: {
    eligible: boolean;
    reasons: string[];
    userName: string;
    userAvatar: string;
  };

  if (meetup.organizerId !== userId) {
    eligibility = await checkRequirements(
      userId,
      petData.petSpecies,
      meetup.requirements,
      meetup
    );
    if (!eligibility.eligible) {
      throw new Error(eligibility.reasons.join(" "));
    }
  } else {
    const profile = await getUserProfile(userId);
    eligibility = {
      eligible: true,
      reasons: [],
      userName: profile?.displayName || "PetNote User",
      userAvatar:
        profile?.avatarUrl ||
        `https://api.dicebear.com/7.x/thumbs/svg?seed=${userId}`,
    };
  }

  const safeUserAvatar =
    eligibility.userAvatar && eligibility.userAvatar.trim().length > 0
      ? eligibility.userAvatar
      : `https://api.dicebear.com/7.x/thumbs/svg?seed=${userId}`;
  const safePetAvatar =
    petData.petAvatar && petData.petAvatar.trim().length > 0
      ? petData.petAvatar
      : `https://api.dicebear.com/7.x/thumbs/svg?seed=${petData.petId}`;

  await runTransaction(db, async (transaction) => {
    const participantSnap = await transaction.get(participantRef);
    if (participantSnap.exists()) return;
    if (
      meetup.requirements.maxPets > 0 &&
      (meetup.participantCount ?? 0) >= meetup.requirements.maxPets
    ) {
      throw new Error("Meetup is full");
    }
    transaction.set(participantRef, {
      meetupId,
      userId,
      userName: eligibility.userName,
      userAvatar: safeUserAvatar,
      petId: petData.petId,
      petName: petData.petName,
      petAvatar: safePetAvatar,
      joinedAt: serverTimestamp(),
      status: "confirmed",
    });
    transaction.update(meetupRef, {
      participantCount: increment(1),
      updatedAt: serverTimestamp(),
    });
  });

  if (meetup.organizerId !== userId) {
    await createNotification({
      userId: meetup.organizerId,
      type: "meetup_join",
      fromUserId: userId,
      fromUserName: eligibility.userName,
      fromUserAvatar: eligibility.userAvatar,
      message: `joined your meetup ${meetup.title}`,
    });
  }
}

export async function leaveMeetup(
  meetupId: string,
  userId: string
): Promise<void> {
  const participantRef = doc(
    db,
    "meetups",
    meetupId,
    "participants",
    userId
  );
  // Only delete the participant doc. Count decrement is handled by
  // onParticipantDeleted Cloud Function to avoid double-decrement.
  const participantSnap = await getDoc(participantRef);
  if (!participantSnap.exists()) return;
  await deleteDoc(participantRef);
}

export async function checkRequirements(
  userId: string,
  petSpecies: string | undefined,
  requirements: MeetupRequirements,
  meetup?: MeetupData
): Promise<{ eligible: boolean; reasons: string[]; userName: string; userAvatar: string }> {
  const reasons: string[] = [];
  const profile = await getUserProfile(userId);
  const userName = profile?.displayName || "PetNote User";
  const userAvatar =
    profile?.avatarUrl ||
    `https://api.dicebear.com/7.x/thumbs/svg?seed=${userId}`;

  if (requirements.mustHavePosts) {
    const stats = await getUserStats(userId);
    if (stats.postCount === 0) {
      reasons.push("Must have posted at least once.");
    }
  }

  if (requirements.mustHavePetProfile && !petSpecies) {
    reasons.push("Must have a pet profile.");
  }

  if (requirements.minFollowers > 0) {
    // Count actual followingPets subcollection instead of trusting
    // the denormalized counter (which could be tampered with)
    const followingPets = await getFollowingPets(userId);
    if (followingPets.length < requirements.minFollowers) {
      reasons.push(
        `Requires at least ${requirements.minFollowers} followed pets.`
      );
    }
  }

  if (requirements.petType === "dog" || requirements.petType === "any_dog") {
    if (petSpecies && petSpecies !== "dog") {
      reasons.push("Dogs only.");
    }
  }

  if (requirements.petType === "cat" || requirements.petType === "any_cat") {
    if (petSpecies && petSpecies !== "cat") {
      reasons.push("Cats only.");
    }
  }

  if (requirements.petType === "other") {
    if (petSpecies && (petSpecies === "dog" || petSpecies === "cat")) {
      reasons.push("Other pets only.");
    }
  }

  if (meetup && meetup.status === "cancelled") {
    reasons.push("Meetup is cancelled.");
  }

  return { eligible: reasons.length === 0, reasons, userName, userAvatar };
}
