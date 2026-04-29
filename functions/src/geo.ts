import { onCall, HttpsError } from "firebase-functions/v2/https";
import { GEOAPIFY_API_KEY } from "./platform";
import { getNotificationActor } from "./notifications";

type GeoapifyFeature = {
  properties?: {
    name?: unknown;
    street?: unknown;
    formatted?: unknown;
    lat?: unknown;
    lon?: unknown;
    city?: unknown;
    county?: unknown;
    state?: unknown;
  };
};

type AddressLocation = {
  lat: number;
  lng: number;
  city: string;
  state: string;
  fullAddress: string;
  name: string;
};

function assertLatLng(lat: unknown, lng: unknown): asserts lat is number {
  if (
    typeof lat !== "number" ||
    typeof lng !== "number" ||
    !Number.isFinite(lat) ||
    !Number.isFinite(lng) ||
    lat < -90 ||
    lat > 90 ||
    lng < -180 ||
    lng > 180
  ) {
    throw new HttpsError("invalid-argument", "Invalid coordinates.");
  }
}

function mapFeature(feature: GeoapifyFeature): AddressLocation | null {
  const props = feature.properties ?? {};
  const lat = props.lat;
  const lng = props.lon;
  if (
    typeof lat !== "number" ||
    typeof lng !== "number" ||
    !Number.isFinite(lat) ||
    !Number.isFinite(lng)
  ) {
    return null;
  }

  const formatted = typeof props.formatted === "string" ? props.formatted : "";
  const name =
    (typeof props.name === "string" && props.name) ||
    (typeof props.street === "string" && props.street) ||
    formatted;

  return {
    lat,
    lng,
    city:
      (typeof props.city === "string" && props.city) ||
      (typeof props.county === "string" && props.county) ||
      "",
    state: typeof props.state === "string" ? props.state : "",
    fullAddress: formatted,
    name,
  };
}

async function callGeoapify(url: URL): Promise<AddressLocation[]> {
  const response = await fetch(url);
  if (!response.ok) {
    throw new HttpsError("unavailable", "Address lookup failed.");
  }

  const data = (await response.json()) as { features?: GeoapifyFeature[] };
  const features = Array.isArray(data.features) ? data.features : [];
  return features
    .map(mapFeature)
    .filter((item): item is AddressLocation => item !== null);
}

async function assertLookupAllowed(callerUid: string): Promise<void> {
  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot use address lookup.");
  }
}

export const searchAddressesCallable = onCall(
  { secrets: [GEOAPIFY_API_KEY] },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");
    await assertLookupAllowed(callerUid);

    const text =
      typeof (request.data as { text?: unknown }).text === "string"
        ? (request.data as { text: string }).text.trim()
        : "";
    if (text.length < 2 || text.length > 120) {
      return { results: [] };
    }

    const apiKey = GEOAPIFY_API_KEY.value();
    if (!apiKey) {
      throw new HttpsError("failed-precondition", "Geoapify key is not configured.");
    }

    const url = new URL("https://api.geoapify.com/v1/geocode/autocomplete");
    url.searchParams.set("text", text);
    url.searchParams.set("filter", "countrycode:us,ca");
    url.searchParams.set("limit", "5");
    url.searchParams.set("lang", "en");
    url.searchParams.set("apiKey", apiKey);

    return { results: await callGeoapify(url) };
  }
);

export const reverseGeocodeCallable = onCall(
  { secrets: [GEOAPIFY_API_KEY] },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");
    await assertLookupAllowed(callerUid);

    const { lat, lng } = request.data as { lat?: unknown; lng?: unknown };
    assertLatLng(lat, lng);

    const apiKey = GEOAPIFY_API_KEY.value();
    if (!apiKey) {
      throw new HttpsError("failed-precondition", "Geoapify key is not configured.");
    }

    const url = new URL("https://api.geoapify.com/v1/geocode/reverse");
    url.searchParams.set("lat", String(lat));
    url.searchParams.set("lon", String(lng));
    url.searchParams.set("apiKey", apiKey);

    const [result] = await callGeoapify(url);
    return {
      location: result ?? {
        lat,
        lng,
        city: "Unknown",
        state: "",
        fullAddress: "",
        name: "",
      },
    };
  }
);
