import { onCall, HttpsError } from "firebase-functions/v2/https";
import { admin, db, GEOAPIFY_API_KEY } from "./platform";
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

const GEOAPIFY_CACHE_MAX_ENTRIES = 250;
const GEOAPIFY_SEARCH_CACHE_TTL_MS = 5 * 60 * 1000;
const GEOAPIFY_REVERSE_CACHE_TTL_MS = 10 * 60 * 1000;
const GEOAPIFY_MISS_LIMIT_PER_MINUTE = 30;

const geoapifyCache = new Map<
  string,
  { results: AddressLocation[]; expiresAt: number }
>();
const pendingGeoapifyRequests = new Map<string, Promise<AddressLocation[]>>();

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

function normalizeCacheText(text: string): string {
  return text.trim().replace(/\s+/g, " ");
}

function getCachedGeoapifyResults(key: string): AddressLocation[] | null {
  const cached = geoapifyCache.get(key);
  if (!cached) return null;
  if (cached.expiresAt <= Date.now()) {
    geoapifyCache.delete(key);
    return null;
  }
  return cached.results;
}

function setCachedGeoapifyResults(
  key: string,
  results: AddressLocation[],
  ttlMs: number
): void {
  if (geoapifyCache.size >= GEOAPIFY_CACHE_MAX_ENTRIES) {
    const firstKey = geoapifyCache.keys().next().value;
    if (firstKey) {
      geoapifyCache.delete(firstKey);
    }
  }
  geoapifyCache.set(key, {
    results,
    expiresAt: Date.now() + ttlMs,
  });
}

async function getCachedOrFetchGeoapifyResults(
  key: string,
  ttlMs: number,
  fetcher: () => Promise<AddressLocation[]>
): Promise<AddressLocation[]> {
  const cached = getCachedGeoapifyResults(key);
  if (cached) return cached;

  const pending = pendingGeoapifyRequests.get(key);
  if (pending) return pending;

  const request = fetcher()
    .then((results) => {
      setCachedGeoapifyResults(key, results, ttlMs);
      return results;
    })
    .finally(() => {
      pendingGeoapifyRequests.delete(key);
    });
  pendingGeoapifyRequests.set(key, request);
  return request;
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

async function assertGeoapifyQuota(callerUid: string): Promise<void> {
  const now = Date.now();
  const bucket = Math.floor(now / 60_000);
  const quotaRef = db.doc(`geoapifyRateLimits/${callerUid}`);

  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(quotaRef);
    const data = snapshot.exists ? snapshot.data() ?? {} : {};
    const currentBucket =
      typeof data.bucket === "number" ? data.bucket : Number.NaN;
    const currentCount =
      currentBucket === bucket && typeof data.count === "number"
        ? data.count
        : 0;

    if (currentCount >= GEOAPIFY_MISS_LIMIT_PER_MINUTE) {
      throw new HttpsError(
        "resource-exhausted",
        "Too many address lookups. Please wait a moment."
      );
    }

    transaction.set(
      quotaRef,
      {
        bucket,
        count: currentCount + 1,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        expiresAt: admin.firestore.Timestamp.fromMillis(now + 2 * 60 * 60 * 1000),
      },
      { merge: true }
    );
  });
}

export const searchAddressesCallable = onCall(
  { secrets: [GEOAPIFY_API_KEY] },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");
    await assertLookupAllowed(callerUid);

    const rawText =
      typeof (request.data as { text?: unknown }).text === "string"
        ? (request.data as { text: string }).text.trim()
        : "";
    const text = normalizeCacheText(rawText);
    if (text.length < 2 || text.length > 120) {
      return { results: [] };
    }

    const cacheKey = `search:${text.toLowerCase()}`;
    return {
      results: await getCachedOrFetchGeoapifyResults(
        cacheKey,
        GEOAPIFY_SEARCH_CACHE_TTL_MS,
        async () => {
          await assertGeoapifyQuota(callerUid);

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

          return callGeoapify(url);
        }
      ),
    };
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
    const latitude = lat;
    const longitude = lng as number;
    const roundedLat = Number(latitude.toFixed(5));
    const roundedLng = Number(longitude.toFixed(5));

    const cacheKey = `reverse:${roundedLat}:${roundedLng}`;
    const [result] = await getCachedOrFetchGeoapifyResults(
      cacheKey,
      GEOAPIFY_REVERSE_CACHE_TTL_MS,
      async () => {
        await assertGeoapifyQuota(callerUid);

        const apiKey = GEOAPIFY_API_KEY.value();
        if (!apiKey) {
          throw new HttpsError("failed-precondition", "Geoapify key is not configured.");
        }

        const url = new URL("https://api.geoapify.com/v1/geocode/reverse");
        url.searchParams.set("lat", String(roundedLat));
        url.searchParams.set("lon", String(roundedLng));
        url.searchParams.set("apiKey", apiKey);

        return callGeoapify(url);
      }
    );
    return {
      location: result ?? {
        lat: latitude,
        lng: longitude,
        city: "Unknown",
        state: "",
        fullAddress: "",
        name: "",
      },
    };
  }
);
