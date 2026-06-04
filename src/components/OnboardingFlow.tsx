import { useEffect, useMemo, useRef, useState } from "react";
import { doc, getDoc, serverTimestamp } from "firebase/firestore";
import PawIcon from "./PawIcon";
import Avatar from "./Avatar";
import { auth, db } from "../services/firebase";
import {
  deleteCloudinaryAssets,
  uploadImage,
  type UploadedAsset,
} from "../services/cloudinary";
import {
  createPet,
  PET_FAMILY_RELATIONSHIP_OPTIONS,
  type Pet,
  type PetFamilyRelationship,
} from "../services/pets";
import {
  completeOnboarding,
  createUserProfile,
  generateUniqueUsername,
  isUsernameTaken,
  updateUserProfile,
  validateUsername,
} from "../services/users";
import { PET_SPECIES, type PetSpecies } from "../utils/petHelpers";
import { useToast } from "../contexts/ToastContext";
import { getSuggestedPets } from "../services/explore";
import { followPet } from "../services/follow";
import { redeemInvitation, validateInvitationCode } from "../services/invitations";

type OnboardingFlowProps = {
  userId: string;
  onComplete: () => void;
};

const stepCount = 5;

const normalizeInviteCode = (value: string): string =>
  value.replace(/[^a-zA-Z0-9]/g, "").toUpperCase().slice(0, 8);

const formatInviteCode = (value: string): string => {
  if (value.length <= 4) return value;
  return `${value.slice(0, 4)} ${value.slice(4, 8)}`;
};

export function OnboardingFlow({ userId, onComplete }: OnboardingFlowProps) {
  const [step, setStep] = useState(() => {
    if (typeof window === "undefined") return 0;
    const saved = window.localStorage.getItem("onboardingStep");
    const value = saved ? Number(saved) : 0;
    return Number.isFinite(value)
      ? Math.max(0, Math.min(value, stepCount - 1))
      : 0;
  });
  const [username, setUsername] = useState("");
  const [initialUsername, setInitialUsername] = useState("");
  const [usernameChecking, setUsernameChecking] = useState(false);
  const [usernameTaken, setUsernameTaken] = useState(false);
  const [savingUsername, setSavingUsername] = useState(false);
  const [petName, setPetName] = useState("");
  const [species, setSpecies] = useState<PetSpecies | null>(null);
  const [relationship, setRelationship] = useState<PetFamilyRelationship | null>(
    null
  );
  const [customRelationship, setCustomRelationship] = useState("");
  const [avatarFile, setAvatarFile] = useState<File | null>(null);
  const [avatarPreview, setAvatarPreview] = useState<string | null>(null);
  const [savingPet, setSavingPet] = useState(false);
  const [showInviteJoin, setShowInviteJoin] = useState(false);
  const [inviteCode, setInviteCode] = useState("");
  const [pendingInvite, setPendingInvite] = useState<{
    code: string;
    petName: string;
  } | null>(null);
  const [joinRelationship, setJoinRelationship] =
    useState<PetFamilyRelationship | null>(null);
  const [joinCustomRelationship, setJoinCustomRelationship] = useState("");
  const [validatingInvite, setValidatingInvite] = useState(false);
  const [joiningFamily, setJoiningFamily] = useState(false);
  const [suggestedPets, setSuggestedPets] = useState<Array<Pet & { postCount: number }>>([]);
  const [suggestedLoading, setSuggestedLoading] = useState(false);
  const [followedIds, setFollowedIds] = useState<Set<string>>(new Set());
  const touchStartRef = useRef(0);
  const touchStartYRef = useRef(0);
  const { showToast } = useToast();

  useEffect(() => {
    if (typeof window === "undefined") return;
    window.localStorage.setItem("onboardingStep", String(step));
  }, [step]);

  useEffect(() => {
    return () => {
      if (avatarPreview) {
        URL.revokeObjectURL(avatarPreview);
      }
    };
  }, [avatarPreview]);

  useEffect(() => {
    let ignore = false;
    const loadUsername = async () => {
      const currentUser = auth.currentUser;
      if (!currentUser) return;
      const current = currentUser.displayName?.trim();
      if (current) {
        if (!ignore) {
          setUsername(current);
          setInitialUsername(current);
        }
        return;
      }
      try {
        const generated = await generateUniqueUsername();
        if (!ignore) {
          setUsername(generated);
          setInitialUsername(generated);
        }
      } catch {
        // Keep empty and let user type manually.
      }
    };
    void loadUsername();
    return () => {
      ignore = true;
    };
  }, []);

  const usernameValidation = useMemo(
    () => validateUsername(username.trim()),
    [username]
  );

  useEffect(() => {
    let ignore = false;
    const normalized = username.trim();
    const unchanged =
      normalized.toLowerCase() === initialUsername.trim().toLowerCase();
    if (!normalized || !usernameValidation.valid || unchanged) {
      setUsernameChecking(false);
      setUsernameTaken(false);
      return;
    }
    setUsernameChecking(true);
    const timer = window.setTimeout(async () => {
      try {
        const taken = await isUsernameTaken(normalized);
        if (!ignore) {
          setUsernameTaken(taken);
        }
      } catch {
        if (!ignore) {
          setUsernameTaken(false);
        }
      } finally {
        if (!ignore) {
          setUsernameChecking(false);
        }
      }
    }, 500);

    return () => {
      ignore = true;
      window.clearTimeout(timer);
    };
  }, [initialUsername, username, usernameValidation.valid]);

  useEffect(() => {
    let ignore = false;
    if (!userId) return;
    const loadSuggested = async () => {
      setSuggestedLoading(true);
      try {
        const pets = await getSuggestedPets(userId, 8);
        if (!ignore) setSuggestedPets(pets);
      } catch (error) {
        console.error("Failed to load suggested users:", error);
      } finally {
        if (!ignore) setSuggestedLoading(false);
      }
    };
    void loadSuggested();
    return () => {
      ignore = true;
    };
  }, [userId]);

  const dots = useMemo(
    () =>
      Array.from({ length: stepCount }).map((_, index) => (
        <span
          key={index}
          className={`h-2 w-2 rounded-full transition-all duration-300 ${
            index === step ? "bg-purple-500" : "bg-slate-300 dark:bg-slate-600"
          }`}
        />
      )),
    [step]
  );

  const handleNext = () => setStep((prev) => Math.min(prev + 1, stepCount - 1));
  const handleBack = () => setStep((prev) => Math.max(prev - 1, 0));

  const handleFinish = async () => {
    await completeOnboarding(userId);
    localStorage.removeItem("onboardingStep");
    onComplete();
  };

  const ensureUserProfile = async () => {
    const currentUser = auth.currentUser;
    if (!currentUser) {
      throw new Error("Please log in to continue.");
    }
    const userRef = doc(db, "users", currentUser.uid);
    const snapshot = await getDoc(userRef);
    if (!snapshot.exists()) {
      const displayName = currentUser.displayName || (await generateUniqueUsername());
      const avatarUrl =
        currentUser.photoURL ||
        `https://api.dicebear.com/7.x/thumbs/svg?seed=${currentUser.uid}`;
      await createUserProfile(currentUser.uid, {
        displayName,
        avatarUrl,
        bio: "",
        onboardingComplete: false,
        createdAt: serverTimestamp(),
      });
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    return currentUser;
  };

  const handleAddPet = async () => {
    if (!petName.trim() || !species || !relationship) {
      showToast("Please add a pet name, species, and relationship.", "warning");
      return;
    }
    setSavingPet(true);
    const uploaded: UploadedAsset[] = [];
    try {
      const currentUser = await ensureUserProfile();
      let uploadedAvatarUrl = "";
      if (avatarFile) {
        const asset = await uploadImage(avatarFile);
        uploaded.push(asset);
        uploadedAvatarUrl = asset.url;
      }
      await createPet(
        currentUser.uid,
        {
          name: petName.trim(),
          species,
          breed: "",
          gender: "unknown",
          bio: "",
          avatarUrl: uploadedAvatarUrl,
        },
        relationship,
        relationship === "other" ? customRelationship : undefined
      );
      handleNext();
    } catch (error) {
      // Best-effort orphan cleanup if createPet rejected the new avatar.
      void deleteCloudinaryAssets(uploaded);
      const message =
        error instanceof Error ? error.message : "Failed to add pet.";
      showToast(message, "error");
    } finally {
      setSavingPet(false);
    }
  };

  const handleValidateInvitation = async () => {
    if (validatingInvite) return;
    const normalized = normalizeInviteCode(inviteCode);
    if (normalized.length !== 8) {
      showToast("Invitation code must be 8 characters.", "warning");
      return;
    }

    setValidatingInvite(true);
    try {
      const result = await validateInvitationCode(normalized);
      if (!result.valid || !result.petName) {
        showToast(result.error || "Invalid invitation code.", "error");
        return;
      }
      setInviteCode(normalized);
      setPendingInvite({ code: normalized, petName: result.petName });
      showToast(`Code accepted for ${result.petName}.`, "success");
    } catch {
      showToast("Unable to validate invitation code.", "error");
    } finally {
      setValidatingInvite(false);
    }
  };

  const handleJoinExistingPet = async () => {
    if (!pendingInvite || !joinRelationship || joiningFamily) {
      return;
    }

    setJoiningFamily(true);
    try {
      const currentUser = await ensureUserProfile();
      const result = await redeemInvitation(
        pendingInvite.code,
        currentUser.uid,
        currentUser.displayName || "User",
        currentUser.photoURL ||
          `https://api.dicebear.com/7.x/thumbs/svg?seed=${currentUser.uid}`,
        joinRelationship,
        joinRelationship === "other" ? joinCustomRelationship : undefined
      );
      if (!result.success) {
        showToast(result.error || "Could not join this pet family.", "error");
        return;
      }
      showToast(`Welcome to ${pendingInvite.petName}'s family.`, "success");
      handleNext();
    } catch {
      showToast("Could not join this pet family.", "error");
    } finally {
      setJoiningFamily(false);
    }
  };

  const handleFollow = async (petId: string) => {
    if (!userId || followedIds.has(petId)) return;
    try {
      await followPet(userId, petId);
      setFollowedIds((prev) => new Set(prev).add(petId));
      showToast("Now following.", "success");
    } catch (error) {
      console.error("Failed to follow pet:", error);
      showToast("Unable to follow right now.", "error");
    }
  };

  const handleContinueUsername = async () => {
    const currentUser = auth.currentUser;
    const normalized = username.trim();
    if (!currentUser) {
      showToast("Please log in to continue.", "error");
      return;
    }
    if (!usernameValidation.valid) {
      showToast(usernameValidation.error || "Invalid username.", "error");
      return;
    }
    if (usernameTaken) {
      showToast("This username is taken.", "error");
      return;
    }
    if (usernameChecking || savingUsername) {
      return;
    }

    setSavingUsername(true);
    try {
      await updateUserProfile(currentUser.uid, { displayName: normalized });
      setInitialUsername(normalized);
      handleNext();
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Failed to save username.";
      showToast(message, "error");
    } finally {
      setSavingUsername(false);
    }
  };

  const normalizedUsername = username.trim();
  const usernameUnchanged =
    normalizedUsername.toLowerCase() === initialUsername.trim().toLowerCase();
  const canContinueUsername =
    normalizedUsername.length > 0 &&
    usernameValidation.valid &&
    !usernameChecking &&
    !savingUsername &&
    (usernameUnchanged || !usernameTaken);

  return (
    <div
      className="fixed inset-0 z-50 flex flex-col items-center justify-between bg-white px-6 py-10 text-center dark:bg-slate-900"
      onTouchStart={(event) => {
        touchStartRef.current = event.touches[0].clientX;
        touchStartYRef.current = event.touches[0].clientY;
      }}
      onTouchEnd={(event) => {
        // Only treat the gesture as a swipe if the horizontal motion
        // dominates the vertical one — otherwise scrolling the long
        // form (relationship grid, suggested-pet list) on a phone
        // would silently flip the user to the next/previous step.
        const dx = event.changedTouches[0].clientX - touchStartRef.current;
        const dy =
          event.changedTouches[0].clientY - touchStartYRef.current;
        if (Math.abs(dx) < 50) return;
        if (Math.abs(dx) <= Math.abs(dy)) return;
        if (dx < 0) {
          handleNext();
        } else {
          handleBack();
        }
      }}
    >
      <div className="w-full max-w-md space-y-6">
        {step === 0 ? (
          <>
            <div className="mx-auto w-fit animate-pulse">
              <PawIcon size={72} />
            </div>
            <h1 className="text-2xl font-semibold text-slate-900 dark:text-white">
              Welcome to PetNote! 🐾
            </h1>
            <p className="text-sm text-slate-500 dark:text-slate-300">
              The best place to share your pet&apos;s life.
            </p>
            <button
              type="button"
              onClick={handleNext}
              className="w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-6 py-3 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110"
            >
              Next
            </button>
          </>
        ) : null}

        {step === 1 ? (
          <>
            <h1 className="text-2xl font-semibold text-slate-900 dark:text-white">
              Choose your username
            </h1>
            <p className="text-sm text-slate-500 dark:text-slate-300">
              This is how other pet lovers will find you.
            </p>

            <div className="space-y-2 rounded-2xl border border-slate-200 bg-slate-50 p-4 dark:border-slate-700 dark:bg-slate-800">
              <p className="text-xs uppercase tracking-wide text-slate-400 dark:text-slate-500">
                Current username
              </p>
              <p className="text-lg font-semibold text-slate-900 dark:text-white">
                @{initialUsername || normalizedUsername || "PetNoteUser"}
              </p>
            </div>

            <div className="rounded-2xl border border-slate-200 bg-white px-4 py-3 dark:border-slate-700 dark:bg-slate-800">
              <label className="mb-2 block text-left text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
                Username
              </label>
              <div className="flex items-center gap-3">
                <span className="text-xl text-slate-400">@</span>
                <input
                  type="text"
                  value={username}
                  onChange={(event) => setUsername(event.target.value)}
                  placeholder={initialUsername || "HappyPanda42"}
                  maxLength={30}
                  className="w-full bg-transparent text-xl text-slate-900 outline-none placeholder:text-slate-400 dark:text-white dark:placeholder:text-slate-500"
                />
                {normalizedUsername ? (
                  usernameChecking ? (
                    <span className="h-5 w-5 animate-spin rounded-full border-2 border-slate-300 border-t-purple-500" />
                  ) : canContinueUsername ? (
                    <span className="text-green-500">✓</span>
                  ) : (
                    <span className="text-red-500">✕</span>
                  )
                ) : null}
              </div>
            </div>

            <div className="space-y-1 text-left text-xs text-slate-500 dark:text-slate-400">
              <p>2-30 characters</p>
              <p>Letters, numbers, and spaces are fine</p>
              <p>Must be unique</p>
            </div>

            {normalizedUsername && !usernameValidation.valid ? (
              <p className="text-sm text-red-500">{usernameValidation.error}</p>
            ) : null}
            {normalizedUsername &&
            usernameValidation.valid &&
            usernameTaken &&
            !usernameChecking ? (
              <p className="text-sm text-red-500">This username is taken</p>
            ) : null}
            {normalizedUsername &&
            usernameValidation.valid &&
            !usernameTaken &&
            !usernameChecking ? (
              <p className="text-sm text-green-500">Username available</p>
            ) : null}

            <div className="flex items-center justify-between">
              <button
                type="button"
                onClick={handleNext}
                className="text-xs font-semibold text-slate-500 transition hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200"
              >
                Skip
              </button>
              <button
                type="button"
                onClick={handleContinueUsername}
                disabled={!canContinueUsername}
                className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-5 py-2 text-xs font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
              >
                {savingUsername ? "Saving..." : "Continue"}
              </button>
            </div>
          </>
        ) : null}

        {step === 2 ? (
          <>
            <h1 className="text-2xl font-semibold text-slate-900 dark:text-white">
              Let&apos;s meet your pet!
            </h1>

            {!showInviteJoin ? (
              <div className="space-y-3">
                <input
                  type="text"
                  placeholder="Pet name"
                  value={petName}
                  onChange={(event) => setPetName(event.target.value)}
                  className="w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-700 dark:text-white"
                />
                <div className="flex flex-wrap justify-center gap-3">
                  {PET_SPECIES.slice(0, 6).map((item) => (
                    <button
                      key={item.value}
                      type="button"
                      onClick={() => setSpecies(item.value)}
                      className={`flex h-20 w-20 items-center justify-center rounded-2xl border text-3xl transition-all duration-200 ${
                        species === item.value
                          ? "border-purple-400 bg-purple-50 scale-105"
                          : "border-slate-200 bg-white dark:border-slate-700 dark:bg-slate-800"
                      }`}
                    >
                      {item.emoji}
                    </button>
                  ))}
                </div>

                <div className="grid grid-cols-3 gap-2 text-left">
                  {PET_FAMILY_RELATIONSHIP_OPTIONS.map((item) => {
                    const active = relationship === item.value;
                    return (
                      <button
                        key={item.value}
                        type="button"
                        onClick={() => setRelationship(item.value)}
                        className={`rounded-xl border px-2 py-2 text-center text-xs font-semibold transition-all duration-200 ${
                          active
                            ? "border-purple-400 bg-purple-50 text-purple-700 dark:border-purple-400 dark:bg-purple-500/10"
                            : "border-slate-200 text-slate-600 dark:border-slate-700 dark:text-slate-300"
                        }`}
                      >
                        <span className="block text-base leading-none">{item.emoji}</span>
                        <span className="mt-1 block truncate">{item.label}</span>
                      </button>
                    );
                  })}
                </div>

                {relationship === "other" ? (
                  <input
                    type="text"
                    value={customRelationship}
                    maxLength={30}
                    placeholder="Enter relationship"
                    onChange={(event) => setCustomRelationship(event.target.value)}
                    className="w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-700 dark:text-white"
                  />
                ) : null}

                <div className="flex items-center justify-center gap-3">
                  <label className="cursor-pointer rounded-full border border-slate-200 px-4 py-2 text-xs font-semibold text-slate-600 transition-all duration-200 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-300">
                    Upload Photo
                    <input
                      type="file"
                      accept="image/*"
                      className="hidden"
                      onChange={(event) => {
                        const file = event.target.files?.[0];
                        if (!file) return;
                        setAvatarFile(file);
                        const url = URL.createObjectURL(file);
                        setAvatarPreview(url);
                      }}
                    />
                  </label>
                  {avatarPreview ? (
                    <img
                      src={avatarPreview}
                      alt="Pet"
                      className="h-12 w-12 rounded-full object-cover"
                    />
                  ) : null}
                </div>

                <button
                  type="button"
                  onClick={() => {
                    setShowInviteJoin(true);
                    setPendingInvite(null);
                    setInviteCode("");
                  }}
                  className="w-full text-xs font-semibold text-purple-600 transition-all duration-200 hover:text-purple-500"
                >
                  Already have a pet on PetNote? Enter invitation code
                </button>
              </div>
            ) : (
              <div className="space-y-3">
                <p className="text-xs text-slate-500 dark:text-slate-300">
                  Enter an invitation code to join an existing pet profile.
                </p>
                <input
                  type="text"
                  value={formatInviteCode(inviteCode)}
                  onChange={(event) => {
                    setInviteCode(normalizeInviteCode(event.target.value));
                    setPendingInvite(null);
                  }}
                  maxLength={9}
                  placeholder="XXXX XXXX"
                  className="w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-center font-mono text-xl tracking-[0.24em] text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-700 dark:text-white"
                />
                <button
                  type="button"
                  onClick={handleValidateInvitation}
                  disabled={validatingInvite}
                  className="w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-5 py-2 text-xs font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
                >
                  {validatingInvite ? "Confirming code..." : "Validate Code"}
                </button>
                {validatingInvite ? (
                  <p className="text-center text-[11px] text-slate-400 dark:text-slate-500">
                    This can take a moment for a brand-new invite.
                  </p>
                ) : null}

                {pendingInvite ? (
                  <div className="space-y-3 rounded-2xl border border-slate-200 bg-slate-50 p-3 text-left dark:border-slate-700 dark:bg-slate-800">
                    <p className="text-xs font-semibold text-slate-700 dark:text-slate-200">
                      Invitation accepted for {pendingInvite.petName}
                    </p>
                    <div className="grid grid-cols-3 gap-2">
                      {PET_FAMILY_RELATIONSHIP_OPTIONS.map((item) => {
                        const active = joinRelationship === item.value;
                        return (
                          <button
                            key={item.value}
                            type="button"
                            onClick={() => setJoinRelationship(item.value)}
                            className={`rounded-xl border px-2 py-2 text-center text-xs font-semibold transition-all duration-200 ${
                              active
                                ? "border-purple-400 bg-purple-50 text-purple-700 dark:border-purple-400 dark:bg-purple-500/10"
                                : "border-slate-200 text-slate-600 dark:border-slate-700 dark:text-slate-300"
                            }`}
                          >
                            <span className="block text-base leading-none">{item.emoji}</span>
                            <span className="mt-1 block truncate">{item.label}</span>
                          </button>
                        );
                      })}
                    </div>
                    {joinRelationship === "other" ? (
                      <input
                        type="text"
                        value={joinCustomRelationship}
                        maxLength={30}
                        placeholder="Enter relationship"
                        onChange={(event) =>
                          setJoinCustomRelationship(event.target.value)
                        }
                        className="w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-2 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-700 dark:text-white"
                      />
                    ) : null}
                    <button
                      type="button"
                      onClick={handleJoinExistingPet}
                      disabled={!joinRelationship || joiningFamily}
                      className="w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-5 py-2 text-xs font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
                    >
                      {joiningFamily ? "Joining..." : "Confirm Join"}
                    </button>
                  </div>
                ) : null}

                <button
                  type="button"
                  onClick={() => setShowInviteJoin(false)}
                  className="text-xs text-slate-400 dark:text-slate-500"
                >
                  Back to adding a new pet
                </button>
              </div>
            )}

            <div className="flex items-center justify-between">
              <button
                type="button"
                onClick={handleNext}
                className="text-xs text-slate-400 dark:text-slate-500"
              >
                Skip
              </button>
              {!showInviteJoin ? (
                <button
                  type="button"
                  onClick={handleAddPet}
                  disabled={savingPet}
                  className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-5 py-2 text-xs font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
                >
                  {savingPet ? "Adding..." : "Add Pet"}
                </button>
              ) : (
                <div className="w-[92px]" />
              )}
            </div>
          </>
        ) : null}

        {step === 3 ? (
          <>
            <h1 className="text-2xl font-semibold text-slate-900 dark:text-white">
              Share Your Pet&apos;s Moments!
            </h1>
            <div className="mx-auto flex h-32 w-32 items-center justify-center rounded-3xl bg-slate-100 text-4xl dark:bg-slate-800">
              📸
            </div>
            <p className="text-sm text-slate-500 dark:text-slate-300">
              You&apos;re all set! Start sharing photos and videos of your pet
              anytime from the home screen.
            </p>
            <button
              type="button"
              onClick={handleNext}
              className="w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-6 py-3 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110"
            >
              Let&apos;s Go! 🐾
            </button>
          </>
        ) : null}

        {step === 4 ? (
          <>
            <h1 className="text-2xl font-semibold text-slate-900 dark:text-white">
              Find your community!
            </h1>
            <p className="text-sm text-slate-500 dark:text-slate-300">
              Follow a few pets to personalize your feed.
            </p>
            <div className="space-y-3">
              {suggestedLoading ? (
                <div className="rounded-2xl border border-slate-200 bg-white px-4 py-6 text-sm text-slate-400 dark:border-slate-700 dark:bg-slate-800 dark:text-slate-500">
                  Loading suggestions...
                </div>
              ) : suggestedPets.length === 0 ? (
                <div className="rounded-2xl border border-slate-200 bg-white px-4 py-6 text-sm text-slate-500 dark:border-slate-700 dark:bg-slate-800 dark:text-slate-300">
                  <p>No pets available yet. You&apos;re one of the first! 🎉</p>
                  <p className="mt-2 text-xs text-slate-400">
                    Invite your friends to join PetNote.
                  </p>
                </div>
              ) : (
                suggestedPets.map((item) => (
                  <div
                    key={item.id}
                    className="flex items-center justify-between rounded-2xl border border-slate-200 bg-white px-4 py-3 dark:border-slate-700 dark:bg-slate-800"
                  >
                    <div className="flex items-center gap-3">
                      <Avatar
                        src={item.avatarUrl}
                        alt={item.name || "Pet"}
                        userId={item.id}
                        size={40}
                        className="h-10 w-10"
                      />
                      <div>
                        <p className="text-sm font-semibold text-slate-900 dark:text-white">
                          {item.name || "Pet"}
                        </p>
                        {item.breed ? (
                          <p className="text-xs text-slate-400">
                            {item.breed}
                          </p>
                        ) : null}
                      </div>
                    </div>
                    <button
                      type="button"
                      onClick={() => handleFollow(item.id)}
                      className={`rounded-full border px-3 py-1.5 text-xs font-semibold transition-all duration-200 ${
                        followedIds.has(item.id)
                          ? "border-slate-200 text-slate-400 dark:border-slate-700"
                          : "border-slate-200 text-slate-600 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-300"
                      }`}
                    >
                      {followedIds.has(item.id) ? "Following" : "Follow"}
                    </button>
                  </div>
                ))
              )}
            </div>
            <button
              type="button"
              onClick={handleFinish}
              className="w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-6 py-3 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110"
            >
              Start Exploring
            </button>
          </>
        ) : null}
      </div>

      <div className="flex items-center gap-2">{dots}</div>
    </div>
  );
}
