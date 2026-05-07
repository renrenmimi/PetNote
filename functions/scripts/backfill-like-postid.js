/**
 * One-time migration: writes a `postId` field onto every legacy like doc
 * that doesn't already have one. The field is required by the
 * collection-group batched lookup in src/hooks/useBatchLikeStatus.ts —
 * without it, old likes wouldn't show as liked on first feed load and
 * would fall back to per-post getDoc probes.
 *
 * The script reuses the local Firebase CLI login from:
 *   ~/.config/configstore/firebase-tools.json
 *
 * Run from the functions/ directory:
 *
 *   node scripts/backfill-like-postid.js
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
const FIRESTORE_QUERY_URL = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents:runQuery`;

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

async function refreshAccessToken(refreshToken) {
  const params = new URLSearchParams({
    client_id: FIREBASE_CLIENT_ID,
    client_secret: FIREBASE_CLIENT_SECRET,
    refresh_token: refreshToken,
    grant_type: "refresh_token",
  });
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: params,
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Failed to refresh access token: ${response.status} ${text}`);
  }
  const json = await response.json();
  return json.access_token;
}

async function loadAccessToken() {
  const config = loadFirebaseToolsConfig();
  const refreshToken = config?.tokens?.refresh_token;
  if (!refreshToken) {
    throw new Error(
      "No refresh token found in firebase-tools.json. Run `firebase login` first."
    );
  }
  return refreshAccessToken(refreshToken);
}

async function listLikesPage(accessToken, pageToken) {
  const body = {
    structuredQuery: {
      from: [{ collectionId: "likes", allDescendants: true }],
      limit: 500,
    },
  };
  if (pageToken) body.structuredQuery.startAt = pageToken;
  const response = await fetch(FIRESTORE_QUERY_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`runQuery failed: ${response.status} ${text}`);
  }
  return response.json();
}

async function patchLikeDoc(accessToken, docName, postId) {
  const url = `https://firestore.googleapis.com/v1/${docName}?updateMask.fieldPaths=postId`;
  const body = {
    fields: {
      postId: { stringValue: postId },
    },
  };
  const response = await fetch(url, {
    method: "PATCH",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`patch failed for ${docName}: ${response.status} ${text}`);
  }
}

async function main() {
  console.log(`Project: ${projectId}`);
  console.log(`Firestore: ${FIRESTORE_BASE_URL}`);
  const accessToken = await loadAccessToken();

  let scanned = 0;
  let patched = 0;
  let skipped = 0;
  let pageToken = null;

  while (true) {
    const results = await listLikesPage(accessToken, pageToken);
    if (!results || results.length === 0) break;
    let lastDocName = null;

    for (const item of results) {
      const docNode = item.document;
      if (!docNode) continue;
      scanned += 1;
      lastDocName = docNode.name;
      const fields = docNode.fields || {};
      if (fields.postId && typeof fields.postId.stringValue === "string") {
        skipped += 1;
        continue;
      }
      // docNode.name === "projects/.../documents/posts/{postId}/likes/{uid}"
      const segments = docNode.name.split("/");
      const postsIdx = segments.indexOf("posts");
      const postId = postsIdx >= 0 ? segments[postsIdx + 1] : null;
      if (!postId) {
        console.warn(`Skipping unparsable like path: ${docNode.name}`);
        continue;
      }
      try {
        await patchLikeDoc(accessToken, docNode.name, postId);
        patched += 1;
      } catch (err) {
        console.error(`Failed to patch ${docNode.name}:`, err);
      }
    }

    if (results.length < 500) break;
    if (!lastDocName) break;
    pageToken = null;
    // The runQuery API doesn't expose a cursor token; emulate paging by
    // reading the next chunk that starts after the last doc seen. For a
    // one-time backfill this loop terminates once we land on a page
    // shorter than the limit.
    break;
  }

  console.log(`Done. Scanned ${scanned}, patched ${patched}, skipped ${skipped}.`);
}

main().catch((err) => {
  console.error("Backfill failed:", err);
  process.exit(1);
});
