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
import {
  clearUserLocation,
  getCityFromCoords,
  saveUserLocation,
} from "../services/location";
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

function SectionTitle({ children }: { children: React.ReactNode }) {
  return (
    <p className="px-4 py-2 text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400">
      {children}
    </p>
  );
}

function Toggle({
  enabled,
  onChange,
  disabled,
}: {
  enabled: boolean;
  onChange: (value: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      onClick={() => onChange(!enabled)}
      disabled={disabled}
      className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${
        enabled ? "bg-purple-500" : "bg-gray-300 dark:bg-gray-600"
      } ${disabled ? "cursor-not-allowed opacity-60" : ""}`}
    >
      <span
        className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${
          enabled ? "translate-x-6" : "translate-x-1"
        }`}
      />
    </button>
  );
}

function SettingRow({
  label,
  value,
  onClick,
  rightElement,
  danger = false,
  border = true,
}: {
  label: string;
  value?: string;
  onClick?: () => void;
  rightElement?: React.ReactNode;
  danger?: boolean;
  border?: boolean;
}) {
  return (
    <div
      onClick={onClick}
      className={`flex items-center justify-between px-4 py-3.5 text-left ${
        border ? "border-b border-gray-100 dark:border-gray-800" : ""
      } ${
        onClick
          ? "cursor-pointer active:bg-gray-50 dark:active:bg-gray-800"
          : ""
      }`}
    >
      <span
        className={`text-sm ${
          danger
            ? "font-medium text-red-500"
            : "text-gray-900 dark:text-gray-100"
        }`}
      >
        {label}
      </span>
      {rightElement ? (
        rightElement
      ) : value ? (
        <span className="text-sm text-gray-500 dark:text-gray-400">{value}</span>
      ) : onClick ? (
        <span className="text-gray-400">›</span>
      ) : null}
    </div>
  );
}

export function Settings() {
  const navigate = useNavigate();
  const { user, profile, signOut } = useAuth();
  const { isDark, setMode } = useTheme();
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
  const [signOutOpen, setSignOutOpen] = useState(false);
  const [locationLoading, setLocationLoading] = useState(false);
  const [locationSheetOpen, setLocationSheetOpen] = useState(false);

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
      try {
        const data = await getSettings(user.uid);
        if (!ignore) {
          setSettings(data);
        }
      } catch {
        if (!ignore) {
          showToast("Failed to load settings.", "error");
        }
      } finally {
        if (!ignore) {
          setLoading(false);
        }
      }
    };
    void load();
    return () => {
      ignore = true;
    };
  }, [showToast, user]);

  if (!user) return null;

  const handleSettingsUpdate = async (patch: Partial<UserSettings>) => {
    const next = { ...settings, ...patch };
    setSettings(next);
    try {
      await updateSettings(user.uid, patch);
    } catch (error) {
      setSettings(settings);
      const message =
        error instanceof Error ? error.message : "Failed to save settings.";
      showToast(message, "error");
    }
  };

  const handlePasswordSave = async () => {
    if (!user.email) return;
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
      setExpandedPassword(false);
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Failed to update password";
      showToast(message, "error");
    } finally {
      setSavingPassword(false);
    }
  };

  const handleDeleteAccount = async () => {
    if (deleteInput !== "DELETE") {
      showToast("Please type DELETE to confirm.", "warning");
      return;
    }
    setDeleting(true);
    try {
      await deleteAccount(user.uid);
      navigate("/login", { replace: true });
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Failed to delete account.";
      showToast(message, "error");
    } finally {
      setDeleting(false);
    }
  };

  const handleUpdateLocation = async () => {
    if (locationLoading) return;
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
      const { city, state } = await getCityFromCoords(latitude, longitude);
      await saveUserLocation(user.uid, {
        lat: latitude,
        lng: longitude,
        city,
        state,
      });
      showToast("Location updated", "success");
    } catch (error) {
      const geolocationError = error as { code?: number; message?: string };
      if (geolocationError.code === 1) {
        showToast(
          "Location access denied. Please enable location in your browser settings.",
          "error"
        );
      } else if (
        geolocationError.code === 3 ||
        geolocationError.message === "timeout"
      ) {
        showToast("Location request timed out. Please try again.", "error");
      } else {
        const message =
          error instanceof Error ? error.message : "Failed to update location.";
        showToast(message, "error");
      }
    } finally {
      setLocationLoading(false);
    }
  };

  const handleClearLocation = async () => {
    if (locationLoading) return;
    setLocationLoading(true);
    try {
      await clearUserLocation(user.uid);
      showToast("Location cleared", "info");
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Failed to clear location.";
      showToast(message, "error");
    } finally {
      setLocationLoading(false);
    }
  };

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

      <main className="mx-auto w-full max-w-md space-y-6 px-4 py-6 text-left">
        {loading ? (
          <div className="rounded-2xl bg-slate-50 p-6 text-center text-sm text-slate-500 dark:bg-slate-800 dark:text-slate-300">
            Loading settings...
          </div>
        ) : null}

        <section>
          <SectionTitle>Account</SectionTitle>
          <div className="overflow-hidden rounded-2xl border border-gray-200 bg-white dark:border-gray-800 dark:bg-slate-900">
            <SettingRow
              label="Change Password"
              onClick={() => setExpandedPassword((prev) => !prev)}
              rightElement={
                <span className="text-gray-400">{expandedPassword ? "⌄" : "›"}</span>
              }
            />
            {expandedPassword ? (
              <div className="space-y-3 border-b border-gray-100 px-4 pb-4 dark:border-gray-800">
                <input
                  type="password"
                  placeholder="Current password"
                  value={currentPassword}
                  onChange={(event) => setCurrentPassword(event.target.value)}
                  maxLength={64}
                  className="w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
                />
                <input
                  type="password"
                  placeholder="New password"
                  value={newPassword}
                  onChange={(event) => setNewPassword(event.target.value)}
                  maxLength={64}
                  className="w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
                />
                <PasswordStrengthIndicator password={newPassword} />
                <input
                  type="password"
                  placeholder="Confirm new password"
                  value={confirmPassword}
                  onChange={(event) => setConfirmPassword(event.target.value)}
                  maxLength={64}
                  className="w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
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
            <SettingRow label="Email" value={user.email || "-"} />
            <SettingRow
              label="Sign Out"
              onClick={() => setSignOutOpen(true)}
              danger
              border={false}
            />
          </div>
        </section>

        <section>
          <SectionTitle>Appearance</SectionTitle>
          <div className="overflow-hidden rounded-2xl border border-gray-200 bg-white dark:border-gray-800 dark:bg-slate-900">
            <SettingRow
              label="Dark Mode"
              rightElement={
                <Toggle
                  enabled={isDark}
                  onChange={(nextEnabled) =>
                    setMode(nextEnabled ? "dark" : "light")
                  }
                />
              }
              border={false}
            />
          </div>
        </section>

        <section>
          <SectionTitle>Notifications</SectionTitle>
          <div className="overflow-hidden rounded-2xl border border-gray-200 bg-white dark:border-gray-800 dark:bg-slate-900">
            <SettingRow
              label="Likes"
              rightElement={
                <Toggle
                  enabled={settings.likeNotifications}
                  onChange={(nextEnabled) =>
                    void handleSettingsUpdate({ likeNotifications: nextEnabled })
                  }
                />
              }
            />
            <SettingRow
              label="Comments"
              rightElement={
                <Toggle
                  enabled={settings.commentNotifications}
                  onChange={(nextEnabled) =>
                    void handleSettingsUpdate({ commentNotifications: nextEnabled })
                  }
                />
              }
            />
            <SettingRow
              label="Follows"
              rightElement={
                <Toggle
                  enabled={settings.followNotifications}
                  onChange={(nextEnabled) =>
                    void handleSettingsUpdate({ followNotifications: nextEnabled })
                  }
                />
              }
              border={false}
            />
          </div>
        </section>

        <section>
          <SectionTitle>Privacy</SectionTitle>
          <div className="overflow-hidden rounded-2xl border border-gray-200 bg-white dark:border-gray-800 dark:bg-slate-900">
            <SettingRow
              label="My Location"
              onClick={() => setLocationSheetOpen(true)}
              rightElement={
                <div className="flex items-center gap-2">
                  <span className="text-sm text-gray-500 dark:text-gray-400">
                    {locationLabel}
                  </span>
                  <span className="text-gray-400">›</span>
                </div>
              }
            />
            <SettingRow
              label="Blocked Users"
              onClick={() => navigate("/blocked-users")}
              border={false}
            />
          </div>
        </section>

        <section>
          <SectionTitle>Danger Zone</SectionTitle>
          <div className="overflow-hidden rounded-2xl border border-red-200 bg-white dark:border-red-500/40 dark:bg-slate-900">
            <SettingRow
              label="Delete Account"
              onClick={() => setDeleteOpen(true)}
              danger
              border={false}
            />
          </div>
        </section>

        <section>
          <SectionTitle>About</SectionTitle>
          <div className="overflow-hidden rounded-2xl border border-gray-200 bg-white dark:border-gray-800 dark:bg-slate-900">
            <SettingRow
              label="Contact Us & Feedback"
              onClick={() => navigate("/contact")}
            />
            <SettingRow
              label="Terms of Service"
              onClick={() => navigate("/terms")}
            />
            <SettingRow
              label="Privacy Policy"
              onClick={() => navigate("/privacy")}
            />
            <SettingRow label="Version" value="1.0.0" border={false} />
          </div>
          <p className="mt-3 text-center text-xs text-gray-500 dark:text-gray-400">
            Made with ❤️ and 🐾
          </p>
        </section>
      </main>

      {locationSheetOpen ? (
        <div className="fixed inset-0 z-40">
          <button
            type="button"
            className="absolute inset-0 bg-black/40"
            onClick={() => setLocationSheetOpen(false)}
            aria-label="Close location sheet"
          />
          <div className="absolute bottom-0 left-0 right-0 rounded-t-3xl bg-white px-4 pb-6 pt-4 dark:bg-slate-900">
            <div className="mx-auto mb-4 h-1.5 w-12 rounded-full bg-slate-300 dark:bg-slate-700" />
            <h3 className="text-left text-base font-semibold text-slate-900 dark:text-white">
              My Location
            </h3>
            <p className="mt-1 text-left text-sm text-slate-500 dark:text-slate-400">
              Current: {locationLabel}
            </p>
            <button
              type="button"
              onClick={() => void handleUpdateLocation()}
              disabled={locationLoading}
              className="mt-4 w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:opacity-70"
            >
              {locationLoading ? "Updating..." : "Update Location"}
            </button>
            {profile?.location ? (
              <button
                type="button"
                onClick={() => void handleClearLocation()}
                disabled={locationLoading}
                className="mt-3 w-full text-sm font-medium text-slate-500 transition hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200"
              >
                Clear Location
              </button>
            ) : null}
            <p className="mt-4 text-left text-xs text-slate-400 dark:text-slate-500">
              Your location is used to show distances to meetups and places.
            </p>
          </div>
        </div>
      ) : null}

      {signOutOpen ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-sm rounded-2xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)] dark:bg-slate-800">
            <h3 className="text-base font-semibold text-slate-900 dark:text-white">
              Sign Out
            </h3>
            <p className="mt-2 text-sm text-slate-600 dark:text-slate-300">
              Are you sure you want to sign out?
            </p>
            <div className="mt-4 flex items-center justify-end gap-2">
              <button
                type="button"
                onClick={() => setSignOutOpen(false)}
                className="rounded-full px-4 py-2 text-sm font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={async () => {
                  await signOut();
                  navigate("/login", { replace: true });
                }}
                className="w-24 rounded-full bg-red-500 px-4 py-2 text-center text-sm font-semibold text-white transition-all duration-200 hover:brightness-110"
              >
                Sign Out
              </button>
            </div>
          </div>
        </div>
      ) : null}

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
