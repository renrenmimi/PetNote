import { useEffect, useMemo, useRef, useState } from "react";
import PawIcon from "./PawIcon";
import Avatar from "./Avatar";
import { doc, getDoc, serverTimestamp } from "firebase/firestore";
import { auth, db } from "../services/firebase";
import { uploadImage } from "../services/cloudinary";
import { createPet } from "../services/pets";
import { completeOnboarding, createUserProfile, type UserProfile } from "../services/users";
import { PET_SPECIES, type PetSpecies } from "../utils/petHelpers";
import { generateRandomUsername } from "../utils/randomName";
import { useToast } from "../contexts/ToastContext";
import { getSuggestedUsers } from "../services/explore";
import { followUser } from "../services/follow";

type OnboardingFlowProps = {
  userId: string;
  onComplete: () => void;
};

const stepCount = 4;

export function OnboardingFlow({ userId, onComplete }: OnboardingFlowProps) {
  const [step, setStep] = useState(() => {
    if (typeof window === "undefined") return 0;
    const saved = window.localStorage.getItem("onboardingStep");
    const value = saved ? Number(saved) : 0;
    return Number.isFinite(value) ? Math.max(0, Math.min(value, 3)) : 0;
  });
  const [petName, setPetName] = useState("");
  const [species, setSpecies] = useState<PetSpecies | null>(null);
  const [avatarFile, setAvatarFile] = useState<File | null>(null);
  const [avatarPreview, setAvatarPreview] = useState<string | null>(null);
  const [savingPet, setSavingPet] = useState(false);
  const [suggestedUsers, setSuggestedUsers] = useState<UserProfile[]>([]);
  const [suggestedLoading, setSuggestedLoading] = useState(false);
  const [followedIds, setFollowedIds] = useState<Set<string>>(new Set());
  const touchStartRef = useRef(0);
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
    if (!userId) return;
    const loadSuggested = async () => {
      setSuggestedLoading(true);
      try {
        const users = await getSuggestedUsers(userId, 8);
        if (!ignore) setSuggestedUsers(users);
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

  const handleNext = () => setStep((prev) => Math.min(prev + 1, 3));
  const handleBack = () => setStep((prev) => Math.max(prev - 1, 0));

  const handleFinish = async () => {
    await completeOnboarding(userId);
    localStorage.removeItem("onboardingStep");
    onComplete();
  };

  const handleAddPet = async () => {
    if (!petName.trim() || !species) {
      showToast("Please add a pet name and species.", "warning");
      return;
    }
    setSavingPet(true);
    try {
      const currentUser = auth.currentUser;
      if (!currentUser) {
        showToast("Please log in to add a pet.", "error");
        setSavingPet(false);
        return;
      }
      const userRef = doc(db, "users", currentUser.uid);
      const snapshot = await getDoc(userRef);
      if (!snapshot.exists()) {
        const displayName = currentUser.displayName || generateRandomUsername();
        const avatarUrl =
          currentUser.photoURL ||
          `https://api.dicebear.com/7.x/thumbs/svg?seed=${currentUser.uid}`;
        await createUserProfile(currentUser.uid, {
          displayName,
          avatarUrl,
          bio: "",
          email: currentUser.email || "",
          followerCount: 0,
          followingCount: 0,
          onboardingComplete: false,
          createdAt: serverTimestamp(),
        });
        await new Promise((resolve) => setTimeout(resolve, 500));
      }
      let avatarUrl = "";
      if (avatarFile) {
        avatarUrl = await uploadImage(avatarFile);
      }
      await createPet(currentUser.uid, {
        name: petName.trim(),
        species,
        breed: "",
        gender: "unknown",
        bio: "",
        avatarUrl,
      });
      setSavingPet(false);
      handleNext();
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to add pet.";
      showToast(message, "error");
      setSavingPet(false);
    }
  };

  const handleFollow = async (targetId: string) => {
    if (!userId || followedIds.has(targetId)) return;
    try {
      await followUser(userId, targetId);
      setFollowedIds((prev) => new Set(prev).add(targetId));
      showToast("Now following!", "success");
    } catch (error) {
      console.error("Failed to follow user:", error);
      showToast("Unable to follow right now.", "error");
    }
  };

  return (
    <div
      className="fixed inset-0 z-50 flex flex-col items-center justify-between bg-white px-6 py-10 text-center dark:bg-slate-900"
      onTouchStart={(event) => {
        touchStartRef.current = event.touches[0].clientX;
      }}
      onTouchEnd={(event) => {
        const delta = event.changedTouches[0].clientX - touchStartRef.current;
        if (Math.abs(delta) < 50) return;
        if (delta < 0) {
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
              Let&apos;s meet your pet!
            </h1>
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
            </div>
            <div className="flex items-center justify-between">
                <button
                  type="button"
                  onClick={handleNext}
                  className="text-xs text-slate-400 dark:text-slate-500"
                >
                  Skip
                </button>
              <button
                type="button"
                onClick={handleAddPet}
                disabled={savingPet}
                className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-5 py-2 text-xs font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
              >
                {savingPet ? "Adding..." : "Add Pet"}
              </button>
            </div>
          </>
        ) : null}

        {step === 2 ? (
          <>
            <h1 className="text-2xl font-semibold text-slate-900 dark:text-white">
              Share Your Pet&apos;s Moments!
            </h1>
            <div className="mx-auto flex h-32 w-32 items-center justify-center rounded-3xl bg-slate-100 text-4xl dark:bg-slate-800">
              📸
            </div>
            <p className="text-sm text-slate-500 dark:text-slate-300">
              You&apos;re all set! Start sharing photos and videos of your pet anytime from the home screen.
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

        {step === 3 ? (
          <>
            <h1 className="text-2xl font-semibold text-slate-900 dark:text-white">
              Find your community!
            </h1>
            <p className="text-sm text-slate-500 dark:text-slate-300">
              Follow a few pet lovers to start.
            </p>
            <div className="space-y-3">
              {suggestedLoading ? (
                <div className="rounded-2xl border border-slate-200 bg-white px-4 py-6 text-sm text-slate-400 dark:border-slate-700 dark:bg-slate-800 dark:text-slate-500">
                  Loading suggestions...
                </div>
              ) : suggestedUsers.length === 0 ? (
                <div className="rounded-2xl border border-slate-200 bg-white px-4 py-6 text-sm text-slate-500 dark:border-slate-700 dark:bg-slate-800 dark:text-slate-300">
                  <p>No other users yet. You&apos;re one of the first! 🎉</p>
                  <p className="mt-2 text-xs text-slate-400">Invite your friends to join PetNote.</p>
                </div>
              ) : (
                suggestedUsers.map((item) => (
                  <div
                    key={item.id}
                    className="flex items-center justify-between rounded-2xl border border-slate-200 bg-white px-4 py-3 dark:border-slate-700 dark:bg-slate-800"
                  >
                    <div className="flex items-center gap-3">
                      <Avatar
                        src={item.avatarUrl}
                        alt={item.displayName || "User"}
                        userId={item.id}
                        size={40}
                        className="h-10 w-10"
                      />
                      <div>
                        <p className="text-sm font-semibold text-slate-900 dark:text-white">
                          {item.displayName || "PetNote User"}
                        </p>
                        {item.bio ? (
                          <p className="text-xs text-slate-400">
                            {item.bio.slice(0, 50)}
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
