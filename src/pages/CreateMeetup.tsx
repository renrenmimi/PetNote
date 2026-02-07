import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Timestamp } from "firebase/firestore";
import { useAuth } from "../hooks/useAuth";
import { useToast } from "../contexts/ToastContext";
import { uploadImage } from "../services/cloudinary";
import { getCurrentLocation, getCityFromCoords } from "../services/location";
import { getPetsByOwner, type Pet } from "../services/pets";
import {
  createMeetup,
  joinMeetup,
  type MeetupRequirements,
} from "../services/meetups";

const durations = [
  { label: "30 min", value: 30 },
  { label: "1 hour", value: 60 },
  { label: "1.5 hours", value: 90 },
  { label: "2 hours", value: 120 },
  { label: "3 hours", value: 180 },
  { label: "Half day", value: 240 },
];

export function CreateMeetup() {
  const navigate = useNavigate();
  const { user, profile } = useAuth();
  const { showToast } = useToast();
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [coverFile, setCoverFile] = useState<File | null>(null);
  const [coverPreview, setCoverPreview] = useState<string | null>(null);
  const [date, setDate] = useState("");
  const [time, setTime] = useState("");
  const [duration, setDuration] = useState(60);
  const [locationName, setLocationName] = useState("");
  const [address, setAddress] = useState("");
  const [lat, setLat] = useState<number | null>(null);
  const [lng, setLng] = useState<number | null>(null);
  const [locationStatus, setLocationStatus] = useState<
    "idle" | "success" | "error"
  >("idle");

  const [petType, setPetType] = useState<
    MeetupRequirements["petType"]
  >("any");
  const [dogSize, setDogSize] = useState<
    MeetupRequirements["dogSize"]
  >("any");
  const [maxPets, setMaxPets] = useState(0);
  const [mustHavePosts, setMustHavePosts] = useState(false);
  const [mustHavePetProfile, setMustHavePetProfile] = useState(false);
  const [minFollowers, setMinFollowers] = useState(0);
  const [additionalNotes, setAdditionalNotes] = useState("");
  const [saving, setSaving] = useState(false);
  const [pets, setPets] = useState<Pet[]>([]);

  useEffect(() => {
    if (!coverFile) return;
    const url = URL.createObjectURL(coverFile);
    setCoverPreview(url);
    return () => URL.revokeObjectURL(url);
  }, [coverFile]);

  useEffect(() => {
    let ignore = false;
    if (!user) return;
    const load = async () => {
      const petList = await getPetsByOwner(user.uid);
      if (!ignore) setPets(petList);
    };
    void load();
    return () => {
      ignore = true;
    };
  }, [user]);

  const handleGeocode = async () => {
    if (!address.trim()) return;
    try {
      const res = await fetch(
        `https://nominatim.openstreetmap.org/search?q=${encodeURIComponent(
          address
        )}&format=json&limit=1`
      );
      const data = await res.json();
      if (data?.[0]) {
        setLat(Number(data[0].lat));
        setLng(Number(data[0].lon));
        setLocationStatus("success");
      } else {
        setLocationStatus("error");
      }
    } catch {
      setLocationStatus("error");
    }
  };

  const handleUseMyLocation = async () => {
    try {
      showToast("PetNote needs your location to set meetup coordinates.", "info");
      const coords = await getCurrentLocation();
      setLat(coords.lat);
      setLng(coords.lng);
      const city = await getCityFromCoords(coords.lat, coords.lng);
      if (!locationName) {
        setLocationName(`${city.city} Meetup`);
      }
      setLocationStatus("success");
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to get location.";
      showToast(message, "error");
      setLocationStatus("error");
    }
  };

  const handleCreate = async () => {
    if (!user || saving) return;
    if (!title.trim() || !description.trim()) {
      showToast("Please fill in title and description.", "error");
      return;
    }
    if (!date || !time) {
      showToast("Please choose a date and time.", "error");
      return;
    }
    if (!locationName.trim() || !address.trim()) {
      showToast("Please provide location name and address.", "error");
      return;
    }
    if (lat === null || lng === null) {
      showToast("Please set a valid location.", "error");
      return;
    }

    const start = new Date(`${date}T${time}`);
    if (Number.isNaN(start.getTime()) || start <= new Date()) {
      showToast("Meetup date must be in the future.", "error");
      return;
    }

    setSaving(true);
    try {
      let coverImage: string | undefined;
      if (coverFile) {
        coverImage = await uploadImage(coverFile);
      }
      const requirements: MeetupRequirements = {
        dogSize,
        petType,
        maxPets,
        mustHavePosts,
        mustHavePetProfile,
        minFollowers,
        additionalNotes: additionalNotes.trim(),
      };
      const meetupId = await createMeetup({
        organizerId: user.uid,
        organizerName: profile?.displayName || user.displayName || "PetNote User",
        organizerAvatar:
          profile?.avatarUrl ||
          user.photoURL ||
          `https://api.dicebear.com/7.x/thumbs/svg?seed=${user.uid}`,
        title: title.trim(),
        description: description.trim(),
        coverImage,
        date: Timestamp.fromDate(start),
        duration,
        location: {
          name: locationName.trim(),
          address: address.trim(),
          lat,
          lng,
        },
        requirements,
        status: "upcoming",
        participantCount: 0,
      });

      const organizerPet = pets[0];
      await joinMeetup(meetupId, user.uid, {
        petId: organizerPet?.id || "organizer",
        petName: organizerPet?.name || "Organizer",
        petAvatar: organizerPet?.avatarUrl || "",
        petSpecies: organizerPet?.species,
      });

      showToast("Meetup created!", "success");
      navigate(`/meetups/${meetupId}`, { replace: true });
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to create meetup.";
      showToast(message, "error");
    } finally {
      setSaving(false);
    }
  };

  if (!user) return null;

  return (
    <div className="min-h-screen bg-white pb-10 dark:bg-slate-900">
      <header className="sticky top-0 z-10 border-b border-slate-200 bg-white dark:border-slate-800 dark:bg-slate-900">
        <div className="mx-auto flex w-full max-w-md items-center justify-between px-4 py-3">
          <button
            type="button"
            onClick={() => navigate(-1)}
            className="text-xl text-slate-500 hover:text-slate-700 dark:text-slate-300"
            aria-label="Go back"
          >
            ←
          </button>
          <h1 className="text-base font-semibold text-slate-900 dark:text-white">
            Create Meetup
          </h1>
          <button
            type="button"
            onClick={handleCreate}
            disabled={saving}
            className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-1.5 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
          >
            {saving ? "Creating..." : "Create"}
          </button>
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-6 px-4 py-6">
        <section className="space-y-3 rounded-2xl bg-white p-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <h2 className="text-sm font-semibold text-slate-900 dark:text-white">
            Cover Image
          </h2>
          <div className="flex flex-col items-center gap-3">
            {coverPreview ? (
              <img
                src={coverPreview}
                alt="Cover preview"
                className="h-40 w-full rounded-xl object-cover"
              />
            ) : (
              <div className="flex h-40 w-full items-center justify-center rounded-xl bg-gradient-to-br from-purple-400 to-pink-400 text-3xl text-white">
                🐾
              </div>
            )}
            <label className="cursor-pointer rounded-full border border-slate-200 px-4 py-2 text-xs font-semibold text-slate-600 transition-all duration-200 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-300">
              Upload cover
              <input
                type="file"
                accept="image/*"
                className="hidden"
                onChange={(event) =>
                  setCoverFile(event.target.files?.[0] ?? null)
                }
              />
            </label>
          </div>
        </section>

        <section className="space-y-3">
          <div className="flex items-center justify-between">
            <label className="text-sm font-semibold text-slate-700 dark:text-slate-200">
              Title
            </label>
            <span className="text-xs text-slate-400 dark:text-slate-500">
              {title.length}/60
            </span>
          </div>
          <input
            type="text"
            value={title}
            onChange={(event) => setTitle(event.target.value)}
            maxLength={60}
            placeholder="Golden Retriever Play Date"
            className="w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
          />
          <div className="flex items-center justify-between">
            <label className="text-sm font-semibold text-slate-700 dark:text-slate-200">
              Description
            </label>
            <span className="text-xs text-slate-400 dark:text-slate-500">
              {description.length}/500
            </span>
          </div>
          <textarea
            value={description}
            onChange={(event) => setDescription(event.target.value)}
            maxLength={500}
            rows={4}
            placeholder="Let's get our goldens together for some fun at the park!"
            className="w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
          />
        </section>

        <section className="space-y-3">
          <h2 className="text-sm font-semibold text-slate-900 dark:text-white">
            Time
          </h2>
          <div className="grid grid-cols-2 gap-3">
            <input
              type="date"
              value={date}
              onChange={(event) => setDate(event.target.value)}
              className="w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
            />
            <input
              type="time"
              value={time}
              onChange={(event) => setTime(event.target.value)}
              className="w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
            />
          </div>
          <select
            value={duration}
            onChange={(event) => setDuration(Number(event.target.value))}
            className="w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
          >
            {durations.map((opt) => (
              <option key={opt.value} value={opt.value}>
                {opt.label}
              </option>
            ))}
          </select>
        </section>

        <section className="space-y-3">
          <h2 className="text-sm font-semibold text-slate-900 dark:text-white">
            Location
          </h2>
          <input
            type="text"
            value={locationName}
            onChange={(event) => setLocationName(event.target.value)}
            placeholder="Central Park Dog Run"
            className="w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
          />
          <input
            type="text"
            value={address}
            onChange={(event) => setAddress(event.target.value)}
            onBlur={handleGeocode}
            placeholder="123 Park Ave, San Francisco, CA"
            className="w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
          />
          <div className="flex items-center gap-3 text-xs">
            <button
              type="button"
              onClick={handleUseMyLocation}
              className="rounded-full border border-slate-200 px-3 py-1.5 text-xs font-semibold text-slate-600 transition-all duration-200 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-300"
            >
              Use My Location
            </button>
            <span
              className={`text-xs ${
                locationStatus === "success"
                  ? "text-emerald-500"
                  : locationStatus === "error"
                  ? "text-red-500"
                  : "text-slate-400 dark:text-slate-500"
              }`}
            >
              {locationStatus === "success"
                ? "📍 Location set"
                : locationStatus === "error"
                ? "⚠️ Could not find location"
                : ""}
            </span>
          </div>
        </section>

        <section className="space-y-3">
          <h2 className="text-sm font-semibold text-slate-900 dark:text-white">
            Requirements
          </h2>
          <div className="flex flex-wrap gap-2">
            {[
              { key: "any", label: "🐾 Any Pet" },
              { key: "dog", label: "🐕 Dogs Only" },
              { key: "cat", label: "🐱 Cats Only" },
            ].map((item) => (
              <button
                key={item.key}
                type="button"
                onClick={() => setPetType(item.key as MeetupRequirements["petType"])}
                className={`rounded-full px-3 py-1.5 text-xs font-semibold transition-all duration-200 ${
                  petType === item.key
                    ? "bg-gradient-to-r from-purple-500 to-pink-500 text-white"
                    : "border border-slate-200 text-slate-500 dark:border-slate-700 dark:text-slate-300"
                }`}
              >
                {item.label}
              </button>
            ))}
          </div>
          {(petType === "dog" || petType === "any_dog") ? (
            <div className="flex flex-wrap gap-2">
              {[
                { key: "any", label: "Any Size" },
                { key: "small", label: "Small" },
                { key: "medium", label: "Medium" },
                { key: "large", label: "Large" },
                { key: "small_medium", label: "Small & Medium" },
                { key: "medium_large", label: "Medium & Large" },
              ].map((item) => (
                <button
                  key={item.key}
                  type="button"
                  onClick={() =>
                    setDogSize(item.key as MeetupRequirements["dogSize"])
                  }
                  className={`rounded-full px-3 py-1.5 text-xs font-semibold transition-all duration-200 ${
                    dogSize === item.key
                      ? "bg-purple-500 text-white"
                      : "border border-slate-200 text-slate-500 dark:border-slate-700 dark:text-slate-300"
                  }`}
                >
                  {item.label}
                </button>
              ))}
            </div>
          ) : null}

          <div className="space-y-2">
            <label className="text-xs font-semibold text-slate-500 dark:text-slate-300">
              Max Pets (0 = unlimited)
            </label>
            <input
              type="range"
              min={0}
              max={20}
              value={maxPets}
              onChange={(event) => setMaxPets(Number(event.target.value))}
              className="w-full"
            />
            <p className="text-xs text-slate-500 dark:text-slate-300">
              {maxPets === 0 ? "Unlimited" : maxPets}
            </p>
          </div>

          <div className="space-y-2 text-sm text-slate-600 dark:text-slate-300">
            <label className="flex items-center gap-2">
              <input
                type="checkbox"
                checked={mustHavePosts}
                onChange={(event) => setMustHavePosts(event.target.checked)}
              />
              Must have posted at least once
            </label>
            <label className="flex items-center gap-2">
              <input
                type="checkbox"
                checked={mustHavePetProfile}
                onChange={(event) => setMustHavePetProfile(event.target.checked)}
              />
              Must have a pet profile
            </label>
          </div>

          <div className="space-y-2">
            <label className="text-xs font-semibold text-slate-500 dark:text-slate-300">
              Minimum followers
            </label>
            <input
              type="number"
              min={0}
              value={minFollowers}
              onChange={(event) => setMinFollowers(Number(event.target.value))}
              className="w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
            />
          </div>

          <div className="space-y-2">
            <label className="text-xs font-semibold text-slate-500 dark:text-slate-300">
              Additional Notes
            </label>
            <textarea
              value={additionalNotes}
              onChange={(event) => setAdditionalNotes(event.target.value)}
              maxLength={200}
              rows={3}
              placeholder="Please bring water bowls and bags"
              className="w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
            />
          </div>
        </section>
      </main>
    </div>
  );
}
