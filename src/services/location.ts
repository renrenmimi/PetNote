import { deleteField, doc, getDoc, setDoc, updateDoc, serverTimestamp } from "firebase/firestore";
import { db } from "./firebase";

export type UserLocation = {
  lat: number;
  lng: number;
  city: string;
  state: string;
  updatedAt?: unknown;
};

export async function getCurrentLocation(): Promise<{ lat: number; lng: number }> {
  return new Promise((resolve, reject) => {
    if (!navigator.geolocation) {
      reject(new Error("Geolocation not supported"));
      return;
    }
    navigator.geolocation.getCurrentPosition(
      (pos) => resolve({ lat: pos.coords.latitude, lng: pos.coords.longitude }),
      (err) => reject(err),
      { enableHighAccuracy: false, timeout: 10000 }
    );
  });
}

export async function getCityFromCoords(
  lat: number,
  lng: number
): Promise<{ city: string; state: string }> {
  const apiKey = import.meta.env.VITE_GEOAPIFY_KEY as string | undefined;
  if (!apiKey) {
    return { city: "Unknown", state: "" };
  }
  const res = await fetch(
    `https://api.geoapify.com/v1/geocode/reverse?lat=${lat}&lon=${lng}&apiKey=${apiKey}`
  );
  const data = await res.json();
  const props = data?.features?.[0]?.properties || {};
  return {
    city: props.city || props.county || "Unknown",
    state: props.state || "",
  };
}

export function calculateDistance(
  lat1: number,
  lng1: number,
  lat2: number,
  lng2: number
): number {
  const R = 3959;
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLng = ((lng2 - lng1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos((lat1 * Math.PI) / 180) *
      Math.cos((lat2 * Math.PI) / 180) *
      Math.sin(dLng / 2) *
      Math.sin(dLng / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return Math.round(R * c * 10) / 10;
}

export async function saveUserLocation(
  userId: string,
  location: Omit<UserLocation, "updatedAt">
): Promise<void> {
  const userRef = doc(db, "users", userId);
  await setDoc(
    userRef,
    {
      location: {
        ...location,
        updatedAt: serverTimestamp(),
      },
    },
    { merge: true }
  );
}

export async function getUserLocation(
  userId: string
): Promise<UserLocation | null> {
  const userRef = doc(db, "users", userId);
  const snapshot = await getDoc(userRef);
  if (!snapshot.exists()) return null;
  const data = snapshot.data() as { location?: UserLocation };
  return data.location ?? null;
}

export async function clearUserLocation(userId: string): Promise<void> {
  const userRef = doc(db, "users", userId);
  await updateDoc(userRef, { location: deleteField() });
}
