import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { Timestamp } from "firebase/firestore";
import { useAuth } from "../hooks/useAuth";
import { uploadImage } from "../services/cloudinary";
import {
  createPet,
  getPetById,
  updatePet,
  PET_FAMILY_RELATIONSHIP_OPTIONS,
  type Pet,
  type PetFamilyRelationship,
} from "../services/pets";
import {
  useInvitation,
  validateInvitationCode,
} from "../services/invitations";
import {
  getSpeciesMeta,
  PET_SPECIES,
  type PetGender,
  type PetSpecies,
} from "../utils/petHelpers";
import { optimizeCloudinaryUrl } from "../utils/cloudinaryUrl";
import { useToast } from "../contexts/ToastContext";

const MAX_BIO = 150;
const MAX_NAME = 20;
const MAX_CUSTOM_RELATION = 30;

type RelationshipSelectorProps = {
  selected: PetFamilyRelationship | null;
  customValue: string;
  onSelect: (value: PetFamilyRelationship) => void;
  onCustomValueChange: (value: string) => void;
};

const normalizeInviteCode = (value: string): string =>
  value.replace(/[^a-zA-Z0-9]/g, "").toUpperCase().slice(0, 8);

const formatInviteCode = (value: string): string => {
  if (value.length <= 4) return value;
  return `${value.slice(0, 4)} ${value.slice(4)}`;
};

function RelationshipSelector({
  selected,
  customValue,
  onSelect,
  onCustomValueChange,
}: RelationshipSelectorProps) {
  return (
    <div className="space-y-2">
      <label className="text-sm font-semibold text-slate-700 dark:text-slate-200">
        What&apos;s your relationship?
      </label>
      <div className="grid grid-cols-3 gap-2">
        {PET_FAMILY_RELATIONSHIP_OPTIONS.map((item) => {
          const active = selected === item.value;
          return (
            <button
              key={item.value}
              type="button"
              onClick={() => onSelect(item.value)}
              className={`rounded-2xl border px-2 py-2 text-center text-xs font-semibold transition-all duration-200 ${
                active
                  ? "border-purple-400 bg-purple-50 text-purple-700 dark:border-purple-400 dark:bg-purple-500/10"
                  : "border-slate-200 text-slate-600 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-300"
              }`}
            >
              <span className="block text-base leading-none">{item.emoji}</span>
              <span className="mt-1 block truncate">{item.label}</span>
            </button>
          );
        })}
      </div>
      {selected === "other" ? (
        <input
          type="text"
          maxLength={MAX_CUSTOM_RELATION}
          value={customValue}
          onChange={(event) => onCustomValueChange(event.target.value)}
          placeholder="Enter relationship"
          className="w-full rounded-xl border border-slate-200 bg-slate-50 px-4 py-2 text-sm text-slate-700 outline-none transition-all duration-200 focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
        />
      ) : null}
    </div>
  );
}

export function AddPet() {
  const navigate = useNavigate();
  const { petId } = useParams();
  const { user } = useAuth();
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [mode, setMode] = useState<"new" | "existing">("new");
  const [name, setName] = useState("");
  const [species, setSpecies] = useState<PetSpecies | "">("");
  const [breed, setBreed] = useState("");
  const [gender, setGender] = useState<PetGender>("unknown");
  const [birthday, setBirthday] = useState("");
  const [bio, setBio] = useState("");
  const [avatarUrl, setAvatarUrl] = useState("");
  const [avatarFile, setAvatarFile] = useState<File | null>(null);
  const [relationship, setRelationship] = useState<PetFamilyRelationship | null>(null);
  const [customRelationship, setCustomRelationship] = useState("");
  const [inviteCode, setInviteCode] = useState("");
  const [pendingInvite, setPendingInvite] = useState<{
    code: string;
    petId: string;
    petName: string;
  } | null>(null);
  const [joinRelationship, setJoinRelationship] = useState<PetFamilyRelationship | null>(null);
  const [joinCustomRelationship, setJoinCustomRelationship] = useState("");
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [validatingInvite, setValidatingInvite] = useState(false);
  const [joiningFamily, setJoiningFamily] = useState(false);
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
    if (!isEdit && !relationship) {
      showToast("Please select your relationship.", "error");
      return;
    }

    setSaving(true);

    try {
      let finalAvatarUrl = avatarUrl;
      if (avatarFile) {
        finalAvatarUrl = await uploadImage(avatarFile);
      }

      const payload: Omit<Pet, "id" | "ownerId" | "createdAt" | "primaryOwnerId"> = {
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
        targetId = await createPet(
          user.uid,
          payload,
          relationship || "other",
          relationship === "other" ? customRelationship : undefined
        );
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

  const handleValidateInvite = async () => {
    const normalized = normalizeInviteCode(inviteCode);
    if (validatingInvite || normalized.length !== 8) return;
    setValidatingInvite(true);
    try {
      const result = await validateInvitationCode(normalized);
      if (!result.valid || !result.petId || !result.petName) {
        showToast(result.error || "Invalid invitation code.", "error");
        return;
      }
      setPendingInvite({
        code: normalized,
        petId: result.petId,
        petName: result.petName,
      });
      setInviteCode(normalized);
      showToast(`Code accepted for ${result.petName}.`, "success");
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : "Failed to validate code. Please try again.";
      showToast(message, "error");
    } finally {
      setValidatingInvite(false);
    }
  };

  const handleJoinFamily = async () => {
    if (!pendingInvite || !joinRelationship || joiningFamily) {
      return;
    }
    setJoiningFamily(true);
    try {
      const result = await useInvitation(
        pendingInvite.code,
        user.uid,
        user.displayName || "User",
        user.photoURL || `https://api.dicebear.com/7.x/thumbs/svg?seed=${user.uid}`,
        joinRelationship,
        joinRelationship === "other" ? joinCustomRelationship : undefined
      );
      if (!result.success || !result.petId) {
        showToast(result.error || "Could not join family.", "error");
        return;
      }
      showToast(`Welcome to ${result.petName || pendingInvite.petName}'s family!`, "success");
      navigate(`/pet/${result.petId}`, { replace: true });
    } catch (error) {
      showToast("Could not join family.", "error");
    } finally {
      setJoiningFamily(false);
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
          {isEdit || mode === "new" ? (
            <button
              type="button"
              onClick={handleSave}
              disabled={saving}
              className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-1.5 text-sm font-semibold text-white shadow-md transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
            >
              {saving ? "Saving..." : "Save"}
            </button>
          ) : (
            <div className="w-16" />
          )}
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-6 px-4 py-6">
        {!isEdit ? (
          <div className="grid grid-cols-2 rounded-2xl bg-slate-100 p-1 dark:bg-slate-800">
            <button
              type="button"
              onClick={() => setMode("new")}
              className={`rounded-xl px-3 py-2 text-sm font-semibold transition-all duration-200 ${
                mode === "new"
                  ? "bg-white text-slate-900 shadow-sm dark:bg-slate-700 dark:text-white"
                  : "text-slate-500 dark:text-slate-300"
              }`}
            >
              New Pet
            </button>
            <button
              type="button"
              onClick={() => setMode("existing")}
              className={`rounded-xl px-3 py-2 text-sm font-semibold transition-all duration-200 ${
                mode === "existing"
                  ? "bg-white text-slate-900 shadow-sm dark:bg-slate-700 dark:text-white"
                  : "text-slate-500 dark:text-slate-300"
              }`}
            >
              Existing Pet
            </button>
          </div>
        ) : null}

        {loading ? (
          <div className="rounded-2xl bg-slate-50 p-6 text-center text-sm text-slate-500 dark:bg-slate-800 dark:text-slate-300">
            Loading pet profile...
          </div>
        ) : null}

        {isEdit || mode === "new" ? (
          <>
            <section className="rounded-3xl bg-white p-6 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
              <div className="flex flex-col items-center text-center">
                <div className={`rounded-full bg-gradient-to-r ${speciesMeta.gradient} p-1`}>
                  {avatarUrl ? (
                    <img
                      src={optimizeCloudinaryUrl(avatarUrl, "avatar")}
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

              {!isEdit ? (
                <RelationshipSelector
                  selected={relationship}
                  customValue={customRelationship}
                  onSelect={setRelationship}
                  onCustomValueChange={setCustomRelationship}
                />
              ) : null}
            </section>
          </>
        ) : (
          <section className="space-y-4 rounded-2xl border border-slate-200 bg-white p-4 dark:border-slate-700 dark:bg-slate-800">
            <div>
              <p className="text-sm font-semibold text-slate-900 dark:text-white">
                Join your pet&apos;s family with an invitation code
              </p>
              <p className="mt-1 text-xs text-slate-500 dark:text-slate-300">
                Enter the 8-character code shared by a family member.
              </p>
            </div>

            <input
              type="text"
              value={formatInviteCode(inviteCode)}
              onChange={(event) => {
                const normalized = normalizeInviteCode(event.target.value);
                setInviteCode(normalized);
                setPendingInvite(null);
              }}
              maxLength={9}
              placeholder="XXXX XXXX"
              className="w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-center font-mono text-2xl tracking-[0.28em] text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-900 dark:text-white"
            />

            <button
              type="button"
              onClick={handleValidateInvite}
              disabled={inviteCode.length !== 8 || validatingInvite}
              className="w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
            >
              {validatingInvite ? "Validating..." : "Join Family"}
            </button>

            {pendingInvite ? (
              <div className="space-y-3 rounded-2xl border border-slate-200 bg-slate-50 p-3 dark:border-slate-700 dark:bg-slate-900">
                <p className="text-sm font-semibold text-slate-900 dark:text-white">
                  Invitation accepted for {pendingInvite.petName}
                </p>

                <RelationshipSelector
                  selected={joinRelationship}
                  customValue={joinCustomRelationship}
                  onSelect={setJoinRelationship}
                  onCustomValueChange={setJoinCustomRelationship}
                />

                <button
                  type="button"
                  onClick={handleJoinFamily}
                  disabled={!joinRelationship || joiningFamily}
                  className="w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
                >
                  {joiningFamily ? "Joining..." : "Confirm Join"}
                </button>
              </div>
            ) : null}
          </section>
        )}
      </main>
    </div>
  );
}
