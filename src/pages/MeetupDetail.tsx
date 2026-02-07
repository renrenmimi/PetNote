import { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { Timestamp } from "firebase/firestore";
import Avatar from "../components/Avatar";
import { useAuth } from "../hooks/useAuth";
import { useToast } from "../contexts/ToastContext";
import { calculateDistance } from "../services/location";
import {
  cancelMeetup,
  checkRequirements,
  getMeetupById,
  getParticipants,
  joinMeetup,
  leaveMeetup,
  type Meetup,
  type MeetupRequirements,
  type Participant,
} from "../services/meetups";
import { getPetsByOwner, type Pet } from "../services/pets";
import { getSpeciesMeta } from "../utils/petHelpers";

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

const formatDateLong = (value: unknown) => {
  const date = toDate(value);
  if (!date) return "";
  return date.toLocaleDateString(undefined, {
    weekday: "long",
    month: "short",
    day: "numeric",
    year: "numeric",
  });
};

const formatTimeRange = (value: unknown, durationMinutes: number) => {
  const date = toDate(value);
  if (!date) return "";
  const start = date.toLocaleTimeString(undefined, {
    hour: "numeric",
    minute: "2-digit",
  });
  const endDate = new Date(date.getTime() + durationMinutes * 60 * 1000);
  const end = endDate.toLocaleTimeString(undefined, {
    hour: "numeric",
    minute: "2-digit",
  });
  return `${start} - ${end}`;
};

const durationLabel = (duration: number) => {
  if (duration < 60) return `${duration} min`;
  const hours = duration / 60;
  return hours % 1 === 0 ? `${hours} hours` : `${hours.toFixed(1)} hours`;
};

const statusStyles: Record<string, string> = {
  upcoming: "bg-emerald-500 text-white",
  ongoing: "bg-blue-500 text-white animate-pulse",
  completed: "bg-slate-300 text-slate-700",
  cancelled: "bg-red-500 text-white",
};

const petTypeLabels: Record<MeetupRequirements["petType"], string> = {
  any: "Any pet",
  dog: "Dogs only",
  cat: "Cats only",
  any_dog: "Any dog",
  any_cat: "Any cat",
};

const dogSizeLabels: Record<MeetupRequirements["dogSize"], string> = {
  any: "Any size",
  small: "Small",
  medium: "Medium",
  large: "Large",
  small_medium: "Small & medium",
  medium_large: "Medium & large",
};

export function MeetupDetail() {
  const navigate = useNavigate();
  const { meetupId = "" } = useParams();
  const { user, profile } = useAuth();
  const { showToast } = useToast();
  const [meetup, setMeetup] = useState<Meetup | null>(null);
  const [loading, setLoading] = useState(true);
  const [participants, setParticipants] = useState<Participant[]>([]);
  const [participantsLoading, setParticipantsLoading] = useState(true);
  const [pets, setPets] = useState<Pet[]>([]);
  const [selectedPetId, setSelectedPetId] = useState<string | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const [confirmCancel, setConfirmCancel] = useState(false);
  const [joining, setJoining] = useState(false);
  const [leaving, setLeaving] = useState(false);
  const [petPickerOpen, setPetPickerOpen] = useState(false);
  const [eligibility, setEligibility] = useState<{
    eligible: boolean;
    reasons: string[];
  }>({ eligible: true, reasons: [] });

  useEffect(() => {
    let ignore = false;
    if (!meetupId) return;
    const load = async () => {
      setLoading(true);
      const data = await getMeetupById(meetupId);
      if (!ignore) {
        setMeetup(data);
        setLoading(false);
      }
    };
    void load();
    return () => {
      ignore = true;
    };
  }, [meetupId]);

  useEffect(() => {
    let ignore = false;
    if (!meetupId) return;
    const loadParticipants = async () => {
      setParticipantsLoading(true);
      const data = await getParticipants(meetupId);
      if (!ignore) {
        setParticipants(data);
        setParticipantsLoading(false);
      }
    };
    void loadParticipants();
    return () => {
      ignore = true;
    };
  }, [meetupId]);

  useEffect(() => {
    let ignore = false;
    if (!user) return;
    const loadPets = async () => {
      const data = await getPetsByOwner(user.uid);
      if (!ignore) {
        setPets(data);
        setSelectedPetId((prev) => prev ?? data[0]?.id ?? null);
      }
    };
    void loadPets();
    return () => {
      ignore = true;
    };
  }, [user]);

  useEffect(() => {
    let ignore = false;
    if (!user || !meetup) {
      setEligibility({ eligible: true, reasons: [] });
      return;
    }
    const load = async () => {
      const base = await checkRequirements(
        user.uid,
        undefined,
        meetup.requirements,
        meetup
      );
      const hasMatchingPet =
        meetup.requirements.petType === "any" ||
        pets.some((pet) => {
          if (meetup.requirements.petType === "dog") return pet.species === "dog";
          if (meetup.requirements.petType === "cat") return pet.species === "cat";
          if (meetup.requirements.petType === "any_dog") return pet.species === "dog";
          if (meetup.requirements.petType === "any_cat") return pet.species === "cat";
          return true;
        });

      const reasons = [...base.reasons];
      if (!hasMatchingPet && pets.length > 0) {
        reasons.push("No eligible pets match the meetup requirements.");
      }
      const eligible = reasons.length === 0;
      if (!ignore) {
        setEligibility({ eligible, reasons });
      }
    };
    void load();
    return () => {
      ignore = true;
    };
  }, [user, meetup, pets]);

  const isOrganizer = !!user && meetup?.organizerId === user.uid;
  const isJoined = !!user && participants.some((item) => item.userId === user.uid);
  const maxPets = meetup?.requirements.maxPets ?? 0;
  const spotsLeft =
    maxPets > 0 && meetup ? Math.max(0, maxPets - meetup.participantCount) : null;

  const distance = useMemo(() => {
    if (!meetup || !profile?.location) return null;
    return calculateDistance(
      profile.location.lat,
      profile.location.lng,
      meetup.location.lat,
      meetup.location.lng
    );
  }, [meetup, profile?.location]);

  const handleJoin = async () => {
    if (!user || !meetup || joining) return;
    if (isOrganizer) return;
    if (!eligibility.eligible) return;
    const selectedPet = pets.find((pet) => pet.id === selectedPetId);
    if (!selectedPet) {
      showToast("Select a pet to join.", "warning");
      return;
    }
    const petMatchesType =
      meetup.requirements.petType === "any" ||
      (meetup.requirements.petType === "dog" && selectedPet.species === "dog") ||
      (meetup.requirements.petType === "cat" && selectedPet.species === "cat") ||
      (meetup.requirements.petType === "any_dog" && selectedPet.species === "dog") ||
      (meetup.requirements.petType === "any_cat" && selectedPet.species === "cat");
    if (!petMatchesType) {
      showToast("Selected pet doesn't meet the requirements.", "warning");
      return;
    }
    setJoining(true);
    try {
      await joinMeetup(meetup.id, user.uid, {
        petId: selectedPet.id,
        petName: selectedPet.name,
        petAvatar: selectedPet.avatarUrl,
        petSpecies: selectedPet.species,
      });
      setParticipants((prev) => [
        ...prev,
        {
          userId: user.uid,
          userName: profile?.displayName || user.displayName || "PetNote User",
          userAvatar: profile?.avatarUrl || user.photoURL || "",
          petId: selectedPet.id,
          petName: selectedPet.name,
          petAvatar: selectedPet.avatarUrl,
          status: "confirmed",
        },
      ]);
      setMeetup((prev) =>
        prev
          ? { ...prev, participantCount: (prev.participantCount ?? 0) + 1 }
          : prev
      );
      showToast("You're in! See you at the meetup.", "success");
      setPetPickerOpen(false);
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to join meetup.";
      showToast(message, "error");
    } finally {
      setJoining(false);
    }
  };

  const handleLeave = async () => {
    if (!user || !meetup || leaving) return;
    setLeaving(true);
    try {
      await leaveMeetup(meetup.id, user.uid);
      setParticipants((prev) => prev.filter((item) => item.userId !== user.uid));
      setMeetup((prev) =>
        prev
          ? { ...prev, participantCount: Math.max(0, prev.participantCount - 1) }
          : prev
      );
      showToast("You left the meetup.", "info");
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to leave meetup.";
      showToast(message, "error");
    } finally {
      setLeaving(false);
    }
  };

  const handleCancelMeetup = async () => {
    if (!meetup) return;
    try {
      await cancelMeetup(meetup.id);
      setMeetup((prev) =>
        prev ? { ...prev, status: "cancelled" } : prev
      );
      showToast("Meetup cancelled.", "info");
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to cancel meetup.";
      showToast(message, "error");
    } finally {
      setConfirmCancel(false);
    }
  };

  const renderRequirementList = (requirements: MeetupRequirements) => {
    const items: Array<{ icon: string; label: string }> = [];
    items.push({ icon: "🐾", label: `Pet type: ${petTypeLabels[requirements.petType]}` });
    if (requirements.petType === "dog" || requirements.petType === "any_dog") {
      items.push({
        icon: "📏",
        label: `Size: ${dogSizeLabels[requirements.dogSize]}`,
      });
    }
    if (requirements.maxPets > 0) {
      items.push({
        icon: "👥",
        label: `Spots: ${meetup?.participantCount ?? 0}/${requirements.maxPets}`,
      });
    }
    if (requirements.mustHavePosts) {
      items.push({ icon: "📝", label: "Must have posted at least once" });
    }
    if (requirements.mustHavePetProfile) {
      items.push({ icon: "🐕", label: "Must have a pet profile" });
    }
    if (requirements.minFollowers > 0) {
      items.push({
        icon: "⭐",
        label: `Minimum followers: ${requirements.minFollowers}`,
      });
    }
    if (requirements.additionalNotes) {
      items.push({
        icon: "📌",
        label: requirements.additionalNotes,
      });
    }
    return items;
  };

  if (loading) {
    return (
      <div className="min-h-screen bg-slate-50 px-4 py-6 text-sm text-slate-500 dark:bg-slate-900">
        Loading meetup...
      </div>
    );
  }

  if (!meetup) {
    return (
      <div className="min-h-screen bg-slate-50 px-4 py-6 text-sm text-slate-500 dark:bg-slate-900">
        Meetup not found.
      </div>
    );
  }

  const meetupDate = meetup.date instanceof Timestamp ? meetup.date.toDate() : meetup.date;
  const isCancelled = meetup.status === "cancelled";
  const isCompleted = meetup.status === "completed";
  const isFull = maxPets > 0 && meetup.participantCount >= maxPets;

  return (
    <div className="min-h-screen bg-slate-50 pb-28 dark:bg-slate-900">
      <header className="sticky top-0 z-20 border-b border-slate-200 bg-white/80 backdrop-blur dark:border-slate-800 dark:bg-slate-900/80">
        <div className="mx-auto flex w-full max-w-md items-center justify-between px-4 py-3">
          <button
            type="button"
            onClick={() => navigate(-1)}
            className="text-xl text-slate-500 hover:text-slate-700 dark:text-slate-300"
          >
            ←
          </button>
          <h1 className="text-base font-semibold text-slate-900 dark:text-white">
            Meetup
          </h1>
          {isOrganizer ? (
            <div className="relative">
              <button
                type="button"
                onClick={() => setMenuOpen((prev) => !prev)}
                className="text-xl text-slate-400 transition-all duration-200 hover:text-slate-600 dark:text-slate-300 dark:hover:text-slate-100"
                aria-label="Meetup menu"
              >
                ⋯
              </button>
              {menuOpen ? (
                <div className="absolute right-0 top-8 z-20 w-40 rounded-xl bg-white p-2 text-sm shadow-[0_12px_30px_-20px_rgba(15,23,42,0.5)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
                  <button
                    type="button"
                    onClick={() => {
                      setMenuOpen(false);
                      navigate(`/edit-meetup/${meetup.id}`);
                    }}
                    className="w-full rounded-lg px-3 py-2 text-left text-slate-600 transition-all duration-200 hover:bg-slate-100 dark:text-slate-200 dark:hover:bg-slate-700"
                  >
                    Edit Meetup
                  </button>
                  <button
                    type="button"
                    onClick={() => {
                      setMenuOpen(false);
                      setConfirmCancel(true);
                    }}
                    className="w-full rounded-lg px-3 py-2 text-left text-red-500 transition-all duration-200 hover:bg-red-50 dark:hover:bg-red-500/10"
                  >
                    Cancel Meetup
                  </button>
                </div>
              ) : null}
            </div>
          ) : (
            <div className="w-6" />
          )}
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-4 px-4 py-4">
        <div className="overflow-hidden rounded-2xl shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)]">
          {meetup.coverImage ? (
            <img
              src={meetup.coverImage}
              alt={meetup.title}
              className="h-48 w-full object-cover"
            />
          ) : (
            <div className="flex h-48 items-center justify-center bg-gradient-to-br from-purple-500 via-pink-500 to-amber-400 text-4xl text-white">
              🐾
            </div>
          )}
        </div>

        <div className="space-y-4 rounded-2xl bg-white p-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <div className="flex items-start justify-between gap-3">
            <div>
              <h2 className="text-lg font-semibold text-slate-900 dark:text-white">
                {meetup.title}
              </h2>
              <p className="mt-1 text-sm text-slate-500 dark:text-slate-300">
                {meetup.description}
              </p>
            </div>
            <span
              className={`rounded-full px-2 py-1 text-xs font-semibold ${
                statusStyles[meetup.status] || "bg-slate-200 text-slate-700"
              }`}
            >
              {meetup.status}
            </span>
          </div>

          <div className="space-y-2 text-sm text-slate-600 dark:text-slate-300">
            <p>📅 {formatDateLong(meetupDate)}</p>
            <p>🕐 {formatTimeRange(meetupDate, meetup.duration)}</p>
            <p>⏱️ {durationLabel(meetup.duration)}</p>
          </div>

          <div className="space-y-1 text-sm text-slate-600 dark:text-slate-300">
            <p className="font-semibold text-slate-900 dark:text-white">📍 {meetup.location.name}</p>
            <p>{meetup.location.address}</p>
            {distance !== null ? (
              <span className="inline-flex rounded-full bg-blue-50 px-2 py-0.5 text-xs font-semibold text-blue-600 dark:bg-blue-500/10 dark:text-blue-200">
                {distance} miles from you
              </span>
            ) : null}
            <div>
              <button
                type="button"
                onClick={() =>
                  window.open(
                    `https://maps.google.com/?q=${meetup.location.lat},${meetup.location.lng}`,
                    "_blank"
                  )
                }
                className="mt-2 inline-flex items-center gap-2 rounded-full border border-slate-200 px-3 py-1 text-xs font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-100 dark:border-slate-700 dark:text-slate-200 dark:hover:bg-slate-700"
              >
                Open in Maps
              </button>
            </div>
          </div>

          <div className="flex items-center gap-3 rounded-xl bg-slate-50 p-3 dark:bg-slate-700/40">
            <Avatar
              src={meetup.organizerAvatar}
              alt={meetup.organizerName}
              userId={meetup.organizerId}
              size={40}
            />
            <div>
              <p className="text-sm font-semibold text-slate-900 dark:text-white">
                {meetup.organizerName}
              </p>
              <button
                type="button"
                onClick={() => navigate(`/profile/${meetup.organizerId}`)}
                className="text-xs text-purple-500 hover:text-purple-600"
              >
                Organizer
              </button>
            </div>
          </div>

          <div className="space-y-2">
            <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
              Requirements
            </h3>
            <ul className="space-y-1 text-sm text-slate-600 dark:text-slate-300">
              {renderRequirementList(meetup.requirements).map((item) => (
                <li key={item.label} className="flex items-center gap-2">
                  <span>{item.icon}</span>
                  <span>{item.label}</span>
                </li>
              ))}
            </ul>
          </div>

          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
                Participants ({meetup.participantCount}
                {maxPets > 0 ? `/${maxPets}` : ""})
              </h3>
              {participantsLoading ? (
                <span className="text-xs text-slate-400">Loading...</span>
              ) : null}
            </div>
            <div className="flex gap-3 overflow-x-auto pb-2">
              {participants.map((participant) => (
                <div key={participant.userId} className="flex w-20 flex-shrink-0 flex-col items-center text-center">
                  <div className="relative">
                    <img
                      src={participant.petAvatar}
                      alt={participant.petName}
                      className="h-12 w-12 rounded-full border-2 border-purple-300 object-cover"
                    />
                  </div>
                  <p className="mt-1 text-xs font-semibold text-slate-700 dark:text-slate-200">
                    {participant.petName}
                  </p>
                  <p className="text-[10px] text-slate-400 dark:text-slate-400">
                    {participant.userName}
                  </p>
                </div>
              ))}
              {maxPets > 0 && meetup.participantCount < maxPets ? (
                <div className="flex w-20 flex-shrink-0 flex-col items-center text-center">
                  <div className="flex h-12 w-12 items-center justify-center rounded-full border-2 border-dashed border-slate-300 text-slate-400 dark:border-slate-600">
                    +
                  </div>
                </div>
              ) : null}
              {participants.length === 0 && !participantsLoading ? (
                <p className="text-sm text-slate-400">No participants yet.</p>
              ) : null}
            </div>
          </div>
        </div>
      </main>

      {!isCancelled && !isCompleted ? (
        <div className="fixed bottom-0 left-0 right-0 z-20 border-t border-slate-200 bg-white/95 px-4 py-3 backdrop-blur dark:border-slate-800 dark:bg-slate-900/95">
          <div className="mx-auto w-full max-w-md space-y-2">
            {isOrganizer ? (
              <div className="flex gap-2">
                <button
                  type="button"
                  onClick={() => navigate(`/edit-meetup/${meetup.id}`)}
                  className="flex-1 rounded-full border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-100 dark:border-slate-700 dark:text-slate-200 dark:hover:bg-slate-800"
                >
                  Edit Meetup
                </button>
                <button
                  type="button"
                  onClick={() => setConfirmCancel(true)}
                  className="flex-1 rounded-full bg-red-500 px-4 py-2 text-sm font-semibold text-white transition-all duration-200 hover:bg-red-600"
                >
                  Cancel Meetup
                </button>
              </div>
            ) : isJoined ? (
              <button
                type="button"
                onClick={handleLeave}
                disabled={leaving}
                className="w-full rounded-full border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-70 dark:border-slate-700 dark:text-slate-200 dark:hover:bg-slate-800"
              >
                {leaving ? "Leaving..." : "Leave Meetup"}
              </button>
            ) : isFull ? (
              <button
                type="button"
                disabled
                className="w-full rounded-full bg-slate-200 px-4 py-2 text-sm font-semibold text-slate-500 dark:bg-slate-700 dark:text-slate-400"
              >
                Meetup Full
              </button>
            ) : !user ? (
              <button
                type="button"
                onClick={() => navigate("/login")}
                className="w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white shadow-[0_12px_25px_-15px_rgba(168,85,247,0.8)] transition-all duration-200 hover:scale-[1.01]"
              >
                Login to Join
              </button>
            ) : !eligibility.eligible ? (
              <div className="rounded-2xl bg-red-50 px-4 py-3 text-sm text-red-600 dark:bg-red-500/10 dark:text-red-300">
                <p className="font-semibold">You don&apos;t meet the requirements.</p>
                <ul className="mt-1 list-disc pl-4 text-xs">
                  {eligibility.reasons.map((reason) => (
                    <li key={reason}>{reason}</li>
                  ))}
                </ul>
              </div>
            ) : (
              <button
                type="button"
                onClick={() => setPetPickerOpen(true)}
                className="w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white shadow-[0_12px_25px_-15px_rgba(168,85,247,0.8)] transition-all duration-200 hover:scale-[1.01]"
              >
                Join Meetup
              </button>
            )}
          </div>
        </div>
      ) : null}

      {petPickerOpen ? (
        <div className="fixed inset-0 z-40 flex items-end justify-center bg-black/40 px-4 pb-6">
          <div className="w-full max-w-md rounded-2xl bg-white p-4 shadow-xl dark:bg-slate-800">
            <div className="flex items-center justify-between">
              <h3 className="text-base font-semibold text-slate-900 dark:text-white">
                Which pet are you bringing?
              </h3>
              <button
                type="button"
                onClick={() => setPetPickerOpen(false)}
                className="text-slate-400 hover:text-slate-600 dark:text-slate-300"
              >
                ✕
              </button>
            </div>
            {pets.length === 0 ? (
              <div className="mt-4 space-y-3 text-sm text-slate-500 dark:text-slate-300">
                <p>Add a pet profile to join meetups.</p>
                <button
                  type="button"
                  onClick={() => navigate("/add-pet")}
                  className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white"
                >
                  Add a Pet
                </button>
              </div>
            ) : (
              <div className="mt-4 space-y-2">
                {pets.map((pet) => {
                  const speciesMeta = getSpeciesMeta(pet.species);
                  const petMatchesType =
                    meetup.requirements.petType === "any" ||
                    (meetup.requirements.petType === "dog" &&
                      pet.species === "dog") ||
                    (meetup.requirements.petType === "cat" &&
                      pet.species === "cat") ||
                    (meetup.requirements.petType === "any_dog" &&
                      pet.species === "dog") ||
                    (meetup.requirements.petType === "any_cat" &&
                      pet.species === "cat");
                  return (
                    <button
                      key={pet.id}
                      type="button"
                      disabled={!petMatchesType}
                      onClick={() => setSelectedPetId(pet.id)}
                      className={`flex w-full items-center gap-3 rounded-xl border px-3 py-2 text-left transition-all duration-200 ${
                        selectedPetId === pet.id
                          ? "border-purple-400 bg-purple-50"
                          : "border-slate-200 hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-700/40"
                      } ${
                        !petMatchesType
                          ? "cursor-not-allowed opacity-50"
                          : "cursor-pointer"
                      }`}
                    >
                      <img
                        src={pet.avatarUrl}
                        alt={pet.name}
                        className="h-12 w-12 rounded-full object-cover"
                      />
                      <div className="flex-1">
                        <p className="text-sm font-semibold text-slate-900 dark:text-white">
                          {pet.name}
                        </p>
                        <p className="text-xs text-slate-500 dark:text-slate-300">
                          {speciesMeta.emoji} {pet.breed || speciesMeta.label}
                        </p>
                        {!petMatchesType ? (
                          <p className="text-[11px] text-red-500">
                            Doesn&apos;t meet pet type requirement
                          </p>
                        ) : null}
                      </div>
                    </button>
                  );
                })}
                <button
                  type="button"
                  onClick={handleJoin}
                  disabled={joining}
                  className="mt-3 w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white shadow-[0_12px_25px_-15px_rgba(168,85,247,0.8)] transition-all duration-200 hover:scale-[1.01] disabled:cursor-not-allowed disabled:opacity-70"
                >
                  {joining ? "Joining..." : "Confirm Join"}
                </button>
              </div>
            )}
          </div>
        </div>
      ) : null}

      {confirmCancel ? (
        <div className="fixed inset-0 z-40 flex items-center justify-center bg-black/40 px-4">
          <div className="w-full max-w-sm rounded-2xl bg-white p-5 text-center shadow-xl dark:bg-slate-800">
            <h3 className="text-base font-semibold text-slate-900 dark:text-white">
              Cancel this meetup?
            </h3>
            <p className="mt-2 text-sm text-slate-500 dark:text-slate-300">
              Participants will be notified.
            </p>
            <div className="mt-4 flex gap-2">
              <button
                type="button"
                onClick={() => setConfirmCancel(false)}
                className="flex-1 rounded-full border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-100 dark:border-slate-700 dark:text-slate-200 dark:hover:bg-slate-700"
              >
                Keep
              </button>
              <button
                type="button"
                onClick={handleCancelMeetup}
                className="flex-1 rounded-full bg-red-500 px-4 py-2 text-sm font-semibold text-white transition-all duration-200 hover:bg-red-600"
              >
                Cancel Meetup
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
