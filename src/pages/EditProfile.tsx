import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { uploadImage } from "../services/cloudinary";
import { getUserProfile, updateUserProfile } from "../services/users";

const MAX_BIO = 150;

export function EditProfile() {
  const navigate = useNavigate();
  const { user } = useAuth();
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [displayName, setDisplayName] = useState("");
  const [bio, setBio] = useState("");
  const [avatarPreview, setAvatarPreview] = useState<string | null>(null);
  const [avatarFile, setAvatarFile] = useState<File | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const remaining = useMemo(
    () => Math.max(0, MAX_BIO - bio.length),
    [bio]
  );

  useEffect(() => {
    let ignore = false;
    if (!user) return;
    const load = async () => {
      const profile = await getUserProfile(user.uid);
      if (ignore) return;
      setDisplayName(profile?.displayName || user.displayName || "");
      setBio(profile?.bio || "");
      setAvatarPreview(
        profile?.avatarUrl || user.photoURL || "https://i.pravatar.cc/150?img=12"
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

  const handleSave = async () => {
    if (!user || saving) return;
    const name = displayName.trim();
    if (name.length < 2 || name.length > 30) {
      setError("Display name must be 2-30 characters.");
      return;
    }
    setError(null);
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
      setError(message);
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="min-h-screen bg-white pb-10">
      <header className="sticky top-0 z-10 border-b border-slate-200 bg-white">
        <div className="mx-auto flex w-full max-w-md items-center justify-between px-4 py-3">
          <button
            type="button"
            onClick={() => navigate(-1)}
            className="text-xl text-slate-500 hover:text-slate-700"
            aria-label="Go back"
          >
            ←
          </button>
          <h1 className="text-base font-semibold text-slate-900">Edit Profile</h1>
          <button
            type="button"
            onClick={handleSave}
            disabled={saving}
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
        <section className="rounded-3xl bg-white p-6 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100">
          <div className="flex flex-col items-center text-center">
            <div className="relative">
              <img
                src={avatarPreview || "https://i.pravatar.cc/150?img=12"}
                alt="Profile"
                className="h-28 w-28 rounded-full object-cover"
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
              className="mt-3 rounded-full border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-700 transition-all duration-200 hover:scale-105 hover:border-purple-300 hover:text-purple-600"
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
            <label className="text-sm font-semibold text-slate-700">
              Display Name
            </label>
            <input
              type="text"
              value={displayName}
              onChange={(event) => setDisplayName(event.target.value)}
              className="w-full rounded-xl border border-slate-200 bg-slate-50 px-4 py-2 text-sm text-slate-700 outline-none transition-all duration-200 focus:border-purple-400 focus:ring-2 focus:ring-purple-200"
              placeholder="Enter display name"
            />
          </div>

          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <label className="text-sm font-semibold text-slate-700">Bio</label>
              <span
                className={`text-xs ${
                  remaining === 0 ? "text-red-500" : "text-slate-400"
                }`}
              >
                {remaining} left
              </span>
            </div>
            <textarea
              value={bio}
              onChange={(event) => setBio(event.target.value)}
              maxLength={MAX_BIO}
              rows={4}
              className="w-full rounded-xl border border-slate-200 bg-slate-50 px-4 py-2 text-sm text-slate-700 outline-none transition-all duration-200 focus:border-purple-400 focus:ring-2 focus:ring-purple-200"
              placeholder="Tell us about your pets..."
            />
          </div>

          {error ? (
            <div className="rounded-xl border border-red-200 bg-red-50 px-4 py-2 text-sm text-red-600">
              {error}
            </div>
          ) : null}
        </section>
      </main>
    </div>
  );
}
