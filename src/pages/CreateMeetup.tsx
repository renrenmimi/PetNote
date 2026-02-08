import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Timestamp } from "firebase/firestore";
import { AddressAutocomplete } from "../components/AddressAutocomplete";
import { useAuth } from "../hooks/useAuth";
import { useToast } from "../contexts/ToastContext";
import { uploadImage } from "../services/cloudinary";
import { getPetsByOwner, type Pet } from "../services/pets";
import {
  createMeetup,
  joinMeetup,
  type MeetupRequirements,
} from "../services/meetups";
import { buildLocationId, getLocation, type Location } from "../services/locations";

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
  const [locationCity, setLocationCity] = useState("");
  const [locationState, setLocationState] = useState("");
  const [lat, setLat] = useState<number | null>(null);
  const [lng, setLng] = useState<number | null>(null);
  const [locationStatus, setLocationStatus] = useState<
    "idle" | "success" | "error"
  >("idle");
  const [locationLoading, setLocationLoading] = useState(false);
  const [locationError, setLocationError] = useState("");
  const [locationVisibility, setLocationVisibility] = useState<
    "everyone" | "participants_only"
  >("participants_only");
  const [locationPreview, setLocationPreview] = useState<Location | null>(null);
  const [safetyOpen, setSafetyOpen] = useState(true);

  const [petType, setPetType] = useState<
    MeetupRequirements["petType"]
  >("any");
  const [customPetType, setCustomPetType] = useState("" );
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

  const handleUseMyLocation = async () => {
    setLocationLoading(true);
    setLocationError("");
    try {
      showToast("PetNote needs your location to set meetup coordinates.", "info");
      if (!navigator.geolocation) {
        throw new Error("Geolocation is not supported.");
      }
      const position = await new Promise<GeolocationPosition>(
        (resolve, reject) => {
          let settled = false;
          let timeoutId = 0;
          const cleanup = (watchId: number) => {
            navigator.geolocation.clearWatch(watchId);
            window.clearTimeout(timeoutId);
          };
          const watchId = navigator.geolocation.watchPosition(
            (pos) => {
              if (settled) return;
              settled = true;
              cleanup(watchId);
              resolve(pos);
            },
            (err) => {
              if (settled) return;
              settled = true;
              cleanup(watchId);
              reject(err);
            },
            {
              enableHighAccuracy: false,
              timeout: 15000,
              maximumAge: 60000,
            }
          );
          timeoutId = window.setTimeout(() => {
            if (settled) return;
            settled = true;
            cleanup(watchId);
            reject(new Error("timeout"));
          }, 15000);
        }
      );
      const { latitude, longitude } = position.coords;
      setLat(latitude);
      setLng(longitude);
      const apiKey = import.meta.env.VITE_GEOAPIFY_KEY as string | undefined;
      if (!apiKey) {
        setLocationError("Geoapify key is missing. Unable to set address.");
        setLocationStatus("error");
        return;
      }
      const res = await fetch(
        `https://api.geoapify.com/v1/geocode/reverse?lat=${latitude}&lon=${longitude}&apiKey=${apiKey}`
      );
      const data = await res.json();
      const props = data?.features?.[0]?.properties || {};
      const formatted = props.formatted || "";
      const city = props.city || props.county || "";
      const state = props.state || "";
      setLocationName(props.name || props.street || formatted || `${city} Meetup`);
      setAddress(formatted || `${city}${state ? `, ${state}` : ""}`);
      setLocationCity(city);
      setLocationState(state);
      setLocationStatus("success");
      if (latitude && longitude) {
        const locationId = buildLocationId(latitude, longitude);
        const preview = await getLocation(locationId);
        setLocationPreview(preview);
      }
    } catch (err: any) {
      if (err?.code === 1) {
        setLocationError(
          "Location access denied. Please enable location in your browser settings."
        );
      } else if (err?.code === 2) {
        setLocationError("Unable to determine your location. Please try again.");
      } else if (err?.code === 3 || err?.message === "timeout") {
        setLocationError("Location request timed out. Please try again.");
      } else {
        setLocationError(
          "Could not get your location. Please enter address manually."
        );
      }
      setLocationStatus("error");
      setLocationPreview(null);
    }
    finally {
      setLocationLoading(false);
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
    if (!address.trim()) {
      showToast("Please provide a meetup address.", "error");
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
        customPetType: petType === "other" ? customPetType.trim() : undefined,
      };
      const resolvedLocationName = locationName.trim() || address.trim();
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
          name: resolvedLocationName,
          address: address.trim(),
          lat,
          lng,
          city: locationCity.trim() || undefined,
          state: locationState.trim() || undefined,
        },
        locationVisibility,
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
          <div className="overflow-hidden rounded-r-lg border border-blue-200 border-l-4 border-blue-400 bg-blue-50 p-4 text-left text-xs text-blue-800 shadow-sm transition-all duration-200 dark:border-blue-500/30 dark:bg-blue-900/20 dark:text-blue-100">
            <button
              type="button"
              onClick={() => setSafetyOpen((prev) => !prev)}
              className="flex w-full items-center justify-between text-left"
            >
              <p className="text-left text-sm font-semibold">
                🛡️ Safety Tips for Meetup Organizers
              </p>
              <span className="text-blue-400">{safetyOpen ? "−" : "+"}</span>
            </button>
            {safetyOpen ? (
              <ul className="mt-2 list-disc space-y-1 pl-4 text-left text-sm text-blue-700 dark:text-blue-300">
                <li>
                  Always choose a public, well-lit location — dog parks,
                  community parks, or pet-friendly cafés
                </li>
                <li>
                  Avoid hosting meetups at private residences, especially with
                  people you haven't met before
                </li>
                <li>
                  Let a friend or family member know where and when the meetup is
                  happening
                </li>
                <li>
                  Remind participants to bring fresh water and waste bags for their pets
                </li>
                <li>
                  Ensure all attending pets are up to date on vaccinations
                </li>
              </ul>
            ) : null}
          </div>

          <AddressAutocomplete
            value={address}
            onChange={(nextValue, location) => {
              setAddress(nextValue);
              setLocationError("");
              if (location) {
                setLocationName(location.name);
                setLat(location.lat);
                setLng(location.lng);
                setLocationCity(location.city || "");
                setLocationState(location.state || "");
                setLocationStatus("success");
                const locationId = buildLocationId(location.lat, location.lng);
                void getLocation(locationId).then((data) => {
                  setLocationPreview(data);
                });
              } else {
                setLocationName("");
                setLat(null);
                setLng(null);
                setLocationCity("");
                setLocationState("");
                setLocationStatus("idle");
                setLocationPreview(null);
              }
            }}
            placeholder="Search for a location"
          />
          <div className="flex items-center gap-3 text-xs">
            <button
              type="button"
              onClick={handleUseMyLocation}
              disabled={locationLoading}
              className="rounded-full border border-slate-200 px-3 py-1.5 text-xs font-semibold text-slate-600 transition-all duration-200 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-300"
            >
              {locationLoading ? "Locating..." : "Use My Location"}
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
                ? locationError || "⚠️ Could not find location"
                : ""}
            </span>
          </div>
          {locationPreview && locationPreview.totalRatings > 0 ? (
            <div className="rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2 text-xs text-emerald-700 dark:border-emerald-500/30 dark:bg-emerald-500/10 dark:text-emerald-200">
              ⭐ {locationPreview.averageRating.toFixed(1)} (
              {locationPreview.totalRatings} reviews) · Highly rated by pet owners!
            </div>
          ) : null}

          <div className="space-y-2">
            <p className="text-xs font-semibold text-slate-600 dark:text-slate-300">
              Address visibility
            </p>
            <div className="grid gap-2">
              {[
                {
                  key: "everyone",
                  title: "🌍 Full address visible to everyone",
                  description: "Best for public parks or community spots.",
                },
                {
                  key: "participants_only",
                  title: "🔒 Full address visible to participants only",
                  description: "Non-participants will only see the city/area.",
                },
              ].map((option) => {
                const selected = locationVisibility === option.key;
                return (
                  <button
                    key={option.key}
                    type="button"
                    onClick={() =>
                      setLocationVisibility(
                        option.key as "everyone" | "participants_only"
                      )
                    }
                    className={`rounded-2xl border px-4 py-3 text-left text-xs transition-all duration-200 ${
                      selected
                        ? "border-purple-400 bg-purple-50 text-purple-700"
                        : "border-slate-200 text-slate-600 hover:border-slate-300 dark:border-slate-700 dark:text-slate-300"
                    }`}
                  >
                    <p className="text-sm font-semibold">{option.title}</p>
                    <p className="mt-1 text-xs text-slate-500 dark:text-slate-400">
                      {option.description}
                    </p>
                  </button>
                );
              })}
            </div>
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
              { key: "other", label: "📝 Other" },
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
          {petType === "other" ? (
            <div className="space-y-2">
              <label className="text-xs font-semibold text-slate-500 dark:text-slate-300">
                Custom pet type
              </label>
              <input
                type="text"
                value={customPetType}
                maxLength={30}
                onChange={(event) => setCustomPetType(event.target.value)}
                placeholder="Enter pet type (e.g. Birds, Rabbits, Hamsters...)"
                className="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
              />
              <p className="text-[11px] text-slate-400 dark:text-slate-500">
                {customPetType.length}/30
              </p>
            </div>
          ) : null}

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
