import { doc, getDoc, onSnapshot, setDoc } from "firebase/firestore";
import { db } from "./firebase";

export type AdminState = {
  role?: "admin" | "user";
  banned?: boolean;
  bannedReason?: string;
  bannedAt?: unknown;
};

function getAdminStateRef(userId: string) {
  return doc(db, "users", userId, "admin", "state");
}

export async function getAdminState(userId: string): Promise<AdminState | null> {
  const snapshot = await getDoc(getAdminStateRef(userId));
  if (!snapshot.exists()) {
    return null;
  }
  return snapshot.data() as AdminState;
}

export function subscribeAdminState(
  userId: string,
  callback: (state: AdminState | null) => void
): () => void {
  return onSnapshot(
    getAdminStateRef(userId),
    (snapshot) => {
      callback(snapshot.exists() ? (snapshot.data() as AdminState) : null);
    },
    (error) => {
      console.warn("Failed to subscribe to admin state:", error);
      callback(null);
    }
  );
}

export async function setAdminState(
  userId: string,
  data: Record<string, unknown>
): Promise<void> {
  await setDoc(getAdminStateRef(userId), data, { merge: true });
}
