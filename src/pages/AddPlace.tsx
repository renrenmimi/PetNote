import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { AddressAutocomplete } from "../components/AddressAutocomplete";
import { useAuth } from "../hooks/useAuth";
import { useToast } from "../contexts/ToastContext";
import { uploadImage } from "../services/cloudinary";
import {
  addPlace,
  findNearbyPlace,
  submitReview,
  type PlaceCategory,
  type PlaceFeature,
} from "../services/locations";

const categories: Array<{ key: PlaceCategory; label: string; color: string }> = [
  { key: "dog_park", label: "🐕 Dog Park", color: "border-emerald-500" },
  { key: "hiking_trail", label: "🥾 Hiking Trail", color: "border-amber-500" },
  { key: "beach", label: "🏖️ Beach", color: "border-blue-500" },
  { key: "community_park", label: "🌳 Community Park", color: "border-green-500" },
  { key: "cafe", label: "☕ Pet-Friendly Café", color: "border-orange-500" },
  { key: "green_space", label: "🌿 Green Space", color: "border-teal-500" },
  { key: "pet_store", label: "🏪 Pet Store", color: "border-purple-500" },
  { key: "vet", label: "🏥 Vet Clinic", color: "border-red-500" },
  { key: "other", label: "📍 Other", color: "border-slate-400" },
];

const featureOptions: Array<{ key: PlaceFeature; label: string }> = [
  { key: "off_leash", label: "🐕‍🦺 Off-leash area" },
  { key: "fenced", label: "🏗️ Fenced area" },
  { key: "water_access", label: "💧 Water access" },
  { key: "waste_bags", label: "🗑️ Waste bags provided" },
  { key: "parking", label: "🅿️ Parking available" },
  { key: "restrooms", label: "🚽 Restrooms nearby" },
  { key: "seating", label: "🪑 Seating / benches" },
  { key: "shade", label: "🌳 Shade / covered areas" },
  { key: "lighting", label: "🌙 Well-lit" },
  { key: "beach_access", label: "🏖️ Beach access" },
  { key: "trails", label: "🏃 Walking / hiking trails" },
  { key: "food_nearby", label: "☕ Food / drinks nearby" },
];

export function AddPlace() {
  const navigate = useNavigate();
  const { user, profile } = useAuth();
  const { showToast } = useToast();
  const [name, setName] = useState("");
  const [category, setCategory] = useState<PlaceCategory>("dog_park");
  const [description, setDescription] = useState("");
  const [address, setAddress] = useState("");
  const [lat, setLat] = useState<number | null>(null);
  const [lng, setLng] = useState<number | null>(null);
  const [city, setCity] = useState("");
  const [state, setState] = useState("");
  const [features, setFeatures] = useState<PlaceFeature[]>([]);
  const [photos, setPhotos] = useState<File[]>([]);
  const [previews, setPreviews] = useState<string[]>([]);
  const [rating, setRating] = useState(0);
  const [space, setSpace] = useState(0);
  const [safety, setSafety] = useState(0);
  const [cleanliness, setCleanliness] = useState(0);
  const [saving, setSaving] = useState(false);
  const [warningPlaceId, setWarningPlaceId] = useState<string | null>(null);
  const requiresEmailVerification = !!user && !user.emailVerified;

  useEffect(() => {
    const urls = photos.map((file) => URL.createObjectURL(file));
    setPreviews(urls);
    return () => {
      urls.forEach((url) => URL.revokeObjectURL(url));
    };
  }, [photos]);

  const toggleFeature = (key: PlaceFeature) => {
    setFeatures((prev) =>
      prev.includes(key) ? prev.filter((item) => item !== key) : [...prev, key]
    );
  };

  const handlePhotos = (files: FileList | null) => {
    if (!files) return;
    const incoming = Array.from(files).slice(0, 5 - photos.length);
    setPhotos((prev) => [...prev, ...incoming]);
  };

  const handleUseMyLocation = async () => {
    try {
      if (!navigator.geolocation) throw new Error("Geolocation not supported");
      const position = await new Promise<GeolocationPosition>((resolve, reject) => {
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
          { enableHighAccuracy: false, timeout: 15000, maximumAge: 60000 }
        );
        timeoutId = window.setTimeout(() => {
          if (settled) return;
          settled = true;
          cleanup(watchId);
          reject(new Error("timeout"));
        }, 15000);
      });
      const { latitude, longitude } = position.coords;
      setLat(latitude);
      setLng(longitude);
      const apiKey = import.meta.env.VITE_GEOAPIFY_KEY as string | undefined;
      if (!apiKey) throw new Error("Geoapify key missing");
      const res = await fetch(
        `https://api.geoapify.com/v1/geocode/reverse?lat=${latitude}&lon=${longitude}&apiKey=${apiKey}`
      );
      const data = await res.json();
      const props = data?.features?.[0]?.properties || {};
      const formatted = props.formatted || "";
      const placeCity = props.city || props.county || "";
      const placeState = props.state || "";
      setAddress(formatted);
      setCity(placeCity);
      setState(placeState);
      if (!name) setName(props.name || props.street || formatted);
    } catch {
      showToast("Unable to fetch location. Please enter address manually.", "error");
    }
  };

  const handleSubmit = async () => {
    if (!user) {
      showToast("Please login to add a place.", "error");
      return;
    }
    if (requiresEmailVerification) {
      showToast("Please verify your email before creating places", "warning");
      return;
    }
    if (!name.trim() || !description.trim()) {
      showToast("Please fill in name and description.", "error");
      return;
    }
    if (!address.trim() || lat === null || lng === null) {
      showToast("Please select a valid address.", "error");
      return;
    }
    setSaving(true);
    try {
      const existing = await findNearbyPlace(lat, lng);
      if (existing) {
        setWarningPlaceId(existing.id);
        showToast("This place may already exist.", "warning");
        if (photos.length > 0 && rating === 0) {
          showToast(
            "To attach photos to an existing place, please add a rating first.",
            "warning"
          );
          return;
        }
      }
      const photoUrls = await Promise.all(
        photos.map((file) => uploadImage(file))
      );
      const { locationId, alreadyExisted } = await addPlace({
        name: name.trim(),
        category,
        description: description.trim(),
        address: address.trim(),
        lat,
        lng,
        city: city || "",
        state: state || "",
        features,
        photos: photoUrls,
        addedBy: user.uid,
        addedByName: profile?.displayName || user.displayName || "PetNote User",
      });
      if (rating > 0) {
        await submitReview(locationId, {
          userId: user.uid,
          userName: profile?.displayName || user.displayName || "PetNote User",
          userAvatar:
            profile?.avatarUrl ||
            user.photoURL ||
            `https://api.dicebear.com/7.x/thumbs/svg?seed=${user.uid}`,
          rating,
          comment: "",
          photos: photoUrls,
          tags: [],
          petFriendly: {
            space: space || rating,
            safety: safety || rating,
            cleanliness: cleanliness || rating,
          },
        });
      }
      showToast(alreadyExisted ? "Place contribution added!" : "Place added!", "success");
      navigate(`/location/${locationId}`, { replace: true });
    } catch {
      showToast("Failed to add place.", "error");
    } finally {
      setSaving(false);
    }
  };

  const remainingDesc = useMemo(() => 500 - description.length, [description]);

  if (!user) return null;

  return (
    <div className="min-h-screen bg-white pb-10 dark:bg-slate-900">
      <header className="sticky top-0 z-10 border-b border-slate-200 bg-white dark:border-slate-800 dark:bg-slate-900">
        <div className="mx-auto flex w-full max-w-md items-center justify-between px-4 py-3">
          <button
            type="button"
            onClick={() => navigate(-1)}
            className="text-xl text-slate-500 hover:text-slate-700 dark:text-slate-300"
          >
            ←
          </button>
          <h1 className="text-base font-semibold text-slate-900 dark:text-white">
            Add a Place
          </h1>
          <button
            type="button"
            onClick={handleSubmit}
            disabled={saving || requiresEmailVerification}
            className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-1.5 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
          >
            {saving
              ? "Submitting..."
              : requiresEmailVerification
              ? "🔒 Verify Email"
              : "Submit"}
          </button>
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-6 px-4 py-6">
        {requiresEmailVerification ? (
          <section className="rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-700 dark:border-amber-500/30 dark:bg-amber-500/10 dark:text-amber-200">
            Verify your email to create new places.
          </section>
        ) : null}
        <div className="space-y-3">
          <div className="flex items-center justify-between">
            <label className="text-sm font-semibold text-slate-700 dark:text-slate-200">
              Place Name
            </label>
            <span className="text-xs text-slate-400">{name.length}/60</span>
          </div>
          <input
            value={name}
            onChange={(event) => setName(event.target.value)}
            maxLength={60}
            placeholder="Sunset Dog Park"
            className="w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
          />
        </div>

        <div className="space-y-3">
          <p className="text-sm font-semibold text-slate-700 dark:text-slate-200">
            Category
          </p>
          <div className="grid grid-cols-3 gap-3">
            {categories.map((option) => {
              const selected = category === option.key;
              return (
                <button
                  key={option.key}
                  type="button"
                  onClick={() => setCategory(option.key)}
                  className={`flex flex-col items-center justify-center gap-1 rounded-2xl border px-2 py-3 text-xs font-semibold transition-all duration-200 ${
                    selected
                      ? `${option.color} bg-purple-50 text-purple-700`
                      : "border-slate-200 text-slate-500 dark:border-slate-700 dark:text-slate-300"
                  }`}
                >
                  <span className="text-lg">{option.label.split(" ")[0]}</span>
                  <span>{option.label.replace(/^.*?\s/, "")}</span>
                </button>
              );
            })}
          </div>
        </div>

        <div className="space-y-3">
          <div className="flex items-center justify-between">
            <label className="text-sm font-semibold text-slate-700 dark:text-slate-200">
              Description
            </label>
            <span
              className={`text-xs ${remainingDesc <= 80 ? "text-amber-500" : "text-slate-400"}`}
            >
              {description.length}/500
            </span>
          </div>
          <textarea
            value={description}
            onChange={(event) => setDescription(event.target.value)}
            maxLength={500}
            rows={4}
            placeholder="A spacious off-leash dog park with separate areas for large and small dogs..."
            className="w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
          />
        </div>

        <div className="space-y-3">
          <p className="text-sm font-semibold text-slate-700 dark:text-slate-200">
            Address
          </p>
          <AddressAutocomplete
            value={address}
            onChange={(value, location) => {
              setAddress(value);
              if (location) {
                setLat(location.lat);
                setLng(location.lng);
                setCity(location.city || "");
                setState(location.state || "");
              } else {
                setLat(null);
                setLng(null);
                setCity("");
                setState("");
              }
            }}
            placeholder="Search for a place"
          />
          <button
            type="button"
            onClick={handleUseMyLocation}
            className="rounded-full border border-slate-200 px-3 py-1.5 text-xs font-semibold text-slate-600 transition-all duration-200 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-300"
          >
            Use My Location
          </button>
        </div>

        <div className="space-y-3">
          <p className="text-sm font-semibold text-slate-700 dark:text-slate-200">
            Photos
          </p>
          <p className="text-xs text-slate-400">
            📸 Add photos to help others find this place
          </p>
          <div className="grid grid-cols-3 gap-2">
            {previews.map((url, idx) => (
              <div key={url} className="relative aspect-square overflow-hidden rounded-xl">
                <img src={url} alt={`Preview ${idx + 1}`} className="h-full w-full object-cover" />
              </div>
            ))}
            {photos.length < 5 ? (
              <label className="flex aspect-square items-center justify-center rounded-xl border border-dashed border-slate-300 text-sm text-slate-400">
                +
                <input
                  type="file"
                  accept="image/*"
                  multiple
                  className="hidden"
                  onChange={(event) => handlePhotos(event.target.files)}
                />
              </label>
            ) : null}
          </div>
        </div>

        <div className="space-y-3">
          <p className="text-sm font-semibold text-slate-700 dark:text-slate-200">
            What does this place offer?
          </p>
          <div className="flex flex-wrap gap-2">
            {featureOptions.map((option) => {
              const selected = features.includes(option.key);
              return (
                <button
                  key={option.key}
                  type="button"
                  onClick={() => toggleFeature(option.key)}
                  className={`rounded-full px-3 py-1 text-xs font-semibold transition-all duration-200 ${
                    selected
                      ? "bg-gradient-to-r from-purple-500 to-pink-500 text-white"
                      : "border border-slate-300 text-slate-600 dark:border-slate-600 dark:text-slate-300"
                  }`}
                >
                  {option.label}
                </button>
              );
            })}
          </div>
        </div>

        <div className="space-y-3">
          <p className="text-sm font-semibold text-slate-700 dark:text-slate-200">
            Your Rating (optional)
          </p>
          <div className="flex items-center gap-2 text-2xl">
            {[1, 2, 3, 4, 5].map((value) => (
              <button
                key={value}
                type="button"
                onClick={() => setRating(value)}
                className={`transition-transform duration-150 ${
                  rating >= value ? "scale-110 text-amber-500" : "text-slate-300"
                }`}
              >
                {rating >= value ? "⭐" : "☆"}
              </button>
            ))}
          </div>
          <div className="space-y-2 text-sm text-slate-600 dark:text-slate-300">
            {[
              { label: "🐾 Space", value: space, setter: setSpace },
              { label: "🛡️ Safety", value: safety, setter: setSafety },
              { label: "✨ Cleanliness", value: cleanliness, setter: setCleanliness },
            ].map((item) => (
              <div key={item.label} className="flex items-center justify-between">
                <span>{item.label}</span>
                <div className="flex items-center gap-1">
                  {[1, 2, 3, 4, 5].map((value) => (
                    <button
                      key={value}
                      type="button"
                      onClick={() => item.setter(value)}
                      className={`h-2 w-2 rounded-full ${
                        item.value >= value
                          ? "bg-gradient-to-r from-purple-500 to-pink-500"
                          : "bg-slate-300 dark:bg-slate-600"
                      }`}
                    />
                  ))}
                </div>
              </div>
            ))}
          </div>
        </div>

        {warningPlaceId ? (
          <div className="rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 text-xs text-amber-700 dark:border-amber-500/30 dark:bg-amber-500/10 dark:text-amber-200">
            This place may already exist.{" "}
            <button
              type="button"
              onClick={() => navigate(`/location/${warningPlaceId}`)}
              className="font-semibold text-amber-700 underline"
            >
              View existing place
            </button>
          </div>
        ) : null}

        <p className="text-center text-xs text-slate-400">
          ℹ️ Only recommend places you've personally visited with your pet. Please ensure the location is safe and accessible.
        </p>
      </main>
    </div>
  );
}
