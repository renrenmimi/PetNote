/**
 * One-time backfill for the audit-followup PRs (#125-#128):
 *
 *   A. Location review aggregates (PR #127)
 *      For every location with totalRatings > 0, scan its reviews
 *      subcollection and write petFriendlySum / petFriendlyAvg /
 *      tagCounts / topTags. Locations whose reviews predate the
 *      onReviewCreated trigger don't have these fields, so the
 *      LocationDetail UI falls back to the (paginated, partial)
 *      reviews array. After this script runs, the UI uses the exact
 *      server aggregates.
 *
 *   B. Admin/banned custom claims (PR #128)
 *      For every users/{uid}/admin/state doc that already has
 *      role == "admin" or banned == true, re-PATCH the doc with the
 *      same fields. The new onAdminStateWritten trigger fires on the
 *      write and mirrors role/banned into Auth custom claims.
 *
 * Auth: reuses the Firebase CLI's OAuth token from
 *   ~/.config/configstore/firebase-tools.json
 * (matches the existing migrate-admin-state.js pattern), so no
 * service-account key is required. Run from functions/:
 *
 *   node scripts/backfill-aggregates.js
 *
 * Idempotent: re-running just rewrites the same aggregates.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");

const projectId =
  process.env.GCLOUD_PROJECT ||
  process.env.GOOGLE_CLOUD_PROJECT ||
  process.env.FIREBASE_PROJECT_ID ||
  "petnote-a9dac";

const FIREBASE_CLIENT_ID =
  process.env.FIREBASE_CLIENT_ID ||
  "563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com";
const FIREBASE_CLIENT_SECRET =
  process.env.FIREBASE_CLIENT_SECRET || "j9iVZfS8kkCEFUPaAeJV0sAi";
const FIRESTORE_BASE_URL = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents`;

const TOP_TAGS_LIMIT = 10;

function loadFirebaseToolsConfig() {
  const configPath = path.join(
    os.homedir(),
    ".config",
    "configstore",
    "firebase-tools.json"
  );
  if (!fs.existsSync(configPath)) {
    throw new Error(`Firebase CLI config not found at ${configPath}`);
  }
  return JSON.parse(fs.readFileSync(configPath, "utf8"));
}

let cachedToken = { value: "", expiresAt: 0 };

async function getAccessToken() {
  if (cachedToken.value && cachedToken.expiresAt - Date.now() > 60_000) {
    return cachedToken.value;
  }
  const config = loadFirebaseToolsConfig();
  const tokens = config.tokens ?? {};

  const expiresAt = typeof tokens.expires_at === "number" ? tokens.expires_at : 0;
  const accessToken = typeof tokens.access_token === "string" ? tokens.access_token : "";
  if (accessToken && expiresAt - Date.now() > 60_000) {
    cachedToken = { value: accessToken, expiresAt };
    return accessToken;
  }

  const refreshToken =
    typeof tokens.refresh_token === "string" ? tokens.refresh_token : "";
  if (!refreshToken) {
    throw new Error("Firebase CLI refresh token not found.");
  }

  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: FIREBASE_CLIENT_ID,
      client_secret: FIREBASE_CLIENT_SECRET,
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    }),
  });

  const data = await response.json();
  if (!response.ok || typeof data.access_token !== "string") {
    throw new Error(
      `Failed to refresh Firebase CLI access token: ${JSON.stringify(data)}`
    );
  }

  const expiresIn = typeof data.expires_in === "number" ? data.expires_in : 3600;
  cachedToken = {
    value: data.access_token,
    expiresAt: Date.now() + expiresIn * 1000,
  };
  return data.access_token;
}

async function firestoreRequest(url, options = {}) {
  const accessToken = await getAccessToken();
  const response = await fetch(url, {
    ...options,
    headers: {
      authorization: `Bearer ${accessToken}`,
      "content-type": "application/json",
      ...(options.headers ?? {}),
    },
  });

  if (response.status === 404) return null;

  const text = await response.text();
  const data = text ? JSON.parse(text) : null;

  if (!response.ok) {
    throw new Error(`Firestore request failed (${response.status}): ${text}`);
  }
  return data;
}

// ---------------------------- value coding ----------------------------

function asValue(input) {
  if (input === null || input === undefined) return { nullValue: null };
  if (typeof input === "boolean") return { booleanValue: input };
  if (typeof input === "string") return { stringValue: input };
  if (typeof input === "number") {
    return Number.isInteger(input)
      ? { integerValue: String(input) }
      : { doubleValue: input };
  }
  if (Array.isArray(input)) {
    return { arrayValue: { values: input.map(asValue) } };
  }
  if (typeof input === "object") {
    return {
      mapValue: {
        fields: Object.fromEntries(
          Object.entries(input).map(([k, v]) => [k, asValue(v)])
        ),
      },
    };
  }
  throw new Error(`Unsupported value type: ${typeof input}`);
}

function readNumber(field) {
  if (!field) return 0;
  if (typeof field.integerValue === "string") return Number(field.integerValue);
  if (typeof field.doubleValue === "number") return field.doubleValue;
  return 0;
}

function readString(field) {
  return field && typeof field.stringValue === "string" ? field.stringValue : "";
}

function readBoolean(field) {
  return field && field.booleanValue === true;
}

function readMap(field) {
  return field && field.mapValue && field.mapValue.fields
    ? field.mapValue.fields
    : null;
}

function readArrayStrings(field) {
  if (!field || !field.arrayValue || !Array.isArray(field.arrayValue.values)) {
    return [];
  }
  return field.arrayValue.values
    .map((v) => readString(v))
    .filter((s) => s.length > 0);
}

// ---------------------------- A: location aggregates ----------------------------

async function listAllLocations() {
  const all = [];
  let nextPageToken = "";
  do {
    const tokenParam = nextPageToken
      ? `&pageToken=${encodeURIComponent(nextPageToken)}`
      : "";
    const url = `${FIRESTORE_BASE_URL}/locations?pageSize=200${tokenParam}`;
    const response = await firestoreRequest(url);
    all.push(...(response?.documents ?? []));
    nextPageToken = response?.nextPageToken ?? "";
  } while (nextPageToken);
  return all;
}

async function listLocationReviews(locationDocName) {
  const reviews = [];
  let nextPageToken = "";
  do {
    const tokenParam = nextPageToken
      ? `&pageToken=${encodeURIComponent(nextPageToken)}`
      : "";
    const url = `${FIRESTORE_BASE_URL}/${locationDocName.split("/documents/")[1]}/reviews?pageSize=300${tokenParam}`;
    const response = await firestoreRequest(url);
    reviews.push(...(response?.documents ?? []));
    nextPageToken = response?.nextPageToken ?? "";
  } while (nextPageToken);
  return reviews;
}

function recomputeFromReviews(reviewDocs) {
  let sumRating = 0;
  const pfSum = { space: 0, safety: 0, cleanliness: 0 };
  const tagCounts = {};
  const distinctTags = new Set();

  for (const doc of reviewDocs) {
    const fields = doc.fields ?? {};
    const rating = readNumber(fields.rating);
    sumRating += rating;

    const pf = readMap(fields.petFriendly) || {};
    pfSum.space += readNumber(pf.space) || rating;
    pfSum.safety += readNumber(pf.safety) || rating;
    pfSum.cleanliness += readNumber(pf.cleanliness) || rating;

    const tags = readArrayStrings(fields.tags);
    for (const tag of tags) {
      tagCounts[tag] = (tagCounts[tag] ?? 0) + 1;
      distinctTags.add(tag);
    }
  }

  const count = reviewDocs.length;
  const averageRating = count === 0 ? 0 : Number((sumRating / count).toFixed(2));
  const divide = (sum) => (count === 0 ? 0 : Number((sum / count).toFixed(2)));
  const petFriendlyAvg = {
    space: divide(pfSum.space),
    safety: divide(pfSum.safety),
    cleanliness: divide(pfSum.cleanliness),
  };
  const topTags = Object.entries(tagCounts)
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, TOP_TAGS_LIMIT)
    .map(([tag]) => tag);

  return {
    sumRating,
    totalRatings: count,
    averageRating,
    petFriendlySum: pfSum,
    petFriendlyAvg,
    tagCounts,
    topTags,
    tags: Array.from(distinctTags),
  };
}

async function patchLocationAggregates(locationDocName, aggregates) {
  const fields = {
    sumRating: asValue(aggregates.sumRating),
    totalRatings: asValue(aggregates.totalRatings),
    averageRating: asValue(aggregates.averageRating),
    petFriendlySum: asValue(aggregates.petFriendlySum),
    petFriendlyAvg: asValue(aggregates.petFriendlyAvg),
    tagCounts: asValue(aggregates.tagCounts),
    topTags: asValue(aggregates.topTags),
    tags: asValue(aggregates.tags),
  };
  const updateMask = Object.keys(fields)
    .map((field) => `updateMask.fieldPaths=${encodeURIComponent(field)}`)
    .join("&");
  const url = `${FIRESTORE_BASE_URL}/${locationDocName.split("/documents/")[1]}?${updateMask}`;
  await firestoreRequest(url, {
    method: "PATCH",
    body: JSON.stringify({ name: locationDocName, fields }),
  });
}

async function backfillLocationAggregates() {
  const locations = await listAllLocations();
  const candidates = locations.filter((doc) => {
    const total = readNumber(doc.fields?.totalRatings);
    return total > 0;
  });

  console.log(
    `[A] Locations: ${locations.length} total, ${candidates.length} with totalRatings > 0`
  );

  let updated = 0;
  let skipped = 0;
  for (const location of candidates) {
    const reviews = await listLocationReviews(location.name);
    if (reviews.length === 0) {
      skipped += 1;
      continue;
    }
    const aggregates = recomputeFromReviews(reviews);
    await patchLocationAggregates(location.name, aggregates);
    updated += 1;
    if (updated % 10 === 0) {
      console.log(`[A] ... ${updated} locations updated`);
    }
  }

  console.log(`[A] Done. Updated ${updated}, skipped ${skipped} (no reviews).`);
}

// ---------------------------- B: admin state trigger replay ----------------------------

async function listAdminStateDocs() {
  const url = `${FIRESTORE_BASE_URL}:runQuery`;
  const body = {
    structuredQuery: {
      from: [{ collectionId: "admin", allDescendants: true }],
      // Trigger applies for either role==admin OR banned==true. Two
      // separate queries since Firestore doesn't allow OR across
      // different fields without composite indexes we don't have.
    },
  };
  const result = await firestoreRequest(url, {
    method: "POST",
    body: JSON.stringify(body),
  });
  if (!Array.isArray(result)) return [];
  return result
    .map((row) => row.document)
    .filter(
      (doc) =>
        !!doc &&
        typeof doc.name === "string" &&
        doc.name.endsWith("/admin/state")
    );
}

async function rewriteAdminState(doc) {
  // No-op write: re-PATCH every present field with the same value.
  // The onAdminStateWritten trigger fires on any write and resyncs
  // Auth custom claims based on the post-state.
  const fields = doc.fields ?? {};
  const fieldKeys = Object.keys(fields);
  if (fieldKeys.length === 0) return;
  const updateMask = fieldKeys
    .map((field) => `updateMask.fieldPaths=${encodeURIComponent(field)}`)
    .join("&");
  const url = `${FIRESTORE_BASE_URL}/${doc.name.split("/documents/")[1]}?${updateMask}`;
  await firestoreRequest(url, {
    method: "PATCH",
    body: JSON.stringify({ name: doc.name, fields }),
  });
}

async function backfillAdminStateClaims() {
  const docs = await listAdminStateDocs();
  const candidates = docs.filter((doc) => {
    const fields = doc.fields ?? {};
    return (
      readString(fields.role) === "admin" || readBoolean(fields.banned)
    );
  });

  console.log(
    `[B] Admin/state: ${docs.length} total, ${candidates.length} with role=admin or banned=true`
  );

  let updated = 0;
  for (const doc of candidates) {
    await rewriteAdminState(doc);
    updated += 1;
  }

  console.log(`[B] Done. Re-wrote ${updated} admin/state docs (custom claims will sync on trigger).`);
}

// ---------------------------- main ----------------------------

async function main() {
  console.log(`Project: ${projectId}`);
  await backfillLocationAggregates();
  await backfillAdminStateClaims();
}

main().catch((error) => {
  console.error("Backfill failed:", error);
  process.exit(1);
});
