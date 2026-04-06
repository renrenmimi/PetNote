import {
  collection,
  collectionGroup,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  startAfter,
  Timestamp,
  where,
  type QueryConstraint,
  type QueryDocumentSnapshot,
} from "firebase/firestore";
import { httpsCallable } from "firebase/functions";
import { db, functions } from "./firebase";
import { calculateDistance } from "./location";
import { getUserProfile } from "./users";
import { getUserStats } from "./posts";
import { getFollowingPets } from "./follow";

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
  const dateMillis =
    data.date instanceof Timestamp
      ? data.date.toMillis()
      : new Date(data.date as unknown as Date).getTime();
  const result = await httpsCallable<
    {
      title: string;
      description: string;
      coverImage?: string;
      dateMillis: number;
      duration: number;
      location: MeetupLocation;
      locationVisibility?: "everyone" | "participants_only";
      requirements: MeetupRequirements;
    },
    { id: string }
  >(functions, "createMeetupCallable")({
    title: data.title,
    description: data.description,
    coverImage: data.coverImage,
    dateMillis,
    duration: data.duration,
    location: data.location,
    locationVisibility: data.locationVisibility ?? "participants_only",
    requirements: data.requirements,
  });
  return result.data.id;
}

export async function updateMeetup(
  meetupId: string,
  data: Partial<MeetupData>
): Promise<void> {
  if (!data.date || !data.location || !data.requirements) {
    throw new Error("Meetup updates require date, location, and requirements.");
  }
  const dateMillis =
    data.date instanceof Timestamp
      ? data.date.toMillis()
      : new Date(data.date as unknown as Date).getTime();
  await httpsCallable<
    {
      meetupId: string;
      title: string;
      description: string;
      coverImage?: string;
      dateMillis: number;
      duration: number;
      location: MeetupLocation;
      locationVisibility?: "everyone" | "participants_only";
      requirements: MeetupRequirements;
    },
    { success: boolean }
  >(functions, "updateMeetupCallable")({
    meetupId,
    title: data.title ?? "",
    description: data.description ?? "",
    coverImage: data.coverImage,
    dateMillis,
    duration: data.duration ?? 60,
    location: data.location,
    locationVisibility: data.locationVisibility ?? "participants_only",
    requirements: data.requirements,
  });
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
    try {
      await httpsCallable(functions, "checkMeetupStatusCallable")({ meetupId });
      return { ...meetup, status: "completed", isRatingOpen: true };
    } catch {
      return meetup;
    }
  }
  return meetup;
}

export async function cancelMeetup(meetupId: string): Promise<void> {
  await httpsCallable<{ meetupId: string }, { success: boolean }>(
    functions,
    "cancelMeetupCallable"
  )({ meetupId });
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
    // Skip private meetups with zeroed coordinates
    .filter((meetup) => meetup.location.lat !== 0 || meetup.location.lng !== 0)
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
  _userId: string,
  petData: {
    petId: string;
    petName: string;
    petAvatar: string;
    petSpecies?: string;
  }
): Promise<void> {
  const result = await httpsCallable<
    { meetupId: string; petId?: string },
    { success: boolean; error?: string }
  >(functions, "joinMeetupCallable")({
    meetupId,
    petId: petData.petId || undefined,
  });
  if (!result.data.success && result.data.error) {
    throw new Error(result.data.error);
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
