import {
  doc,
  getDoc,
  setDoc,
} from "firebase/firestore";
import { httpsCallable } from "firebase/functions";
import {
  DEFAULT_LANGUAGE,
  isAppLanguage,
  type AppLanguage,
} from "../i18n/config";
import { db, functions } from "./firebase";

export type UserSettings = {
  likeNotifications: boolean;
  commentNotifications: boolean;
  followNotifications: boolean;
  language: AppLanguage;
};

export const defaultUserSettings: UserSettings = {
  likeNotifications: true,
  commentNotifications: true,
  followNotifications: true,
  language: DEFAULT_LANGUAGE,
};

const settingsRef = (userId: string) =>
  doc(db, "users", userId, "settings", "preferences");

export async function getSettings(userId: string): Promise<UserSettings> {
  const snapshot = await getDoc(settingsRef(userId));
  if (!snapshot.exists()) {
    return defaultUserSettings;
  }
  const data = snapshot.data() as Partial<UserSettings>;
  return {
    ...defaultUserSettings,
    ...data,
    language: isAppLanguage(data.language) ? data.language : DEFAULT_LANGUAGE,
  };
}

export async function updateSettings(
  userId: string,
  settings: Partial<UserSettings>
): Promise<void> {
  await setDoc(settingsRef(userId), settings, { merge: true });
}

export async function deleteAccount(userId: string): Promise<void> {
  await httpsCallable<{ userId: string }, { success: boolean }>(
    functions,
    "deleteUserAccount"
  )({ userId });
}
