import { httpsCallable } from "firebase/functions";
import { functions } from "./firebase";

export type AddressLocation = {
  lat: number;
  lng: number;
  city: string;
  state: string;
  fullAddress: string;
  name: string;
};

export async function searchAddresses(text: string): Promise<AddressLocation[]> {
  const normalized = text.trim();
  if (normalized.length < 2) return [];

  const result = await httpsCallable<
    { text: string },
    { results: AddressLocation[] }
  >(functions, "searchAddressesCallable")({ text: normalized });
  return Array.isArray(result.data.results) ? result.data.results : [];
}

export async function reverseGeocode(
  lat: number,
  lng: number
): Promise<AddressLocation> {
  const result = await httpsCallable<
    { lat: number; lng: number },
    { location: AddressLocation }
  >(functions, "reverseGeocodeCallable")({ lat, lng });
  return result.data.location;
}
