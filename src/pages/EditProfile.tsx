import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { uploadImage } from "../services/cloudinary";
import {
  getUserProfile,
  isUsernameTaken,
  updateUserProfile,
} from "../services/users";
import { useToast } from "../contexts/ToastContext";
import Avatar from "../components/Avatar";

const MAX_BIO = 150;
const MAX_NAME = 30;

export function EditProfile() {
  const navigate = useNavigate();
  const { user } = useAuth();
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [displayName, setDisplayName] = useState("");
  const [initialDisplayName, setInitialDisplayName] = useState("");
  const [bio, setBio] = useState("");
  const [avatarPreview, setAvatarPreview] = useState<string | null>(null);
  const [avatarFile, setAvatarFile] = useState<File | null>(null);
  const [saving, setSaving] = useState(false);
  const [usernameChecking, setUsernameChecking] = useState(false);
  const [usernameTaken, setUsernameTaken] = useState(false);
  const { showToast } = useToast();

  const bioRemaining = useMemo(() => MAX_BIO - bio.length, [bio.length]);
  const bioCounterTone =
    bioRemaining <= 0
      ? "text-red-500"
      : bioRemaining <= Math.ceil(MAX_BIO * 0.2)
      ? "text-amber-500"
      : "text-slate-400 dark:text-slate-500";

  const nameRemaining = useMemo(() => MAX_NAME - displayName.length, [
    displayName.length,
  ]);
  const nameCounterTone =
    nameRemaining <= 0
      ? "text-red-500"
      : nameRemaining <= Math.ceil(MAX_NAME * 0.2)
      ? "text-amber-500"
      : "text-slate-400 dark:text-slate-500";

  const canSave = useMemo(() => {
    const normalized = displayName.trim();
    return (
      !!user &&
      !saving &&
      normalized.length >= 2 &&
      normalized.length <= MAX_NAME &&
      !usernameTaken &&
      !usernameChecking
    );
  }, [displayName, saving, user, usernameChecking, usernameTaken]);

  useEffect(() => {
    let ignore = false;
    if (!user) return;
    const load = async () => {
      const profile = await getUserProfile(user.uid);
      if (ignore) return;
      const resolvedDisplayName = profile?.displayName || user.displayName || "";
      setDisplayName(resolvedDisplayName);
      setInitialDisplayName(resolvedDisplayName);
      setBio(profile?.bio || "");
      setAvatarPreview(
        profile?.avatarUrl ||
          user.photoURL ||
          `https://api.dicebear.com/7.x/thumbs/svg?seed=${user.uid}`
      );
    };
    void load();
    return () => {
      ignore = true;
    };
  }, [user]);

  useEffect(() => {
    if (!avatarFile) return;
    const url = URL.createObjectURL(avatarFile);
    setAvatarPreview(url);
    return () => URL.revokeObjectURL(url);
  }, [avatarFile]);

  useEffect(() => {
    let ignore = false;
    if (!user) return;

    const normalized = displayName.trim();
    if (
      normalized.length < 2 ||
      normalized.toLowerCase() === initialDisplayName.trim().toLowerCase()
    ) {
      setUsernameChecking(false);
      setUsernameTaken(false);
      return;
    }

    setUsernameChecking(true);
    const timer = window.setTimeout(async () => {
      try {
        const taken = await isUsernameTaken(normalized, user.uid);
        if (!ignore) {
          setUsernameTaken(taken);
        }
      } catch (error) {
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
  }, [displayName, initialDisplayName, user]);

  const handleSave = async () => {
    if (!user || saving) return;
    const name = displayName.trim();
    if (name.length < 2 || name.length > 30) {
      showToast("Display name must be 2-30 characters.", "error");
      return;
    }
    if (usernameTaken) {
      showToast("This username is already taken.", "error");
      return;
    }
    if (usernameChecking) {
      return;
    }

    setSaving(true);

    try {
      let avatarUrl = avatarPreview || user.photoURL || "";
      if (avatarFile) {
        avatarUrl = await uploadImage(avatarFile);
      }

      await updateUserProfile(user.uid, {
        displayName: name,
        avatarUrl,
        bio: bio.trim(),
      });

      navigate("/profile", { replace: true });
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to update profile.";
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
            Edit Profile
          </h1>
          <button
            type="button"
            onClick={handleSave}
            disabled={!canSave}
            className="flex items-center gap-2 rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-1.5 text-sm font-semibold text-white transition-all duration-200 hover:scale-105 disabled:cursor-not-allowed disabled:opacity-70"
          >
            {saving ? (
              <>
                <span className="h-4 w-4 animate-spin rounded-full border-2 border-white/70 border-t-transparent" />
                Saving...
              </>
            ) : (
              "Save"
            )}
          </button>
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-6 px-4 py-6">
        <section className="rounded-3xl bg-white p-6 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <div className="flex flex-col items-center text-center">
            <div className="relative">
              <Avatar
                src={avatarPreview || undefined}
                alt="Profile"
                userId={user?.uid}
                size={112}
                className="h-28 w-28"
              />
              <button
                type="button"
                onClick={() => fileInputRef.current?.click()}
                className="absolute inset-0 flex items-center justify-center rounded-full bg-black/40 text-white opacity-0 transition-all duration-200 hover:opacity-100"
              >
                📷
              </button>
            </div>
            <button
              type="button"
              onClick={() => fileInputRef.current?.click()}
              className="mt-3 rounded-full border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-700 transition-all duration-200 hover:scale-105 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-200"
            >
              Change Photo
            </button>
            <input
              ref={fileInputRef}
              type="file"
              accept="image/*"
              className="hidden"
              onChange={(event) =>
                setAvatarFile(event.target.files?.[0] ?? null)
              }
            />
          </div>
        </section>

        <section className="space-y-4">
          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <label className="text-sm font-semibold text-slate-700 dark:text-slate-200">
                Display Name
              </label>
              <span className={`text-xs ${nameCounterTone}`}>
                {displayName.length}/{MAX_NAME}
              </span>
            </div>
            <input
              type="text"
              value={displayName}
              onChange={(event) => setDisplayName(event.target.value)}
              maxLength={MAX_NAME}
              className="w-full rounded-xl border border-slate-200 bg-slate-50 px-4 py-2 text-sm text-slate-700 outline-none transition-all duration-200 focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
              placeholder="Enter display name"
            />
            {usernameChecking ? (
              <p className="text-xs text-slate-400 dark:text-slate-500">
                Checking username...
              </p>
            ) : usernameTaken ? (
              <p className="text-xs text-red-500">This username is already taken</p>
            ) : null}
          </div>

          <div className="space-y-2">
            <label className="text-sm font-semibold text-slate-700 dark:text-slate-200">
              Email
            </label>
            <input
              type="text"
              readOnly
              value={user?.email || ""}
              className="w-full rounded-xl border border-slate-200 bg-slate-100 px-4 py-2 text-sm text-slate-500 outline-none dark:border-slate-700 dark:bg-slate-900 dark:text-slate-400"
            />
          </div>

          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <label className="text-sm font-semibold text-slate-700 dark:text-slate-200">
                Bio
              </label>
              <span className={`text-xs ${bioCounterTone}`}>
                {bio.length}/{MAX_BIO}
              </span>
            </div>
            <textarea
              value={bio}
              onChange={(event) => setBio(event.target.value)}
              maxLength={MAX_BIO}
              rows={4}
              className="w-full rounded-xl border border-slate-200 bg-slate-50 px-4 py-2 text-sm text-slate-700 outline-none transition-all duration-200 focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
              placeholder="Tell us about your pets..."
            />
          </div>
        </section>
      </main>
    </div>
  );
}
