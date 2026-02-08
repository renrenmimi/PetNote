import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  EmailAuthProvider,
  reauthenticateWithCredential,
  updatePassword,
} from "firebase/auth";
import { useAuth } from "../hooks/useAuth";
import { useTheme } from "../contexts/ThemeContext";
import { useToast } from "../contexts/ToastContext";
import { PasswordStrengthIndicator } from "../components/PasswordStrengthIndicator";
import { validatePassword } from "../utils/passwordValidator";
import { clearUserLocation, getCityFromCoords, saveUserLocation } from "../services/location";
import {
  deleteAccount,
  getSettings,
  updateSettings,
  type UserSettings,
} from "../services/settings";

const defaultSettings: UserSettings = {
  likeNotifications: true,
  commentNotifications: true,
  followNotifications: true,
  privateAccount: false,
};

function Toggle({
  enabled,
  onToggle,
  disabled,
}: {
  enabled: boolean;
  onToggle: () => void;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      onClick={onToggle}
      disabled={disabled}
      className={`relative h-6 w-11 rounded-full transition-all duration-200 ${
        enabled
          ? "bg-gradient-to-r from-purple-500 to-pink-500"
          : "bg-slate-200 dark:bg-slate-700"
      } ${disabled ? "opacity-60" : ""}`}
    >
      <span
        className={`absolute top-0.5 h-5 w-5 rounded-full bg-white transition-all duration-200 ${
          enabled ? "left-5" : "left-0.5"
        }`}
      />
    </button>
  );
}

export function Settings() {
  const navigate = useNavigate();
  const { user, profile } = useAuth();
  const { isDark, mode, setMode } = useTheme();
  const { showToast } = useToast();
  const [settings, setSettings] = useState<UserSettings>(defaultSettings);
  const [loading, setLoading] = useState(true);
  const [expandedPassword, setExpandedPassword] = useState(false);
  const [currentPassword, setCurrentPassword] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [savingPassword, setSavingPassword] = useState(false);
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [deleteInput, setDeleteInput] = useState("");
  const [deleting, setDeleting] = useState(false);
  const [locationLoading, setLocationLoading] = useState(false);

  const locationLabel = useMemo(() => {
    if (!profile?.location) return "Not set";
    const { city, state } = profile.location;
    return state ? `${city}, ${state}` : city;
  }, [profile?.location]);

  const passwordValidation = useMemo(
    () => validatePassword(newPassword),
    [newPassword]
  );
  const passwordsMatch = newPassword === confirmPassword;

  useEffect(() => {
    let ignore = false;
    if (!user) return;
    const load = async () => {
      setLoading(true);
      const data = await getSettings(user.uid);
      if (!ignore) {
        setSettings(data);
        setLoading(false);
      }
    };
    void load();
    return () => {
      ignore = true;
    };
  }, [user]);

  if (!user) return null;

  const handleSettingsUpdate = async (patch: Partial<UserSettings>) => {
    const next = { ...settings, ...patch };
    setSettings(next);
    await updateSettings(user.uid, patch);
    showToast("Settings saved", "success");
  };

  const handlePasswordSave = async () => {
    if (!user?.email) return;
    if (newPassword !== confirmPassword) {
      showToast("Passwords don't match", "error");
      return;
    }
    if (!currentPassword || !newPassword) {
      showToast("Please fill all password fields.", "error");
      return;
    }
    if (!passwordValidation.isValid) {
      showToast("Password does not meet requirements.", "error");
      return;
    }
    setSavingPassword(true);
    try {
      const credential = EmailAuthProvider.credential(
        user.email,
        currentPassword
      );
      await reauthenticateWithCredential(user, credential);
      await updatePassword(user, newPassword);
      showToast("Password updated", "success");
      setCurrentPassword("");
      setNewPassword("");
      setConfirmPassword("");
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to update password";
      showToast(message, "error");
    } finally {
      setSavingPassword(false);
    }
  };

  const handleDeleteAccount = async () => {
    if (!user) return;
    if (deleteInput !== "DELETE") {
      showToast("Please type DELETE to confirm.", "warning");
      return;
    }
    setDeleting(true);
    try {
      await deleteAccount(user.uid);
      navigate("/login", { replace: true });
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to delete account.";
      showToast(message, "error");
    } finally {
      setDeleting(false);
    }
  };

  const handleUpdateLocation = async () => {
    if (!user || locationLoading) return;
    setLocationLoading(true);
    showToast("PetNote needs your location to show nearby meetups.", "info");
    try {
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
      const lat = latitude;
      const lng = longitude;
      const { city, state } = await getCityFromCoords(lat, lng);
      await saveUserLocation(user.uid, { lat, lng, city, state });
      showToast("Location updated", "success");
    } catch (err) {
      const error = err as { code?: number; message?: string };
      if (error?.code === 1) {
        showToast(
          "Location access denied. Please enable location in your browser settings.",
          "error"
        );
      } else if (error?.code === 3 || error?.message === "timeout") {
        showToast("Location request timed out. Please try again.", "error");
      } else {
        const message =
          err instanceof Error ? err.message : "Failed to update location.";
        showToast(message, "error");
      }
    } finally {
      setLocationLoading(false);
    }
  };

  const handleClearLocation = async () => {
    if (!user || locationLoading) return;
    setLocationLoading(true);
    try {
      await clearUserLocation(user.uid);
      showToast("Location cleared", "info");
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to clear location.";
      showToast(message, "error");
    } finally {
      setLocationLoading(false);
    }
  };

  const systemEnabled = mode === "system";

  return (
    <div className="min-h-screen bg-white pb-16 dark:bg-slate-900">
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
            Settings
          </h1>
          <div className="w-6" />
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-6 px-4 py-6">
        {loading ? (
          <div className="rounded-2xl bg-slate-50 p-6 text-center text-sm text-slate-500 dark:bg-slate-800 dark:text-slate-300">
            Loading settings...
          </div>
        ) : null}

        <section className="space-y-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-slate-400 dark:text-slate-500">
            Account
          </p>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 dark:border-slate-700 dark:bg-slate-800">
            <button
              type="button"
              onClick={() => setExpandedPassword((prev) => !prev)}
              className="flex w-full items-center justify-between text-sm font-semibold text-slate-900 dark:text-white"
            >
              Change Password
              <span className="text-slate-400 dark:text-slate-500">
                {expandedPassword ? "−" : "+"}
              </span>
            </button>
            {expandedPassword ? (
              <div className="mt-4 space-y-3">
                <input
                  type="password"
                  placeholder="Current password"
                  value={currentPassword}
                  onChange={(event) => setCurrentPassword(event.target.value)}
                  className="w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-700 dark:text-white"
                  maxLength={64}
                />
                <input
                  type="password"
                  placeholder="New password"
                  value={newPassword}
                  onChange={(event) => setNewPassword(event.target.value)}
                  className="w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-700 dark:text-white"
                  maxLength={64}
                />
                <PasswordStrengthIndicator password={newPassword} />
                <input
                  type="password"
                  placeholder="Confirm new password"
                  value={confirmPassword}
                  onChange={(event) => setConfirmPassword(event.target.value)}
                  className="w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-700 dark:text-white"
                  maxLength={64}
                />
                <button
                  type="button"
                  onClick={handlePasswordSave}
                  disabled={
                    savingPassword ||
                    !currentPassword ||
                    !newPassword ||
                    !passwordValidation.isValid ||
                    !passwordsMatch
                  }
                  className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-xs font-semibold text-white transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
                >
                  {savingPassword ? "Saving..." : "Save"}
                </button>
              </div>
            ) : null}
          </div>

          <div className="rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-600 dark:border-slate-700 dark:bg-slate-800 dark:text-slate-300">
            Email
            <p className="mt-1 text-xs text-slate-400 dark:text-slate-500">
              {user.email}
            </p>
          </div>
        </section>

        <section className="space-y-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-slate-400 dark:text-slate-500">
            Appearance
          </p>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 dark:border-slate-700 dark:bg-slate-800">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-sm font-semibold text-slate-900 dark:text-white">
                  Dark Mode
                </p>
                <p className="text-xs text-slate-400 dark:text-slate-500">
                  Toggle dark theme
                </p>
              </div>
              <Toggle
                enabled={isDark}
                onToggle={() => {
                  if (systemEnabled) {
                    setMode(isDark ? "light" : "dark");
                  } else {
                    setMode(isDark ? "light" : "dark");
                  }
                }}
              />
            </div>
            <div className="mt-4 flex items-center justify-between border-t border-slate-200 pt-3 text-sm dark:border-slate-700">
              <div>
                <p className="text-sm font-semibold text-slate-900 dark:text-white">
                  Use System Setting
                </p>
                <p className="text-xs text-slate-400 dark:text-slate-500">
                  Follow your device theme
                </p>
              </div>
              <Toggle
                enabled={systemEnabled}
                onToggle={() => {
                  if (systemEnabled) {
                    setMode(isDark ? "dark" : "light");
                  } else {
                    setMode("system");
                  }
                }}
              />
            </div>
          </div>
        </section>

        <section className="space-y-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-slate-400 dark:text-slate-500">
            Notifications
          </p>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 dark:border-slate-700 dark:bg-slate-800">
            <div className="flex items-center justify-between py-2">
              <span className="text-sm text-slate-700 dark:text-slate-200">
                Like Notifications
              </span>
              <Toggle
                enabled={settings.likeNotifications}
                onToggle={() =>
                  handleSettingsUpdate({
                    likeNotifications: !settings.likeNotifications,
                  })
                }
              />
            </div>
            <div className="flex items-center justify-between border-t border-slate-200 py-2 dark:border-slate-700">
              <span className="text-sm text-slate-700 dark:text-slate-200">
                Comment Notifications
              </span>
              <Toggle
                enabled={settings.commentNotifications}
                onToggle={() =>
                  handleSettingsUpdate({
                    commentNotifications: !settings.commentNotifications,
                  })
                }
              />
            </div>
            <div className="flex items-center justify-between border-t border-slate-200 py-2 dark:border-slate-700">
              <span className="text-sm text-slate-700 dark:text-slate-200">
                Follow Notifications
              </span>
              <Toggle
                enabled={settings.followNotifications}
                onToggle={() =>
                  handleSettingsUpdate({
                    followNotifications: !settings.followNotifications,
                  })
                }
              />
            </div>
          </div>
        </section>

        <section className="space-y-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-slate-400 dark:text-slate-500">
            Privacy
          </p>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 dark:border-slate-700 dark:bg-slate-800">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-sm font-semibold text-slate-900 dark:text-white">
                  Private Account
                </p>
                <p className="text-xs text-slate-400 dark:text-slate-500">
                  Followers require approval (UI only)
                </p>
              </div>
              <Toggle
                enabled={settings.privateAccount}
                onToggle={() =>
                  handleSettingsUpdate({
                    privateAccount: !settings.privateAccount,
                  })
                }
              />
            </div>
            <div className="mt-4 rounded-xl border border-slate-200 bg-slate-50 px-3 py-3 text-sm text-slate-600 dark:border-slate-700 dark:bg-slate-900/40 dark:text-slate-300">
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-sm font-semibold text-slate-900 dark:text-white">
                    My Location
                  </p>
                  <p className="text-xs text-slate-400 dark:text-slate-500">
                    {locationLabel}
                  </p>
                </div>
                <button
                  type="button"
                  onClick={handleUpdateLocation}
                  disabled={locationLoading}
                  className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-3 py-1.5 text-xs font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-70"
                >
                  {locationLoading ? "Updating..." : "Update Location"}
                </button>
              </div>
              <div className="mt-2 flex items-center justify-between text-xs text-slate-400 dark:text-slate-500">
                <span>
                  Your location is used to show distance to meetups. Only your
                  city is visible to others.
                </span>
                {profile?.location ? (
                  <button
                    type="button"
                    onClick={handleClearLocation}
                    disabled={locationLoading}
                    className="ml-3 text-red-500 hover:text-red-600"
                  >
                    Clear
                  </button>
                ) : null}
              </div>
            </div>
            <button
              type="button"
              onClick={() => navigate("/blocked-users")}
              className="mt-4 w-full rounded-xl border border-slate-200 px-3 py-2 text-left text-sm text-slate-700 transition-all duration-200 hover:bg-slate-50 dark:border-slate-700 dark:text-slate-200 dark:hover:bg-slate-700"
            >
              Blocked Users
            </button>
          </div>
        </section>

        <section className="space-y-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-red-400">
            Danger Zone
          </p>
          <div className="rounded-2xl border border-red-200 bg-white p-4 dark:border-red-500/40 dark:bg-slate-800">
            <button
              type="button"
              onClick={() => setDeleteOpen(true)}
              className="text-sm font-semibold text-red-500"
            >
              Delete Account
            </button>
          </div>
        </section>

        <section className="space-y-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-slate-400 dark:text-slate-500">
            About
          </p>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-600 dark:border-slate-700 dark:bg-slate-800 dark:text-slate-300">
            <p>Version 1.0.0</p>
            <button
              type="button"
              onClick={() => navigate("/contact")}
              className="mt-3 w-full rounded-xl border border-slate-200 px-3 py-2 text-left text-xs font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-50 dark:border-slate-700 dark:text-slate-200 dark:hover:bg-slate-700"
            >
              Contact Us / Feedback
            </button>
            <p className="mt-2 text-xs text-slate-400 dark:text-slate-500">
              Contact: support@petnote.app
            </p>
            <p className="mt-2 text-xs text-slate-400 dark:text-slate-500">
              Terms of Service
            </p>
            <p className="mt-1 text-xs text-slate-400 dark:text-slate-500">
              Privacy Policy
            </p>
            <p className="mt-3 text-xs text-slate-500 dark:text-slate-400">
              Made with ❤️ and 🐾
            </p>
          </div>
        </section>
      </main>

      {deleteOpen ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-sm rounded-2xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)] dark:bg-slate-800">
            <h3 className="text-base font-semibold text-slate-900 dark:text-white">
              Delete Account
            </h3>
            <p className="mt-2 text-sm text-slate-600 dark:text-slate-300">
              Type DELETE to confirm. This action cannot be undone.
            </p>
            <input
              type="text"
              value={deleteInput}
              onChange={(event) => setDeleteInput(event.target.value)}
              className="mt-4 w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 outline-none transition focus:border-red-400 focus:ring-2 focus:ring-red-200 dark:border-slate-700 dark:bg-slate-700 dark:text-white"
            />
            <div className="mt-4 flex items-center justify-end gap-2">
              <button
                type="button"
                onClick={() => setDeleteOpen(false)}
                className="rounded-full px-4 py-2 text-sm font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={handleDeleteAccount}
                disabled={deleting}
                className="rounded-full bg-red-500 px-4 py-2 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
              >
                {deleting ? "Deleting..." : "Delete"}
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
