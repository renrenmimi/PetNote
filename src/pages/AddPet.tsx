import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { Timestamp } from "firebase/firestore";
import { useAuth } from "../hooks/useAuth";
import { uploadImage } from "../services/cloudinary";
import {
  createPet,
  getPetById,
  updatePet,
  type Pet,
} from "../services/pets";
import {
  getSpeciesMeta,
  PET_SPECIES,
  type PetGender,
  type PetSpecies,
} from "../utils/petHelpers";
import { useToast } from "../contexts/ToastContext";

const MAX_BIO = 150;
const MAX_NAME = 20;

export function AddPet() {
  const navigate = useNavigate();
  const { petId } = useParams();
  const { user } = useAuth();
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [name, setName] = useState("");
  const [species, setSpecies] = useState<PetSpecies | "">("");
  const [breed, setBreed] = useState("");
  const [gender, setGender] = useState<PetGender>("unknown");
  const [birthday, setBirthday] = useState("");
  const [bio, setBio] = useState("");
  const [avatarUrl, setAvatarUrl] = useState("");
  const [avatarFile, setAvatarFile] = useState<File | null>(null);
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const { showToast } = useToast();

  const isEdit = Boolean(petId);
  const remaining = useMemo(() => MAX_BIO - bio.length, [bio.length]);
  const bioCounterTone =
    remaining <= 0
      ? "text-red-500"
      : remaining <= Math.ceil(MAX_BIO * 0.2)
      ? "text-amber-500"
      : "text-slate-400 dark:text-slate-500";
  const nameRemaining = useMemo(() => MAX_NAME - name.length, [name.length]);
  const nameCounterTone =
    nameRemaining <= 0
      ? "text-red-500"
      : nameRemaining <= Math.ceil(MAX_NAME * 0.2)
      ? "text-amber-500"
      : "text-slate-400 dark:text-slate-500";
  const speciesMeta = getSpeciesMeta(species as PetSpecies);

  useEffect(() => {
    let ignore = false;
    if (!petId) return;
    const load = async () => {
      setLoading(true);
      const pet = await getPetById(petId);
      if (ignore) return;
      if (!pet) {
        setLoading(false);
        return;
      }
      setName(pet.name);
      setSpecies(pet.species);
      setBreed(pet.breed || "");
      setGender(pet.gender);
      setBio(pet.bio || "");
      setAvatarUrl(pet.avatarUrl || "");
      if (pet.birthday) {
        const date =
          pet.birthday instanceof Date
            ? pet.birthday
            : typeof pet.birthday === "object" &&
              pet.birthday !== null &&
              "toDate" in pet.birthday &&
              typeof (pet.birthday as { toDate: () => Date }).toDate ===
                "function"
            ? (pet.birthday as { toDate: () => Date }).toDate()
            : null;
        if (date) {
          const formatted = date.toISOString().slice(0, 10);
          setBirthday(formatted);
        }
      }
      setLoading(false);
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [petId]);

  if (!user) {
    return null;
  }

  const handleAvatarChange = (file: File | null) => {
    if (!file) return;
    setAvatarFile(file);
    setAvatarUrl(URL.createObjectURL(file));
  };

  const handleSave = async () => {
    if (!user || saving) return;
    if (!name.trim() || name.trim().length < 2) {
      showToast("Pet name must be at least 2 characters.", "error");
      return;
    }
    if (!species) {
      showToast("Please select a species.", "error");
      return;
    }
    if (name.trim().length > 20) {
      showToast("Pet name must be 2-20 characters.", "error");
      return;
    }

    setSaving(true);

    try {
      let finalAvatarUrl = avatarUrl;
      if (avatarFile) {
        finalAvatarUrl = await uploadImage(avatarFile);
      }

      const payload: Omit<Pet, "id" | "ownerId" | "createdAt"> = {
        name: name.trim(),
        species: species as PetSpecies,
        breed: breed.trim(),
        gender,
        bio: bio.trim(),
        avatarUrl: finalAvatarUrl || "",
        ...(birthday
          ? { birthday: Timestamp.fromDate(new Date(birthday)) }
          : {}),
      };

      let targetId = petId;
      if (isEdit && petId) {
        await updatePet(petId, payload);
      } else {
        targetId = await createPet(user.uid, payload);
      }

      if (targetId) {
        navigate(`/pet/${targetId}`, { replace: true });
      }
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to save pet.";
      showToast(message, "error");
    } finally {
      setSaving(false);
    }
  };

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
            {isEdit ? "Edit Pet" : "Add Pet"}
          </h1>
          <button
            type="button"
            onClick={handleSave}
            disabled={saving}
            className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-1.5 text-sm font-semibold text-white shadow-md transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
          >
            {saving ? "Saving..." : "Save"}
          </button>
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-6 px-4 py-6">
        {loading ? (
          <div className="rounded-2xl bg-slate-50 p-6 text-center text-sm text-slate-500 dark:bg-slate-800 dark:text-slate-300">
            Loading pet profile...
          </div>
        ) : null}

        <section className="rounded-3xl bg-white p-6 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <div className="flex flex-col items-center text-center">
            <div className={`rounded-full bg-gradient-to-r ${speciesMeta.gradient} p-1`}>
              {avatarUrl ? (
                <img
                  src={avatarUrl}
                  alt={name || "Pet avatar"}
                  className="h-24 w-24 rounded-full border-4 border-white object-cover dark:border-slate-800"
                />
              ) : (
                <div className="flex h-24 w-24 items-center justify-center rounded-full border-4 border-white bg-white text-4xl dark:border-slate-800 dark:bg-slate-900">
                  {speciesMeta.emoji}
                </div>
              )}
            </div>
            <button
              type="button"
              onClick={() => fileInputRef.current?.click()}
              className="mt-3 text-sm font-semibold text-purple-600"
            >
              Change Photo
            </button>
            <input
              ref={fileInputRef}
              type="file"
              accept="image/jpeg,image/png,image/webp"
              className="hidden"
              onChange={(event) =>
                handleAvatarChange(event.target.files?.[0] ?? null)
              }
            />
          </div>
        </section>

        <section className="space-y-4">
          <div>
            <div className="flex items-center justify-between">
              <label className="text-sm font-semibold text-slate-700 dark:text-slate-200">
                Pet Name
              </label>
              <span className={`text-xs ${nameCounterTone}`}>
                {name.length}/{MAX_NAME}
              </span>
            </div>
            <input
              type="text"
              value={name}
              maxLength={MAX_NAME}
              placeholder="Your pet's name"
              onChange={(event) => setName(event.target.value)}
              className="mt-2 w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
            />
          </div>

          <div>
            <label className="text-sm font-semibold text-slate-700 dark:text-slate-200">
              Species
            </label>
            <select
              value={species}
              onChange={(event) =>
                setSpecies(event.target.value as PetSpecies)
              }
              className="mt-2 w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
            >
              <option value="">Select species</option>
              {PET_SPECIES.map((item) => (
                <option key={item.value} value={item.value}>
                  {item.emoji} {item.label}
                </option>
              ))}
            </select>
          </div>

          <div>
            <label className="text-sm font-semibold text-slate-700 dark:text-slate-200">
              Breed
            </label>
            <input
              type="text"
              value={breed}
              placeholder="e.g. Golden Retriever"
              onChange={(event) => setBreed(event.target.value)}
              className="mt-2 w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
            />
          </div>

          <div>
            <label className="text-sm font-semibold text-slate-700 dark:text-slate-200">
              Gender
            </label>
            <div className="mt-2 flex items-center gap-3">
              {(["male", "female", "unknown"] as PetGender[]).map((value) => (
                <button
                  key={value}
                  type="button"
                  onClick={() => setGender(value)}
                  className={`rounded-full border px-4 py-2 text-sm font-semibold transition-all duration-200 ${
                    gender === value
                      ? "border-purple-400 bg-purple-50 text-purple-600 dark:bg-purple-500/10"
                      : "border-slate-200 text-slate-500 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-300"
                  }`}
                >
                  {value === "male" ? (
                    <span className="text-lg font-bold text-blue-500">♂</span>
                  ) : value === "female" ? (
                    <span className="text-lg font-bold text-pink-500">♀</span>
                  ) : (
                    <span className="text-lg font-semibold text-slate-400">—</span>
                  )}
                </button>
              ))}
            </div>
          </div>

          <div>
            <label className="text-sm font-semibold text-slate-700 dark:text-slate-200">
              Birthday
            </label>
            <input
              type="date"
              value={birthday}
              onChange={(event) => setBirthday(event.target.value)}
              className="mt-2 w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
            />
          </div>

          <div>
            <div className="flex items-center justify-between">
              <label className="text-sm font-semibold text-slate-700 dark:text-slate-200">
                Bio
              </label>
              <span className={`text-xs ${bioCounterTone}`}>
                {bio.length}/{MAX_BIO}
              </span>
            </div>
            <textarea
              rows={4}
              value={bio}
              maxLength={MAX_BIO}
              placeholder="Tell us about your pet..."
              onChange={(event) => setBio(event.target.value)}
              className="mt-2 w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
            />
          </div>
        </section>
      </main>
    </div>
  );
}
