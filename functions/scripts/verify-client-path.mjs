/**
 * Proves the CLIENT path works end to end: a real signed-in user, constrained
 * by firestore.rules, can do what it should and cannot do what it should not.
 *
 * ## Why this is not another Admin SDK script
 *
 * The Admin SDK bypasses Firestore security rules entirely. An Admin SDK read
 * or write that succeeds says nothing about whether a phone in someone's hand
 * can do the same thing — it only says the document exists. So nothing in here
 * touches `firebase-admin`. Every request below is one a client makes:
 *
 *   - sign-in      Identity Toolkit REST (`accounts:signInWithPassword`),
 *                  the exact endpoint the Web SDK's
 *                  `signInWithEmailAndPassword` posts to;
 *   - reads/writes Firestore REST with `Authorization: Bearer <idToken>`,
 *                  which IS rules-enforced — an unauthenticated GET of
 *                  `seedRuns/current` returns "No matching allow statements";
 *   - callables    the callable HTTP protocol (`{"data":...}` in,
 *                  `{"result":...}` or `{"error":{"status":...}}` out).
 *
 * REST rather than the `firebase` Web SDK package because the Web SDK is not
 * installed under functions/ and this machine's disk is tight. The path
 * exercised is the same one: same endpoints, same ID token, same rules.
 *
 * ## The check that matters most
 *
 * Check 6. It is the only one that proves the rules are actually loaded and
 * evaluated. If a write that must be refused instead SUCCEEDS, that is not a
 * passing day with an odd result — it means the deployed rules are not in
 * force, and every other green line above it is meaningless. It is reported
 * as a hard failure with that wording.
 *
 * ## Usage
 *
 *   Local emulator (project petnote-test — emulator hosts are defaulted):
 *
 *     cd functions
 *     PETNOTE_PROJECT=petnote-test \
 *     PETNOTE_VERIFIED_EMAIL=accept-a@example.com \
 *     PETNOTE_VERIFIED_PASSWORD='...' \
 *     PETNOTE_UNVERIFIED_EMAIL=accept-new@example.com \
 *     PETNOTE_UNVERIFIED_PASSWORD='...' \
 *     node scripts/verify-client-path.mjs
 *
 *   Cloud test project (petnote-devtest — emulator hosts must be UNSET):
 *
 *     cd functions
 *     PETNOTE_PROJECT=petnote-devtest \
 *     PETNOTE_API_KEY='<Web API key from console: Project settings > General>' \
 *     PETNOTE_VERIFIED_EMAIL=accept-a@example.com \
 *     PETNOTE_VERIFIED_PASSWORD='...' \
 *     PETNOTE_UNVERIFIED_EMAIL=accept-new@example.com \
 *     PETNOTE_UNVERIFIED_PASSWORD='...' \
 *     node scripts/verify-client-path.mjs
 *
 * No password is ever hardcoded here and none is printed.
 *
 * ## What it leaves behind
 *
 * Nothing, on a clean run. The like it writes is deleted, the comment it
 * creates is deleted through `deleteCommentCallable`, and both counters are
 * polled back to their starting values. A crash mid-run can leave one like
 * and one comment — both are named in the output so they can be removed by
 * hand. It never creates posts and never runs the seed script.
 *
 * Exit code 0 only if every check passed.
 */

/* ------------------------------------------------------------- guards --- */

// Production is refused by name, first, before anything else is read. A
// wildcard or a prefix match would be a cheap way to find out this check was
// loose, so the allowlist is literal.
const PRODUCTION_PROJECT = "petnote-a9dac";
const EMULATOR_PROJECT = "petnote-test";
const CLOUD_TEST_PROJECT = "petnote-devtest";

const PROJECT = process.env.PETNOTE_PROJECT || "";

if (!PROJECT) {
  console.error(
    "PETNOTE_PROJECT is required. Use petnote-test (local emulator) or " +
      "petnote-devtest (the isolated cloud test project)."
  );
  process.exit(2);
}

if (PROJECT === PRODUCTION_PROJECT || PROJECT.includes(PRODUCTION_PROJECT)) {
  console.error(
    `Refusing to run against ${PROJECT}: that is production. This tool writes ` +
      `likes and comments and deliberately attempts forbidden writes. It only ` +
      `ever runs against the emulator or a named test project.`
  );
  process.exit(2);
}

// A second escape hatch exists for a future test project, but it must be named
// explicitly and it can never name production.
const EXTRA = process.env.PETNOTE_EXTRA_PROJECT || "";
if (EXTRA === PRODUCTION_PROJECT) {
  console.error(`PETNOTE_EXTRA_PROJECT may not be ${PRODUCTION_PROJECT}.`);
  process.exit(2);
}
const ALLOWED = [EMULATOR_PROJECT, CLOUD_TEST_PROJECT, EXTRA].filter(Boolean);
if (!ALLOWED.includes(PROJECT)) {
  console.error(
    `Refusing to run against "${PROJECT}". Allowed: ${ALLOWED.join(", ")}.\n` +
      `Set PETNOTE_EXTRA_PROJECT to add another test project by name.`
  );
  process.exit(2);
}

/* ------------------------------------------------------------ endpoints --- */

// Same trap as seed-ios-native.mjs: with an emulator host set while a cloud
// project is named, every request quietly goes to the emulator and the run
// looks like it verified the cloud. Refuse instead of guessing.
const targetingCloud = PROJECT !== EMULATOR_PROJECT;
if (targetingCloud) {
  for (const key of ["FIRESTORE_EMULATOR_HOST", "FIREBASE_AUTH_EMULATOR_HOST", "FUNCTIONS_EMULATOR_HOST"]) {
    if (process.env[key]) {
      console.error(
        `${key} is set while targeting the cloud project ${PROJECT}. Unset it, ` +
          `or every request goes to the emulator and this run proves nothing ` +
          `about ${PROJECT}.`
      );
      process.exit(2);
    }
  }
} else {
  process.env.FIRESTORE_EMULATOR_HOST ||= "127.0.0.1:8088";
  process.env.FIREBASE_AUTH_EMULATOR_HOST ||= "127.0.0.1:9099";
  process.env.FUNCTIONS_EMULATOR_HOST ||= "127.0.0.1:5101";
}

const REGION = process.env.PETNOTE_REGION || "us-central1";

const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST;
const fsHost = process.env.FIRESTORE_EMULATOR_HOST;
const fnHost = process.env.FUNCTIONS_EMULATOR_HOST;

const AUTH_BASE = authHost
  ? `http://${authHost}/identitytoolkit.googleapis.com/v1`
  : "https://identitytoolkit.googleapis.com/v1";
const FS_BASE = fsHost
  ? `http://${fsHost}/v1/projects/${PROJECT}/databases/(default)/documents`
  : `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents`;
const FN_BASE =
  process.env.PETNOTE_FUNCTIONS_BASE ||
  (fnHost ? `http://${fnHost}/${PROJECT}/${REGION}` : `https://${REGION}-${PROJECT}.cloudfunctions.net`);

// The Auth emulator ignores the key; a real project does not.
const API_KEY =
  process.env.PETNOTE_API_KEY || process.env.VITE_FIREBASE_API_KEY || (authHost ? "emulator-ignores-this-key" : "");

if (!API_KEY) {
  console.error(
    `PETNOTE_API_KEY is required when targeting ${PROJECT}.\n` +
      `It is the Web API key: Firebase console > Project settings > General > ` +
      `"Web API Key". It is a public client key, not a secret, but do not ` +
      `commit it — pass it in the environment.`
  );
  process.exit(2);
}

/* ------------------------------------------------------------- settings --- */

const VERIFIED_EMAIL = process.env.PETNOTE_VERIFIED_EMAIL || "";
const VERIFIED_PASSWORD = process.env.PETNOTE_VERIFIED_PASSWORD || "";
const UNVERIFIED_EMAIL = process.env.PETNOTE_UNVERIFIED_EMAIL || "";
const UNVERIFIED_PASSWORD = process.env.PETNOTE_UNVERIFIED_PASSWORD || "";

if (!VERIFIED_EMAIL || !VERIFIED_PASSWORD) {
  console.error(
    "PETNOTE_VERIFIED_EMAIL and PETNOTE_VERIFIED_PASSWORD are required.\n" +
      "The seeded verified account is accept-a@example.com; the password is " +
      "printed by seed-ios-native.mjs. Never hardcode it here."
  );
  process.exit(2);
}

// Post ids are per-run (`ios-<runId>-post-NNN`) and must never be hardcoded.
// `seedRuns/current` is NOT client-readable — it has no rule at all, so it
// falls through to deny — which is correct for production and means this tool
// cannot read the manifest the way a test with Admin access would. It
// discovers the namespace from the feed instead, which is itself a client
// read. Overridable when a specific post is wanted.
const POST_PREFIX = process.env.PETNOTE_POST_PREFIX || "ios-";
const FORCED_LIKE_POST = process.env.PETNOTE_LIKE_POST || "";
const FORCED_COMMENT_POST = process.env.PETNOTE_COMMENT_POST || "";
const DISCOVERY_LIMIT = Number(process.env.PETNOTE_DISCOVERY_LIMIT || 400);

// Triggers are asynchronous. A deadline, and a plain statement when it is
// missed — no retrying until it happens to go green. 60s by default because a
// cold Cloud Functions instance genuinely takes that long on a first call.
const TRIGGER_TIMEOUT_MS = Number(process.env.PETNOTE_TRIGGER_TIMEOUT_MS || 60_000);
const POLL_INTERVAL_MS = Number(process.env.PETNOTE_POLL_INTERVAL_MS || 1000);
// A first call into a cold Cloud Functions instance can take most of half a
// minute, so the cloud default is generous; the emulator answers instantly.
const HTTP_TIMEOUT_MS = Number(process.env.PETNOTE_HTTP_TIMEOUT_MS || (targetingCloud ? 60_000 : 20_000));

const TAG = `vcp-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}`;

/* ---------------------------------------------------------------- http --- */

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function http(method, url, { token, body } = {}) {
  let res;
  try {
    res = await fetch(url, {
      method,
      headers: {
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
    });
  } catch (error) {
    return { status: 0, ok: false, json: undefined, text: "", transportError: String(error?.message ?? error) };
  }
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : undefined;
  } catch {
    json = undefined;
  }
  return { status: res.status, ok: res.ok, json, text };
}

/** Pulls the error out of either shape Firestore REST returns. */
function restError(r) {
  if (r.transportError) return { status: "TRANSPORT", message: r.transportError };
  const e = Array.isArray(r.json) ? r.json.find((x) => x && x.error)?.error : r.json?.error;
  if (e) return { status: e.status || `CODE_${e.code}`, message: String(e.message || "").split("\n").join(" ").trim() };
  if (!r.ok) return { status: `HTTP_${r.status}`, message: r.text.slice(0, 200) };
  return undefined;
}

/* --------------------------------------------------------------- values --- */

function decodeValue(v) {
  if (!v || typeof v !== "object") return undefined;
  if ("integerValue" in v) return Number(v.integerValue);
  if ("doubleValue" in v) return Number(v.doubleValue);
  if ("stringValue" in v) return v.stringValue;
  if ("booleanValue" in v) return v.booleanValue;
  if ("timestampValue" in v) return v.timestampValue;
  if ("nullValue" in v) return null;
  if ("mapValue" in v) return decodeFields(v.mapValue?.fields || {});
  if ("arrayValue" in v) return (v.arrayValue?.values || []).map(decodeValue);
  return undefined;
}

function decodeFields(fields) {
  const out = {};
  for (const [k, v] of Object.entries(fields || {})) out[k] = decodeValue(v);
  return out;
}

/** Reads a JWT's claims without verifying it — for reporting only. */
function decodeClaims(idToken) {
  try {
    const payload = String(idToken).split(".")[1];
    return JSON.parse(Buffer.from(payload.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8"));
  } catch {
    return {};
  }
}

/* --------------------------------------------------------------- report --- */

const results = [];
let rulesBreach = false;

function record(id, title, expected, actual, status, note) {
  results.push({ id, title, status });
  console.log(`\n[${id}] ${title}`);
  console.log(`  expected : ${expected}`);
  console.log(`  actual   : ${actual}`);
  console.log(`  result   : ${status}${note ? `  (${note})` : ""}`);
}

/* ----------------------------------------------------------- 1. sign-in --- */

/**
 * The same request `signInWithEmailAndPassword` makes.
 *
 * The failure this has to name precisely is a disabled Email/Password
 * provider, because the raw response for it is a bare `OPERATION_NOT_ALLOWED`
 * that reads like a client bug.
 */
async function signIn(email, password) {
  const r = await http("POST", `${AUTH_BASE}/accounts:signInWithPassword?key=${encodeURIComponent(API_KEY)}`, {
    body: { email, password, returnSecureToken: true },
  });

  if (r.ok && r.json?.idToken) {
    const claims = decodeClaims(r.json.idToken);
    return { ok: true, idToken: r.json.idToken, uid: r.json.localId, claims };
  }

  const raw = String(r.json?.error?.message || r.transportError || r.text || `HTTP ${r.status}`);
  const code = raw.split(" ")[0];
  const diagnoses = {
    OPERATION_NOT_ALLOWED:
      "Email/Password sign-in is DISABLED for this project. Firebase console > " +
      "Authentication > Sign-in method > Email/Password > Enable. Nothing below " +
      "this line can run until it is on.",
    PASSWORD_LOGIN_DISABLED:
      "Email/Password sign-in is DISABLED for this project (console > " +
      "Authentication > Sign-in method).",
    CONFIGURATION_NOT_FOUND:
      "Firebase Authentication has never been initialised for this project — " +
      "there is no Identity Platform config at all. Open the Authentication " +
      "section in the console once, then enable Email/Password.",
    EMAIL_NOT_FOUND: `No account ${email} exists in ${PROJECT}. The test accounts have not been seeded into this project.`,
    INVALID_PASSWORD: "Wrong password for this account (the account does exist).",
    INVALID_LOGIN_CREDENTIALS:
      "Wrong email or password, OR email-enumeration protection is on, which " +
      "collapses 'no such user' and 'wrong password' into this one code.",
    USER_DISABLED: "The account exists but is disabled in the Auth console.",
    API_KEY_INVALID: "PETNOTE_API_KEY is not a valid API key for this project.",
    INVALID_API_KEY: "PETNOTE_API_KEY is not a valid API key for this project.",
    PERMISSION_DENIED:
      "The Identity Toolkit API is not enabled for this project, or the API key " +
      "is restricted away from it.",
  };
  let diagnosis = diagnoses[code];
  if (!diagnosis && /API key not valid/i.test(raw)) diagnosis = diagnoses.API_KEY_INVALID;
  if (!diagnosis && r.transportError) diagnosis = `Could not reach ${AUTH_BASE} — ${r.transportError}`;

  return { ok: false, code, raw, diagnosis: diagnosis || `Unrecognised Identity Toolkit error: ${raw}` };
}

/* -------------------------------------------------------- firestore ops --- */

function docUrl(path) {
  return `${FS_BASE}/${path}`;
}

/** Reads one count field. Absent is distinct from 0 — no post starts with these. */
async function readCount(postId, field, token) {
  const r = await http("GET", `${docUrl(`posts/${postId}`)}?mask.fieldPaths=${field}`, { token });
  const err = restError(r);
  if (err) return { error: err };
  const raw = r.json?.fields?.[field];
  if (raw === undefined) return { present: false, value: 0 };
  return { present: true, value: Number(decodeValue(raw)) };
}

/**
 * Waits for a counter to reach `want`, then stops. A miss is reported as a
 * miss — the deadline is not extended and the operation is not repeated.
 */
async function waitForCount(postId, field, want, token) {
  const started = Date.now();
  let last = await readCount(postId, field, token);
  while (Date.now() - started < TRIGGER_TIMEOUT_MS) {
    if (last.error) return { converged: false, last, ms: Date.now() - started };
    if (last.value === want) return { converged: true, last, ms: Date.now() - started };
    await sleep(POLL_INTERVAL_MS);
    last = await readCount(postId, field, token);
  }
  return { converged: last.value === want, last, ms: Date.now() - started };
}

async function callCallable(name, data, token) {
  const r = await http("POST", `${FN_BASE}/${name}`, { token, body: { data } });
  if (r.ok && r.json && "result" in r.json) return { ok: true, result: r.json.result };
  const e = r.json?.error;
  if (e) return { ok: false, status: e.status || `HTTP_${r.status}`, message: String(e.message || "") };
  if (r.transportError) return { ok: false, status: "TRANSPORT", message: r.transportError };
  return { ok: false, status: `HTTP_${r.status}`, message: r.text.slice(0, 200) };
}

/* -------------------------------------------------------------- cleanup --- */

const leftovers = [];

async function deleteDoc(path, token) {
  return http("DELETE", docUrl(path), { token });
}

/* ----------------------------------------------------------- discovery --- */

/**
 * Finds the current seed namespace from the feed, not from `seedRuns/current`
 * (not client-readable) and not from a hardcoded id (they change every run).
 *
 * Several runs can coexist if an old one was never swept, so this groups by
 * run id and takes the largest group — the complete 210-post run — rather
 * than whatever sorts first. Within it, it works from the HIGHEST index
 * downwards: the low indexes carry the seeded likes and the landmark posts
 * other acceptance work asserts on, so touching them invites a collision.
 */
async function discoverPosts(token) {
  const r = await http("POST", `${FS_BASE}:runQuery`, {
    token,
    body: {
      structuredQuery: {
        from: [{ collectionId: "posts" }],
        orderBy: [{ field: { fieldPath: "createdAt" }, direction: "DESCENDING" }],
        limit: DISCOVERY_LIMIT,
        select: { fields: [{ fieldPath: "likeCount" }, { fieldPath: "commentCount" }] },
      },
    },
  });
  const err = restError(r);
  if (err) return { error: err };

  const ids = (Array.isArray(r.json) ? r.json : [])
    .map((row) => row?.document?.name?.split("/").pop())
    .filter((id) => typeof id === "string" && id.startsWith(POST_PREFIX));
  if (ids.length === 0) return { error: { status: "NO_SEED_DATA", message: `No posts with id prefix "${POST_PREFIX}" in ${PROJECT}. Seed it first.` } };

  const runs = new Map();
  for (const id of ids) {
    const m = /^(.*-post-)(\d+)$/.exec(id);
    const key = m ? m[1] : id;
    if (!runs.has(key)) runs.set(key, []);
    runs.get(key).push({ id, index: m ? Number(m[2]) : -1 });
  }
  const [prefix, members] = [...runs.entries()].sort((a, b) => b[1].length - a[1].length)[0];
  members.sort((a, b) => b.index - a.index);
  return { prefix, candidates: members.map((m) => m.id), total: ids.length };
}

/* ------------------------------------------------------------------ run --- */

function banner() {
  console.log("PetNote client-path verification");
  console.log(`  project   ${PROJECT}${targetingCloud ? "  (CLOUD)" : "  (local emulator)"}`);
  console.log(`  auth      ${AUTH_BASE}`);
  console.log(`  firestore ${FS_BASE}`);
  console.log(`  functions ${FN_BASE}`);
  console.log(`  identity  ${VERIFIED_EMAIL} (verified) / ${UNVERIFIED_EMAIL || "(not supplied)"} (unverified)`);
  console.log(`  trigger deadline ${TRIGGER_TIMEOUT_MS}ms, polling every ${POLL_INTERVAL_MS}ms`);
  console.log(`  run tag   ${TAG}`);
  console.log("  no firebase-admin is loaded: every request below is a client request");
}

async function main() {
  banner();

  /* ---- 1. sign in as a real client ---------------------------------- */

  const signedIn = await signIn(VERIFIED_EMAIL, VERIFIED_PASSWORD);
  if (!signedIn.ok) {
    record(
      1,
      "Test account signs in (client signInWithEmailAndPassword)",
      `${VERIFIED_EMAIL} receives an ID token from ${PROJECT}`,
      `${signedIn.code} — ${signedIn.raw}`,
      "FAIL",
      signedIn.diagnosis
    );
    console.log(`\n  DIAGNOSIS: ${signedIn.diagnosis}`);
  } else {
    const aud = signedIn.claims.aud;
    const audOk = aud === PROJECT;
    const verified = signedIn.claims.email_verified === true;
    record(
      1,
      "Test account signs in (client signInWithEmailAndPassword)",
      `${VERIFIED_EMAIL} receives an ID token whose aud is ${PROJECT} and whose email_verified is true`,
      `uid=${signedIn.uid} aud=${aud} email_verified=${signedIn.claims.email_verified}`,
      audOk && verified ? "PASS" : "FAIL",
      !audOk
        ? `token audience is ${aud}, not ${PROJECT} — the API key belongs to a different project`
        : verified
          ? undefined
          : "this account is NOT email-verified, so check 3 cannot pass for the right reason"
    );
  }

  const token = signedIn.ok ? signedIn.idToken : undefined;
  const uid = signedIn.ok ? signedIn.uid : undefined;

  /* ---- 2. read with client permissions ------------------------------ */

  let likePost;
  let commentPost;
  let postCandidates = [];

  if (!token) {
    record(2, "Client-permission reads", "feed and own-bookmarks readable with an ID token", "not attempted — sign-in failed", "BLOCKED");
  } else {
    const found = await discoverPosts(token);
    // The feed is world-readable by design (`match /posts/{postId} { allow
    // read: if true }`), so reading it does not on its own prove the token was
    // applied. The bookmarks read does: its rule is `isOwner(userId)`, so it
    // can only succeed for this uid and it is refused outright without a
    // token (check 6c).
    const bm = await http("GET", `${docUrl(`users/${uid}/bookmarks`)}?pageSize=1`, { token });
    const bmErr = restError(bm);

    if (found.error) {
      record(
        2,
        "Client-permission reads (feed + identity-bound own bookmarks)",
        `feed query returns seeded posts; users/${uid}/bookmarks is readable`,
        `feed query failed: ${found.error.status} ${found.error.message}`,
        "FAIL"
      );
    } else {
      postCandidates = found.candidates;
      likePost = FORCED_LIKE_POST || found.candidates[0];
      commentPost = FORCED_COMMENT_POST || found.candidates[1] || found.candidates[0];
      record(
        2,
        "Client-permission reads (feed + identity-bound own bookmarks)",
        `feed query returns seeded posts; users/${uid}/bookmarks (rule: isOwner) is readable with the token`,
        `${found.total} posts in namespace "${found.prefix}"; bookmarks read ${bmErr ? `FAILED ${bmErr.status}` : "allowed"}`,
        bmErr ? "FAIL" : "PASS",
        `will use ${likePost} for likes and ${commentPost} for comments`
      );
    }
  }

  /* ---- 3. comment through the callable, then read it back ----------- */

  let commentId;
  const commentText = `TEST CONTENT client-path check ${TAG}`;
  let commentBaseline;

  if (!token || !commentPost) {
    record(3, "Comment written through createCommentCallable and read back", "comment stored with the exact text sent", "not attempted — no token or no post", "BLOCKED");
  } else {
    commentBaseline = await readCount(commentPost, "commentCount", token);
    const call = await callCallable("createCommentCallable", { postId: commentPost, text: commentText }, token);
    if (!call.ok) {
      record(
        3,
        "Comment written through createCommentCallable and read back",
        `callable returns {id} for post ${commentPost}`,
        `${call.status}: ${call.message}`,
        "FAIL",
        call.status === "TRANSPORT" || call.status.startsWith("HTTP_404")
          ? `createCommentCallable is not reachable at ${FN_BASE} — not deployed yet, or the region is not ${REGION}`
          : undefined
      );
    } else {
      commentId = call.result?.id;
      leftovers.push(`posts/${commentPost}/comments/${commentId}`);
      const back = await http("GET", docUrl(`posts/${commentPost}/comments/${commentId}`), { token });
      const backErr = restError(back);
      const stored = backErr ? undefined : decodeFields(back.json?.fields);
      const matches = stored?.text === commentText && stored?.authorId === uid;
      record(
        3,
        "Comment written through createCommentCallable and read back",
        `comment ${commentId || "?"} reads back with text "${commentText}" and authorId ${uid}`,
        backErr
          ? `read-back failed: ${backErr.status} ${backErr.message}`
          : `text=${JSON.stringify(stored?.text)} authorId=${stored?.authorId}`,
        matches ? "PASS" : "FAIL"
      );
    }
  }

  /* ---- 4. like trigger eventually updates likeCount ----------------- */

  if (!token || !likePost) {
    record(4, "Like trigger converges likeCount (write, wait, unlike, wait)", "likeCount +1 then back", "not attempted — no token or no post", "BLOCKED");
  } else {
    // This account may already like the chosen post — the seed gives it likes
    // on the low indexes, and a crashed earlier run can leave one anywhere.
    // When the post was not pinned by hand, walk on to the next candidate
    // rather than reporting a fixture collision as a product result.
    let alreadyLiked = true;
    if (FORCED_LIKE_POST) {
      alreadyLiked = !restError(await http("GET", docUrl(`posts/${likePost}/likes/${uid}`), { token }));
    } else {
      for (const candidate of postCandidates.slice(0, 25)) {
        if (restError(await http("GET", docUrl(`posts/${candidate}/likes/${uid}`), { token }))) {
          likePost = candidate;
          alreadyLiked = false;
          break;
        }
      }
    }

    const before = await readCount(likePost, "likeCount", token);
    const likePath = `posts/${likePost}/likes/${uid}`;
    if (alreadyLiked) {
      record(
        4,
        "Like trigger converges likeCount (write, wait, unlike, wait)",
        `a post ${uid} has not liked yet`,
        FORCED_LIKE_POST
          ? `${likePath} already exists — this account has already liked the pinned post`
          : `${uid} already likes all of the first 25 candidate posts`,
        "BLOCKED",
        "set PETNOTE_LIKE_POST to a post this account has not liked"
      );
    } else if (before.error) {
      record(4, "Like trigger converges likeCount (write, wait, unlike, wait)", "likeCount readable", `${before.error.status} ${before.error.message}`, "FAIL");
    } else {
      // Exactly the body firestore.rules demands: no extra keys, userId and
      // postId matching, and counted:false — an absent `counted` is read
      // downstream as "already counted", which is the hole the rule closes.
      const create = await http("POST", `${docUrl(`posts/${likePost}/likes`)}?documentId=${encodeURIComponent(uid)}`, {
        token,
        body: {
          fields: {
            userId: { stringValue: uid },
            postId: { stringValue: likePost },
            createdAt: { timestampValue: new Date().toISOString() },
            counted: { booleanValue: false },
          },
        },
      });
      const createErr = restError(create);
      if (createErr) {
        record(
          4,
          "Like trigger converges likeCount (write, wait, unlike, wait)",
          `client may write ${likePath} under the rules`,
          `${createErr.status} ${createErr.message}`,
          "FAIL"
        );
      } else {
        leftovers.push(likePath);
        const want = before.value + 1;
        const up = await waitForCount(likePost, "likeCount", want, token);
        const del = await deleteDoc(likePath, token);
        const delErr = restError(del);
        if (!delErr) leftovers.splice(leftovers.indexOf(likePath), 1);
        const down = delErr ? undefined : await waitForCount(likePost, "likeCount", before.value, token);

        const ok = up.converged && !delErr && down?.converged;
        record(
          4,
          "Like trigger converges likeCount (write, wait, unlike, wait)",
          `likeCount ${before.present ? before.value : "absent(=0)"} -> ${want} after the like, back to ${before.value} after the unlike, within ${TRIGGER_TIMEOUT_MS}ms each`,
          `${up.converged ? `reached ${want} in ${up.ms}ms` : `DID NOT CONVERGE within ${up.ms}ms, still ${up.last.present ? up.last.value : "absent"}`}` +
            `; ${delErr ? `unlike failed: ${delErr.status}` : down.converged ? `back to ${before.value} in ${down.ms}ms` : `DID NOT CONVERGE back within ${down.ms}ms, still ${down.last.present ? down.last.value : "absent"}`}`,
          ok ? "PASS" : up.converged || down?.converged ? "TIMEOUT" : "TIMEOUT",
          ok ? undefined : "trigger latency is normal; not converging inside the deadline is not"
        );
      }
    }
  }

  /* ---- 5. comment trigger eventually updates commentCount ----------- */

  if (!token || !commentId || !commentPost) {
    record(5, "Comment trigger converges commentCount", "commentCount +1 then back", "not attempted — check 3 did not produce a comment", "BLOCKED");
  } else {
    const base = commentBaseline?.error ? { present: false, value: 0 } : commentBaseline;
    const want = base.value + 1;
    const up = await waitForCount(commentPost, "commentCount", want, token);

    const del = await callCallable("deleteCommentCallable", { postId: commentPost, commentId }, token);
    if (del.ok) leftovers.splice(leftovers.indexOf(`posts/${commentPost}/comments/${commentId}`), 1);
    const down = del.ok ? await waitForCount(commentPost, "commentCount", base.value, token) : undefined;

    const ok = up.converged && del.ok && down?.converged;
    record(
      5,
      "Comment trigger converges commentCount",
      `commentCount ${base.present ? base.value : "absent(=0)"} -> ${want} after the comment, back to ${base.value} after deleteCommentCallable, within ${TRIGGER_TIMEOUT_MS}ms each`,
      `${up.converged ? `reached ${want} in ${up.ms}ms` : `DID NOT CONVERGE within ${up.ms}ms, still ${up.last.present ? up.last.value : "absent"}`}` +
        `; ${del.ok ? (down.converged ? `back to ${base.value} in ${down.ms}ms` : `DID NOT CONVERGE back within ${down.ms}ms, still ${down.last.present ? down.last.value : "absent"}`) : `deleteCommentCallable failed: ${del.status} ${del.message}`}`,
      ok ? "PASS" : "TIMEOUT",
      ok ? undefined : "trigger latency is normal; not converging inside the deadline is not"
    );
  }

  /* ---- 6. the forbidden stays forbidden ----------------------------- */

  // The one check that proves the rules are loaded at all. Every sub-check
  // here PASSES only by being refused. A success is a breach, reported as
  // such — and cleaned up, because a forged like left behind corrupts a count.
  const denials = [];

  async function mustBeDenied(label, expectation, attempt, cleanupPath, cleanupToken) {
    const outcome = await attempt();
    if (outcome.denied) {
      denials.push({ label, ok: true, detail: outcome.detail });
      console.log(`    ok      ${label} -> refused (${outcome.detail})`);
      return;
    }
    rulesBreach = true;
    denials.push({ label, ok: false, detail: outcome.detail });
    console.log(`    BREACH  ${label} -> ALLOWED (${outcome.detail}) — expected ${expectation}`);
    if (cleanupPath) {
      const r = await deleteDoc(cleanupPath, cleanupToken);
      console.log(`            cleanup ${cleanupPath}: ${restError(r) ? "FAILED, remove it by hand" : "removed"}`);
    }
  }

  console.log("\n  attempting the forbidden operations (each must be refused):");

  // 6a — no identity at all, writing a like.
  await mustBeDenied(
    "6a anonymous like write",
    "PERMISSION_DENIED",
    async () => {
      const r = await http("POST", `${docUrl(`posts/${likePost || "ios-nonexistent"}/likes`)}?documentId=${TAG}-anon`, {
        body: {
          fields: {
            userId: { stringValue: `${TAG}-anon` },
            postId: { stringValue: likePost || "ios-nonexistent" },
            createdAt: { timestampValue: new Date().toISOString() },
            counted: { booleanValue: false },
          },
        },
      });
      const e = restError(r);
      return { denied: Boolean(e) && /PERMISSION_DENIED|UNAUTHENTICATED|HTTP_40[13]/.test(e.status), detail: e ? `${e.status}` : "write accepted" };
    },
    likePost ? `posts/${likePost}/likes/${TAG}-anon` : undefined,
    token
  );

  // 6b — signed in, but writing a like under somebody else's id. The rule is
  // request.auth.uid == likeId; a forged body is how phantom like state gets
  // planted on a victim.
  if (token && likePost) {
    const otherId = process.env.PETNOTE_OTHER_UID || `not-${uid}`;
    await mustBeDenied(
      "6b signed-in like write under another uid",
      "PERMISSION_DENIED",
      async () => {
        const r = await http("POST", `${docUrl(`posts/${likePost}/likes`)}?documentId=${encodeURIComponent(otherId)}`, {
          token,
          body: {
            fields: {
              userId: { stringValue: otherId },
              postId: { stringValue: likePost },
              createdAt: { timestampValue: new Date().toISOString() },
              counted: { booleanValue: false },
            },
          },
        });
        const e = restError(r);
        return { denied: Boolean(e) && /PERMISSION_DENIED/.test(e.status), detail: e ? e.status : "write accepted" };
      },
      `posts/${likePost}/likes/${otherId}`,
      token
    );

    // 6c — an identity-bound READ from the wrong side of the token. Without
    // this, check 2's read proves nothing: posts are world-readable.
    await mustBeDenied("6c anonymous read of a user's bookmarks", "PERMISSION_DENIED", async () => {
      const r = await http("GET", `${docUrl(`users/${uid}/bookmarks`)}?pageSize=1`);
      const e = restError(r);
      return { denied: Boolean(e) && /PERMISSION_DENIED/.test(e.status), detail: e ? e.status : "read allowed" };
    });

    // 6d — comments are callable-only: `allow create: if false`, for everyone,
    // however verified. The Admin SDK writes this document happily, which is
    // the whole reason an Admin SDK success proves nothing.
    await mustBeDenied(
      "6d signed-in direct comment write (bypassing the callable)",
      "PERMISSION_DENIED",
      async () => {
        const r = await http("POST", `${docUrl(`posts/${commentPost || likePost}/comments`)}?documentId=${TAG}-direct`, {
          token,
          body: {
            fields: {
              authorId: { stringValue: uid },
              text: { stringValue: `TEST CONTENT direct write ${TAG}` },
              createdAt: { timestampValue: new Date().toISOString() },
              counted: { booleanValue: false },
            },
          },
        });
        const e = restError(r);
        return { denied: Boolean(e) && /PERMISSION_DENIED/.test(e.status), detail: e ? e.status : "write accepted" };
      },
      `posts/${commentPost || likePost}/comments/${TAG}-direct`,
      token
    );
  }

  // 6e — an unverified account calling the comment callable. Enforced in
  // functions/src/posts.ts, not in the rules, so it is a separate layer.
  if (!UNVERIFIED_EMAIL || !UNVERIFIED_PASSWORD) {
    denials.push({ label: "6e unverified account comments", ok: false, blocked: true, detail: "PETNOTE_UNVERIFIED_EMAIL/PASSWORD not supplied" });
    console.log("    BLOCKED 6e unverified account comments -> PETNOTE_UNVERIFIED_EMAIL/PASSWORD not supplied");
  } else {
    const unv = await signIn(UNVERIFIED_EMAIL, UNVERIFIED_PASSWORD);
    if (!unv.ok) {
      denials.push({ label: "6e unverified account comments", ok: false, blocked: true, detail: `${unv.code}: ${unv.diagnosis}` });
      console.log(`    BLOCKED 6e unverified account comments -> sign-in failed: ${unv.code} — ${unv.diagnosis}`);
    } else if (unv.claims.email_verified === true) {
      denials.push({ label: "6e unverified account comments", ok: false, blocked: true, detail: "that account IS email-verified, so it cannot test this" });
      console.log(`    BLOCKED 6e unverified account comments -> ${UNVERIFIED_EMAIL} has email_verified=true; it cannot test this rejection`);
    } else {
      await mustBeDenied(
        "6e unverified account comments",
        "permission-denied from createCommentCallable",
        async () => {
          const call = await callCallable(
            "createCommentCallable",
            { postId: commentPost || likePost, text: `TEST CONTENT unverified ${TAG}` },
            unv.idToken
          );
          if (call.ok) return { denied: false, detail: `comment ${call.result?.id} created` };
          return { denied: /PERMISSION_DENIED|permission-denied/i.test(call.status), detail: `${call.status}: ${call.message}` };
        },
        undefined
      );
    }
  }

  const denialsBlocked = denials.filter((d) => d.blocked).length;
  const denialsFailed = denials.filter((d) => !d.ok && !d.blocked).length;
  record(
    6,
    "Unauthenticated and unauthorised operations are refused",
    `all ${denials.length} forbidden operations are refused`,
    `${denials.filter((d) => d.ok).length} refused, ${denialsFailed} ALLOWED, ${denialsBlocked} not runnable`,
    denialsFailed > 0 ? "FAIL" : denialsBlocked > 0 ? "BLOCKED" : "PASS",
    denialsFailed > 0
      ? "an operation that must be refused SUCCEEDED — the deployed rules are not in force. Treat every PASS above as meaningless until this is fixed."
      : undefined
  );

  /* ---- summary ------------------------------------------------------ */

  const passed = results.filter((r) => r.status === "PASS").length;
  console.log("\n" + "-".repeat(72));
  for (const r of results) console.log(`  ${r.status.padEnd(8)} [${r.id}] ${r.title}`);
  if (leftovers.length) {
    console.log(`\n  LEFT BEHIND (remove by hand): ${leftovers.join(", ")}`);
  }
  if (rulesBreach) {
    console.log("\n  SECURITY: at least one forbidden operation was ALLOWED. The rules on");
    console.log(`  ${PROJECT} are not doing their job. This is worse than a failing check.`);
  }
  console.log(
    `\nSUMMARY: ${passed}/${results.length} checks passed against ${PROJECT} ` +
      `(${targetingCloud ? "cloud" : "local emulator"}) as ${VERIFIED_EMAIL} — client path only, no Admin SDK.`
  );
  process.exit(passed === results.length ? 0 : 1);
}

main().catch(async (error) => {
  console.error("\nverify-client-path crashed:", error?.stack || error);
  if (leftovers.length) console.error(`Left behind, remove by hand: ${leftovers.join(", ")}`);
  process.exit(1);
});
