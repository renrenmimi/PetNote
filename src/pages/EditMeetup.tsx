import { useEffect, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { Timestamp } from "firebase/firestore";
import { AddressAutocomplete } from "../components/AddressAutocomplete";
import { useAuth } from "../hooks/useAuth";
import { useToast } from "../contexts/ToastContext";
import {
  deleteCloudinaryAssets,
  uploadImage,
  type UploadedAsset,
} from "../services/cloudinary";
import { reverseGeocode } from "../services/geoapify";
import { getCurrentLocation } from "../services/location";
import {
  getMeetupById,
  getMeetupPrivateAddress,
  getParticipants,
  updateMeetup,
  type Meetup,
  type MeetupRequirements,
} from "../services/meetups";
import { optimizeCloudinaryUrl } from "../utils/cloudinaryUrl";

const durations = [
  { label: "30 min", value: 30 },
  { label: "1 hour", value: 60 },
  { label: "1.5 hours", value: 90 },
  { label: "2 hours", value: 120 },
  { label: "3 hours", value: 180 },
  { label: "Half day", value: 240 },
];

export function EditMeetup() {
  const navigate = useNavigate();
  const { meetupId } = useParams();
  const { user } = useAuth();
  const { showToast } = useToast();
  const [meetup, setMeetup] = useState<Meetup | null>(null);
  const [participantsCount, setParticipantsCount] = useState(0);
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
  const [petType, setPetType] = useState<
    MeetupRequirements["petType"]
  >("any");
  const [customPetType, setCustomPetType] = useState("");
  const [dogSize, setDogSize] = useState<
    MeetupRequirements["dogSize"]
  >("any");
  const [maxPets, setMaxPets] = useState(0);
  const [mustHavePosts, setMustHavePosts] = useState(false);
  const [mustHavePetProfile, setMustHavePetProfile] = useState(false);
  const [minFollowers, setMinFollowers] = useState(0);
  const [additionalNotes, setAdditionalNotes] = useState("");
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!coverFile) return;
    const url = URL.createObjectURL(coverFile);
    setCoverPreview(url);
    return () => URL.revokeObjectURL(url);
  }, [coverFile]);

  useEffect(() => {
    let ignore = false;
    if (!meetupId) return;
    const load = async () => {
      let data;
      try {
        data = await getMeetupById(meetupId);
      } catch (error) {
        // Without this catch, a transient permission/network failure
        // left the page stuck on "Loading meetup..." forever — meetup
        // state never advanced past null, so the UI couldn't even
        // surface a retry button.
        console.error("Failed to load meetup for edit:", error);
        if (!ignore) {
          showToast(
            error instanceof Error ? error.message : "Failed to load meetup.",
            "error"
          );
        }
        return;
      }
      if (!data || ignore) return;
      setMeetup(data);
      setTitle(data.title);
      setDescription(data.description);
      setCoverPreview(data.coverImage || null);
      const dateValue =
        data.date instanceof Timestamp ? data.date.toDate() : new Date();
      // Use local fields for both date and time. `toISOString()` returns the
       // UTC calendar date, which doesn't match the local time we display
       // alongside it — for evening meetups in negative-UTC zones, this shows
       // tomorrow's date with today's time.
      const yyyy = dateValue.getFullYear();
      const mm = String(dateValue.getMonth() + 1).padStart(2, "0");
      const dd = String(dateValue.getDate()).padStart(2, "0");
      const hh = String(dateValue.getHours()).padStart(2, "0");
      const minute = String(dateValue.getMinutes()).padStart(2, "0");
      setDate(`${yyyy}-${mm}-${dd}`);
      setTime(`${hh}:${minute}`);
      setDuration(data.duration);
      // For private meetups, read full address from private subcollection
      const isPrivate = (data.locationVisibility ?? "participants_only") === "participants_only";
      if (isPrivate) {
        const privateAddr = await getMeetupPrivateAddress(meetupId);
        if (privateAddr) {
          setLocationName(privateAddr.name);
          setAddress(privateAddr.address);
          setLat(privateAddr.lat);
          setLng(privateAddr.lng);
          setLocationCity(privateAddr.city || "");
          setLocationState(privateAddr.state || "");
        } else {
          setLocationName(data.location.name);
          setAddress(data.location.address);
          setLat(data.location.lat);
          setLng(data.location.lng);
          setLocationCity(data.location.city || "");
          setLocationState(data.location.state || "");
        }
      } else {
        setLocationName(data.location.name);
        setAddress(data.location.address);
        setLat(data.location.lat);
        setLng(data.location.lng);
        setLocationCity(data.location.city || "");
        setLocationState(data.location.state || "");
      }
      setLocationVisibility(data.locationVisibility ?? "participants_only");
      setLocationStatus("success");
      setPetType(data.requirements.petType);
      setCustomPetType(data.requirements.customPetType || "");
      setDogSize(data.requirements.dogSize);
      setMaxPets(data.requirements.maxPets);
      setMustHavePosts(data.requirements.mustHavePosts);
      setMustHavePetProfile(data.requirements.mustHavePetProfile);
      setMinFollowers(data.requirements.minFollowers);
      setAdditionalNotes(data.requirements.additionalNotes || "");
      try {
        const participants = await getParticipants(meetupId);
        if (!ignore) setParticipantsCount(participants.length);
      } catch (error) {
        // Participants list is informational only — log and continue
        // so the rest of the form still saves correctly.
        console.warn("Failed to load meetup participants:", error);
      }
    };
    void load();
    return () => {
      ignore = true;
    };
    // showToast comes from a context value that is stable across renders,
    // so omitting it from the dep array is fine and keeps this effect
    // tied to the meetupId param only.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [meetupId]);

  const handleUseMyLocation = async () => {
    setLocationLoading(true);
    setLocationError("");
    try {
      showToast("PetNote needs your location to set meetup coordinates.", "info");
      const { lat: latitude, lng: longitude } = await getCurrentLocation();
      setLat(latitude);
      setLng(longitude);
      const location = await reverseGeocode(latitude, longitude);
      const formatted = location.fullAddress || "";
      const city = location.city || "";
      const state = location.state || "";
      setLocationName(location.name || formatted || `${city} Meetup`);
      setAddress(formatted || `${city}${state ? `, ${state}` : ""}`);
      setLocationCity(city);
      setLocationState(state);
      setLocationStatus("success");
    } catch (err: unknown) {
      const geoErr = err as GeolocationPositionError;
      if (geoErr?.code === 1) {
        setLocationError(
          "Location access denied. Please enable location in your browser settings."
        );
      } else if (geoErr?.code === 2) {
        setLocationError("Unable to determine your location. Please try again.");
      } else if (geoErr?.code === 3 || (err as Error)?.message === "timeout") {
        setLocationError("Location request timed out. Please try again.");
      } else {
        setLocationError(
          "Could not get your location. Please enter address manually."
        );
      }
      setLocationStatus("error");
    }
    finally {
      setLocationLoading(false);
    }
  };

  const handleSave = async () => {
    if (!meetup || !user || saving) return;
    if (meetup.organizerId !== user.uid) {
      showToast("Only the organizer can edit this meetup.", "error");
      return;
    }
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
    if (Number.isNaN(start.getTime())) {
      showToast("Invalid date/time.", "error");
      return;
    }

    setSaving(true);
    const uploaded: UploadedAsset[] = [];
    try {
      let coverImage = meetup.coverImage;
      if (coverFile) {
        const asset = await uploadImage(coverFile);
        uploaded.push(asset);
        coverImage = asset.url;
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

      await updateMeetup(meetup.id, {
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
      });
      showToast("Meetup updated", "success");
      navigate(`/meetups/${meetup.id}`, { replace: true });
    } catch (err) {
      // Best-effort orphan cleanup of the freshly uploaded cover (the old
      // cover URL persists on Cloudinary regardless and is handled by a
      // separate scheduled cleanup if/when we add one).
      void deleteCloudinaryAssets(uploaded);
      const message =
        err instanceof Error ? err.message : "Failed to update meetup.";
      showToast(message, "error");
    } finally {
      setSaving(false);
    }
  };

  if (!meetup) {
    return (
      <div className="min-h-screen bg-white pb-10 dark:bg-slate-900">
        <main className="mx-auto w-full max-w-md px-4 py-6">
          <div className="rounded-2xl bg-slate-50 p-6 text-center text-sm text-slate-500 dark:bg-slate-800 dark:text-slate-300">
            Loading meetup...
          </div>
        </main>
      </div>
    );
  }

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
            Edit Meetup
          </h1>
          <button
            type="button"
            onClick={handleSave}
            disabled={saving}
            className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-1.5 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
          >
            {saving ? "Saving..." : "Save"}
          </button>
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-6 px-4 py-6">
        {participantsCount > 0 ? (
          <div className="rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 text-xs text-amber-700 dark:border-amber-500/30 dark:bg-amber-500/10 dark:text-amber-200">
            Changing requirements may affect current participants.
          </div>
        ) : null}

        <section className="space-y-3 rounded-2xl bg-white p-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <h2 className="text-sm font-semibold text-slate-900 dark:text-white">
            Cover Image
          </h2>
          <div className="flex flex-col items-center gap-3">
            {coverPreview ? (
              <img
                src={optimizeCloudinaryUrl(coverPreview, "large")}
                alt="Cover preview"
                className="h-40 w-full rounded-xl object-cover"
              />
            ) : (
              <div className="flex h-40 w-full items-center justify-center rounded-xl bg-gradient-to-br from-purple-400 to-pink-400 text-3xl text-white">
                🐾
              </div>
            )}
            <label className="cursor-pointer rounded-full border border-slate-200 px-4 py-2 text-xs font-semibold text-slate-600 transition-all duration-200 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-300">
              Change cover
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
              } else {
                setLocationName("");
                setLat(null);
                setLng(null);
                setLocationCity("");
                setLocationState("");
                setLocationStatus("idle");
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
              Minimum followed pets
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
              className="w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
            />
          </div>
        </section>
      </main>
    </div>
  );
}
