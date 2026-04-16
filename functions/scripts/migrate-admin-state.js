/**
 * One-time migration script: moves legacy `role` / `banned` admin fields
 * out of public `users/{uid}` docs into `users/{uid}/admin/state`.
 *
 * This script uses the local Firebase CLI login from:
 *   ~/.config/configstore/firebase-tools.json
 *
 * Run from the functions/ directory:
 *
 *   node scripts/migrate-admin-state.js
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

async function getAccessToken() {
  const config = loadFirebaseToolsConfig();
  const tokens = config.tokens ?? {};

  const expiresAt = typeof tokens.expires_at === "number" ? tokens.expires_at : 0;
  const accessToken = typeof tokens.access_token === "string" ? tokens.access_token : "";
  if (accessToken && expiresAt - Date.now() > 60_000) {
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

  if (response.status === 404) {
    return null;
  }

  const text = await response.text();
  const data = text ? JSON.parse(text) : null;

  if (!response.ok) {
    throw new Error(`Firestore request failed (${response.status}): ${text}`);
  }

  return data;
}

function getField(fields, key) {
  return fields && typeof fields === "object" ? fields[key] : undefined;
}

function buildAdminPatch(legacyFields, adminFields) {
  const patch = {};

  const legacyRole = getField(legacyFields, "role");
  const adminRole = getField(adminFields, "role");
  if (
    legacyRole &&
    typeof legacyRole.stringValue === "string" &&
    legacyRole.stringValue === "admin" &&
    !adminRole
  ) {
    patch.role = { stringValue: "admin" };
  }

  const legacyBanned = getField(legacyFields, "banned");
  const adminBanned = getField(adminFields, "banned");
  if (legacyBanned && legacyBanned.booleanValue === true && !adminBanned) {
    patch.banned = { booleanValue: true };

    const legacyReason = getField(legacyFields, "bannedReason");
    if (
      legacyReason &&
      typeof legacyReason.stringValue === "string" &&
      legacyReason.stringValue.length > 0
    ) {
      patch.bannedReason = { stringValue: legacyReason.stringValue };
    }

    const legacyBannedAt = getField(legacyFields, "bannedAt");
    if (legacyBannedAt && typeof legacyBannedAt.timestampValue === "string") {
      patch.bannedAt = { timestampValue: legacyBannedAt.timestampValue };
    }
  }

  return patch;
}

async function fetchAllUsers() {
  const users = [];
  let nextPageToken = "";

  do {
    const pageTokenParam = nextPageToken
      ? `&pageToken=${encodeURIComponent(nextPageToken)}`
      : "";
    const url = `${FIRESTORE_BASE_URL}/users?pageSize=200${pageTokenParam}`;
    const response = await firestoreRequest(url);

    users.push(...(response?.documents ?? []));
    nextPageToken = response?.nextPageToken ?? "";
  } while (nextPageToken);

  return users;
}

async function patchDocument(docName, fields) {
  const fieldPaths = Object.keys(fields)
    .map((field) => `updateMask.fieldPaths=${encodeURIComponent(field)}`)
    .join("&");
  const url = `${FIRESTORE_BASE_URL}/${docName.split("/documents/")[1]}?${fieldPaths}`;
  await firestoreRequest(url, {
    method: "PATCH",
    body: JSON.stringify({
      name: docName,
      fields,
    }),
  });
}

async function deleteLegacyFields(userDocName) {
  const fieldPaths = ["role", "banned", "bannedReason", "bannedAt"]
    .map((field) => `updateMask.fieldPaths=${encodeURIComponent(field)}`)
    .join("&");
  const url = `${FIRESTORE_BASE_URL}/${userDocName.split("/documents/")[1]}?${fieldPaths}`;
  await firestoreRequest(url, {
    method: "PATCH",
    body: JSON.stringify({
      name: userDocName,
      fields: {},
    }),
  });
}

async function main() {
  const users = await fetchAllUsers();

  let migratedAdminState = 0;
  let cleanedLegacyFields = 0;
  let skipped = 0;

  for (const userDoc of users) {
    const legacyFields = userDoc.fields ?? {};
    const hasLegacyFields =
      "role" in legacyFields ||
      "banned" in legacyFields ||
      "bannedReason" in legacyFields ||
      "bannedAt" in legacyFields;

    if (!hasLegacyFields) {
      skipped += 1;
      continue;
    }

    const relativeUserPath = userDoc.name.split("/documents/")[1];
    const adminDocPath = `${relativeUserPath}/admin/state`;
    const adminDocName = `${userDoc.name}/admin/state`;
    const adminDoc = await firestoreRequest(`${FIRESTORE_BASE_URL}/${adminDocPath}`);
    const adminFields = adminDoc?.fields ?? {};

    const adminPatch = buildAdminPatch(legacyFields, adminFields);
    if (Object.keys(adminPatch).length > 0) {
      await patchDocument(adminDoc?.name ?? adminDocName, adminPatch);
      migratedAdminState += 1;
    }

    await deleteLegacyFields(userDoc.name);
    cleanedLegacyFields += 1;
  }

  console.log(
    `Done. Migrated ${migratedAdminState} admin state docs, cleaned ${cleanedLegacyFields} legacy user docs, skipped ${skipped}.`
  );
}

main().catch((error) => {
  console.error("Admin state migration failed:", error);
  process.exit(1);
});
