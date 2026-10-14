/**
 * Many people at once, through the client path: what happens when tens of
 * users sign up, follow, post, like, comment, join one meetup, redeem one
 * invitation and check in at one place at the same moment, and whether every
 * count the server keeps comes out exactly right.
 *
 * Same rules as verify-client-features.mjs: nothing here acts as the server.
 * Sign-up and sign-in are Identity Toolkit REST, callables are the callable
 * HTTP protocol, and the writes the app makes itself (a like, leaving a
 * meetup) are Firestore REST with the user's own ID token, under the rules.
 * Only the checks read with admin rights, to see the whole picture.
 *
 * Usage, local emulators (the functions emulator too, so the triggers run):
 *
 *   firebase emulators:exec --config firebase.scenarios.json \
 *     --only auth,firestore,functions --project petnote-test \
 *     "node functions/scripts/scenario-many-users.mjs"
 *
 * Usage, the cloud test project, by name and nothing else (emulator hosts
 * must be unset; the admin token is a project owner's, for marking the
 * people's emails verified, the checks and the cleanup):
 *
 *   PETNOTE_PROJECT=petnote-devtest PETNOTE_API_KEY=... \
 *   PETNOTE_IOS_BUNDLE=dev.local.petnote.native PETNOTE_ADMIN_TOKEN=... \
 *   node functions/scripts/scenario-many-users.mjs
 *
 *   SIM_USERS     how many people (default 50)
 *   SIM_PARALLEL  at most this many requests in flight (default: no limit).
 *                 The emulator's transactions lock far more than the cloud's
 *                 (a query inside one locks the whole collection), so many
 *                 at once time out there that would not in the cloud; a run
 *                 for the counts at scale uses about 6.
 *   SIM_ADMIN_ACCOUNTS  1 to make the accounts through the admin API, already
 *                 verified, and only sign in through the client path: the
 *                 sign-up endpoint limits how many accounts one address may
 *                 make in an hour.
 *   SIM_ONLY      a comma-separated list of what to run besides the accounts,
 *                 pets and posts the rest need: follows, likes, comments,
 *                 meetup, invitation, places, visitors, ratelimit.
 *   SIM_CLEANUP   1 to delete everything the run made, and its accounts,
 *                 then check that nothing of it is left. Always on in the
 *                 cloud.
 *
 * Production is refused by name. On the test project, what it has not got
 * is skipped and said so: check-ins (no media account to vouch for a photo),
 * reviews, and the trigger that counts someone leaving a meetup.
 *
 * Exit code 0 only if every check passed.
 */

const PRODUCTION_PROJECT = "petnote-a9dac";
const EMULATOR_PROJECT = "petnote-test";
const CLOUD_PROJECT = "petnote-devtest";
const PROJECT = process.env.PETNOTE_PROJECT || process.env.GCLOUD_PROJECT || EMULATOR_PROJECT;
if (PROJECT.includes(PRODUCTION_PROJECT) || ![EMULATOR_PROJECT, CLOUD_PROJECT].includes(PROJECT)) {
  console.error(`Refusing to run against "${PROJECT}". Only ${EMULATOR_PROJECT} or ${CLOUD_PROJECT}. Never ${PRODUCTION_PROJECT}.`);
  process.exit(2);
}
const CLOUD = PROJECT === CLOUD_PROJECT;
const REGION = "us-central1";
let AUTH_BASE, FS_ROOT, FN_BASE, API_KEY, IOS_BUNDLE;
const ADMIN = { token: "" };
if (CLOUD) {
  for (const key of ["FIRESTORE_EMULATOR_HOST", "FIREBASE_AUTH_EMULATOR_HOST", "FUNCTIONS_EMULATOR_HOST"]) {
    if (process.env[key]) {
      console.error(`${key} is set while targeting ${PROJECT}; every request would go to the emulator.`);
      process.exit(2);
    }
  }
  API_KEY = process.env.PETNOTE_API_KEY || "";
  IOS_BUNDLE = process.env.PETNOTE_IOS_BUNDLE || "";
  ADMIN.token = process.env.PETNOTE_ADMIN_TOKEN || "";
  if (!API_KEY || !IOS_BUNDLE || !ADMIN.token) {
    console.error("PETNOTE_API_KEY, PETNOTE_IOS_BUNDLE and PETNOTE_ADMIN_TOKEN are required for the cloud.");
    process.exit(2);
  }
  AUTH_BASE = "https://identitytoolkit.googleapis.com/v1";
  FS_ROOT = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents`;
  FN_BASE = `https://${REGION}-${PROJECT}.cloudfunctions.net`;
} else {
  const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST || "127.0.0.1:9299";
  const fsHost = process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8288";
  const fnHost = process.env.FUNCTIONS_EMULATOR_HOST || "127.0.0.1:5301";
  for (const host of [authHost, fsHost, fnHost]) {
    if (!/^(127\.0\.0\.1|localhost):\d+$/.test(host)) {
      console.error(`Refusing a non-local host: ${host}`);
      process.exit(2);
    }
  }
  AUTH_BASE = `http://${authHost}/identitytoolkit.googleapis.com/v1`;
  FS_ROOT = `http://${fsHost}/v1/projects/${PROJECT}/databases/(default)/documents`;
  FN_BASE = `http://${fnHost}/${PROJECT}/${REGION}`;
  API_KEY = "emulator";
  // The emulator's admin token: past the rules, for the checks only.
  ADMIN.token = "owner";
}
const DOCS = `projects/${PROJECT}/databases/(default)/documents`;
const PASSWORD = "Sim-passw0rd!";
const N = Number(process.env.SIM_USERS || 50);
const CLEANUP = CLOUD || process.env.SIM_CLEANUP === "1";
const ONLY = new Set((process.env.SIM_ONLY || "").split(",").map((x) => x.trim()).filter(Boolean));
const want = (name) => !ONLY.size || ONLY.has(name);
const TAG = `sim${Date.now().toString(36)}`;
const TIMEOUT_MS = 120_000;
// The triggers in the cloud take longer to catch up than the emulator's.
const SETTLE_MS = CLOUD ? 240_000 : 60_000;

/* ----------------------------------------------------------- plumbing --- */

const PARALLEL = Number(process.env.SIM_PARALLEL || 0);
let inFlight = 0;
const waiting = [];
/** A place among the requests in flight, when they are limited. A freed place passes straight to the next in line. */
async function slot() {
  if (!PARALLEL) return;
  if (inFlight < PARALLEL) {
    inFlight += 1;
    return;
  }
  await new Promise((resolve) => waiting.push(resolve));
}
function release() {
  if (!PARALLEL) return;
  const next = waiting.shift();
  if (next) next();
  else inFlight -= 1;
}

/** One request; `ms` is how long the server took, not counting a wait for a place. */
async function http(method, url, { token, body } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (IOS_BUNDLE && url.includes("key=")) headers["X-Ios-Bundle-Identifier"] = IOS_BUNDLE;
  if (CLOUD && token === ADMIN.token) headers["X-Goog-User-Project"] = PROJECT;
  await slot();
  try {
    for (let attempt = 0; ; attempt += 1) {
      const r = await once(method, url, headers, body);
      // The name did not resolve or the connection was refused: the request
      // was never sent, so sending it again cannot make two of anything.
      if (r.status === 0 && NEVER_SENT.has(r.json.error.message) && attempt < 3) {
        await sleep(300 * (attempt + 1));
        continue;
      }
      return r;
    }
  } finally {
    release();
  }
}

const NEVER_SENT = new Set(["ENOTFOUND", "EAI_AGAIN", "ECONNREFUSED"]);

async function once(method, url, headers, body) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  const started = performance.now();
  try {
    const res = await fetch(url, { method, headers, body: body ? JSON.stringify(body) : undefined, signal: controller.signal });
    const text = await res.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { json = { raw: text.slice(0, 200) }; }
    return { status: res.status, json, ms: performance.now() - started };
  } catch (error) {
    // A connection that dropped or timed out: an answer of its own, so one
    // among hundreds is counted rather than the end of the run. Not retried:
    // the request may have arrived, and a comment sent twice would be two.
    return { status: 0, json: { error: { status: "NETWORK", message: String(error?.cause?.code ?? error?.message ?? error) } }, ms: performance.now() - started };
  } finally {
    clearTimeout(timer);
  }
}

/** How long each kind of request took, for the report. */
const timings = new Map();
async function timed(kind, fn) {
  const r = await fn();
  const list = timings.get(kind) ?? [];
  list.push(r.ms);
  timings.set(kind, list);
  return r;
}

async function signUp(email) {
  const r = await timed("sign up", () => http("POST", `${AUTH_BASE}/accounts:signUp?key=${API_KEY}`, {
    body: { email, password: PASSWORD, returnSecureToken: true },
  }));
  if (r.status !== 200) throw new Error(`sign-up failed for ${email}: HTTP ${r.status} ${JSON.stringify(r.json?.error?.message)}`);
  return { token: r.json.idToken, uid: r.json.localId, email };
}

/** A sign-in that keeps its time, for the report. */
async function signInTimed(email) {
  const r = await http("POST", `${AUTH_BASE}/accounts:signInWithPassword?key=${API_KEY}`, {
    body: { email, password: PASSWORD, returnSecureToken: true },
  });
  if (r.status !== 200) throw new Error(`sign-in failed for ${email}: HTTP ${r.status} ${JSON.stringify(r.json?.error?.message)}`);
  return { token: r.json.idToken, uid: r.json.localId, email, ms: r.ms };
}

async function signIn(email) {
  const r = await http("POST", `${AUTH_BASE}/accounts:signInWithPassword?key=${API_KEY}`, {
    body: { email, password: PASSWORD, returnSecureToken: true },
  });
  if (r.status !== 200) throw new Error(`sign-in failed for ${email}: HTTP ${r.status}`);
  return { token: r.json.idToken, uid: r.json.localId, email };
}

/** An account made with admin rights, its email already verified; then signed in as the app signs in. */
async function adminCreate(email) {
  for (let attempt = 0; ; attempt += 1) {
    const r = await timed("admin create account", () => http("POST", `${AUTH_BASE}/projects/${PROJECT}/accounts`, {
      token: ADMIN.token, body: { email, password: PASSWORD, emailVerified: true },
    }));
    if (r.status === 200) return { uid: r.json.localId, email };
    // A dropped connection may still have made it: signed in, it says whose.
    if (String(r.json?.error?.message ?? "").startsWith("EMAIL_EXISTS")) {
      const account = await signIn(email);
      return { uid: account.uid, email };
    }
    if (r.status !== 0 || attempt >= 3) throw new Error(`creating ${email} failed: HTTP ${r.status} ${JSON.stringify(r.json?.error?.message)}`);
    await sleep(500 * (attempt + 1));
  }
}

/** The emulator's admin update, then a fresh token that says so. */
async function verifyEmail(user) {
  const r = await http("POST", `${AUTH_BASE}/projects/${PROJECT}/accounts:update`, {
    token: ADMIN.token, body: { localId: user.uid, emailVerified: true },
  });
  if (r.status !== 200) throw new Error(`verifying ${user.email} failed: HTTP ${r.status}`);
  return signIn(user.email);
}

/** The callable protocol. { ok, result } or { ok: false, code, message }. */
async function call(user, name, data) {
  const r = await timed(name, () => http("POST", `${FN_BASE}/${name}`, { token: user?.token, body: { data } }));
  if (r.status === 200 && r.json && "result" in r.json) return { ok: true, result: r.json.result };
  const e = r.json?.error ?? {};
  const code = e.status ? String(e.status).toLowerCase().replace(/_/g, "-") : `http-${r.status}`;
  return { ok: false, code, message: e.message ?? JSON.stringify(r.json).slice(0, 160) };
}

const value = (v) => {
  if (typeof v === "string") return { stringValue: v };
  if (typeof v === "boolean") return { booleanValue: v };
  if (Number.isInteger(v)) return { integerValue: String(v) };
  if (typeof v === "number") return { doubleValue: v };
  if (v === null) return { nullValue: null };
  return { mapValue: { fields: Object.fromEntries(Object.entries(v).map(([k, x]) => [k, value(x)])) } };
};

/** A create the app makes itself: refused if the document exists, stamped by the server's clock. */
async function clientCreate(user, path, fields, { stamp } = {}) {
  const write = {
    update: { name: `${DOCS}/${path}`, fields: Object.fromEntries(Object.entries(fields).map(([k, v]) => [k, value(v)])) },
    currentDocument: { exists: false },
  };
  if (stamp) write.updateTransforms = [{ fieldPath: stamp, setToServerValue: "REQUEST_TIME" }];
  return timed("client write", () => http("POST", `${FS_ROOT}:commit`, { token: user.token, body: { writes: [write] } }));
}

async function clientDelete(user, path) {
  return timed("client delete", () => http("DELETE", `${FS_ROOT}/${path}`, { token: user.token }));
}

const plain = (v) => {
  if (!v) return undefined;
  if ("stringValue" in v) return v.stringValue;
  if ("integerValue" in v) return Number(v.integerValue);
  if ("doubleValue" in v) return v.doubleValue;
  if ("booleanValue" in v) return v.booleanValue;
  if ("timestampValue" in v) return v.timestampValue;
  if ("nullValue" in v) return null;
  if ("mapValue" in v) return Object.fromEntries(Object.entries(v.mapValue.fields ?? {}).map(([k, x]) => [k, plain(x)]));
  if ("arrayValue" in v) return (v.arrayValue.values ?? []).map(plain);
  return v;
};

async function adminGet(path) {
  const r = await http("GET", `${FS_ROOT}/${path}`, { token: ADMIN.token });
  if (r.status === 404) return null;
  if (r.status !== 200) throw new Error(`reading ${path}: HTTP ${r.status}`);
  return Object.fromEntries(Object.entries(r.json.fields ?? {}).map(([k, v]) => [k, plain(v)]));
}

/** Every document of a subcollection, or of a collection group under the root. */
async function adminQuery(parent, collectionId, { allDescendants = false, where } = {}) {
  const structuredQuery = { from: [{ collectionId, allDescendants }] };
  if (where) {
    structuredQuery.where = {
      fieldFilter: { field: { fieldPath: where[0] }, op: "EQUAL", value: value(where[1]) },
    };
  }
  const url = parent ? `${FS_ROOT}/${parent}:runQuery` : `${FS_ROOT}:runQuery`;
  const r = await http("POST", url, { token: ADMIN.token, body: { structuredQuery } });
  if (r.status !== 200) throw new Error(`querying ${parent}/${collectionId}: HTTP ${r.status} ${JSON.stringify(r.json).slice(0, 200)}`);
  return (Array.isArray(r.json) ? r.json : []).filter((row) => row.document).map((row) => ({
    id: row.document.name.split("/").pop(),
    path: row.document.name.split("/documents/")[1],
    ...Object.fromEntries(Object.entries(row.document.fields ?? {}).map(([k, v]) => [k, plain(v)])),
  }));
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
/** Until the triggers have caught up, or the time runs out: the last answer either way. */
async function settle(read, done, { timeout = SETTLE_MS, every = CLOUD ? 2000 : 500 } = {}) {
  const until = Date.now() + timeout;
  let last = await read();
  while (!done(last) && Date.now() < until) {
    await sleep(every);
    last = await read();
  }
  return last;
}

/* ------------------------------------------------------------ results --- */

const results = [];
function check(id, ok, detail) {
  results.push({ id, ok });
  console.log(`${(ok ? "PASS" : "FAIL").padEnd(6)} ${id.padEnd(58)} ${detail}`);
}
const skipped = [];
function skip(id, why) {
  skipped.push(id);
  console.log(`${"SKIP".padEnd(6)} ${id.padEnd(58)} ${why}`);
}

/** What this run made, for the cleanup. */
const made = { users: [], pets: [], posts: [], meetups: [], codes: [], places: [], startedAt: new Date().toISOString() };
const tally = (outcomes) => ({
  ok: outcomes.filter((o) => o.ok).length,
  refused: outcomes.filter((o) => !o.ok).length,
  codes: [...new Set(outcomes.filter((o) => !o.ok).map((o) => o.code))].join(","),
});

/* ------------------------------------------------------------ cleanup --- */

/** `fn` over `items`, `size` at a time. */
async function pooled(items, size, fn) {
  const out = [];
  for (let i = 0; i < items.length; i += size) out.push(...(await Promise.all(items.slice(i, i + size).map(fn))));
  return out;
}

/** The names of the documents of `collectionId` whose `field` is one of `values`. */
async function namesWhereIn(collectionId, field, values) {
  const names = [];
  for (let i = 0; i < values.length; i += 30) {
    const chunk = values.slice(i, i + 30);
    const r = await http("POST", `${FS_ROOT}:runQuery`, {
      token: ADMIN.token,
      body: { structuredQuery: {
        from: [{ collectionId }],
        where: { fieldFilter: { field: { fieldPath: field }, op: "IN", value: { arrayValue: { values: chunk.map(value) } } } },
        select: { fields: [{ fieldPath: "__name__" }] },
      } },
    });
    if (r.status !== 200) throw new Error(`finding ${collectionId} by ${field}: HTTP ${r.status} ${JSON.stringify(r.json).slice(0, 200)}`);
    names.push(...(Array.isArray(r.json) ? r.json : []).filter((row) => row.document).map((row) => row.document.name));
  }
  return names;
}

/** The ledger entries the triggers wrote since the run began. */
async function namesSince(collectionId, field, iso) {
  const r = await http("POST", `${FS_ROOT}:runQuery`, {
    token: ADMIN.token,
    body: { structuredQuery: {
      from: [{ collectionId }],
      where: { fieldFilter: { field: { fieldPath: field }, op: "GREATER_THAN_OR_EQUAL", value: { timestampValue: iso } } },
      select: { fields: [{ fieldPath: "__name__" }] },
    } },
  });
  if (r.status !== 200) throw new Error(`finding ${collectionId} since ${iso}: HTTP ${r.status}`);
  return (Array.isArray(r.json) ? r.json : []).filter((row) => row.document).map((row) => row.document.name);
}

/** A document and everything under it, deepest first. */
async function treeNames(path) {
  const names = [];
  const listed = await http("POST", `${FS_ROOT}/${path}:listCollectionIds`, { token: ADMIN.token, body: { pageSize: 300 } });
  for (const collectionId of listed.json?.collectionIds ?? []) {
    let pageToken = "";
    do {
      const r = await http("GET", `${FS_ROOT}/${path}/${collectionId}?pageSize=300&showMissing=true&mask.fieldPaths=__name__${pageToken ? `&pageToken=${pageToken}` : ""}`, { token: ADMIN.token });
      const docs = r.json?.documents ?? [];
      for (const name of (await pooled(docs, 10, (d) => treeNames(d.name.split("/documents/")[1]))).flat()) names.push(name);
      pageToken = r.json?.nextPageToken ?? "";
    } while (pageToken);
  }
  names.push(`${DOCS}/${path}`);
  return names;
}

/** The accounts whose emails carry this run's tag. */
async function accountsTagged() {
  const found = [];
  for (let offset = 0; ; offset += 500) {
    // The emulator lists them all at once and refuses a page size.
    const body = CLOUD ? { returnUserInfo: true, limit: "500", offset: String(offset) } : { returnUserInfo: true };
    const r = await http("POST", `${AUTH_BASE}/projects/${PROJECT}/accounts:query`, { token: ADMIN.token, body });
    if (r.status !== 200) throw new Error(`listing accounts: HTTP ${r.status} ${JSON.stringify(r.json).slice(0, 200)}`);
    const page = r.json?.userInfo ?? [];
    found.push(...page.filter((u) => String(u.email ?? "").startsWith(`${TAG}-`)).map((u) => u.localId));
    if (!CLOUD || page.length < 500) return found;
  }
}

/** The document, or anything under it. */
async function stillThere(path) {
  if (await adminGet(path)) return true;
  const r = await http("POST", `${FS_ROOT}/${path}:listCollectionIds`, { token: ADMIN.token, body: { pageSize: 10 } });
  return (r.json?.collectionIds ?? []).length > 0;
}

async function deleteAll(names) {
  const unique = [...new Set(names)];
  for (let i = 0; i < unique.length; i += 400) {
    const r = await http("POST", `${FS_ROOT}:commit`, { token: ADMIN.token, body: { writes: unique.slice(i, i + 400).map((name) => ({ delete: name })) } });
    if (r.status !== 200) throw new Error(`deleting: HTTP ${r.status} ${JSON.stringify(r.json).slice(0, 200)}`);
  }
  return unique.length;
}

/** Everything the run made, by what it recorded and by whose it is, then its accounts; and a check that none of it is left. */
async function cleanup() {
  console.log("\ncleaning up what this run made:");
  // Recorded, and found by this run's tag: an account made just before a
  // stop is not always recorded.
  const uids = [...new Set([...made.users.map((u) => u.uid), ...(await accountsTagged())])];
  const roots = [
    ...made.posts.map((id) => `posts/${id}`), ...made.pets.map((id) => `pets/${id}`),
    ...made.meetups.map((id) => `meetups/${id}`), ...made.codes.map((code) => `invitationCodes/${code}`),
    ...made.places.map((id) => `locations/${id}`), ...uids.map((uid) => `users/${uid}`),
  ];
  const byOwner = async () => [
    ...(await namesWhereIn("usernames", "userId", uids)),
    ...(await namesWhereIn("notifications", "userId", uids)),
    ...(await namesWhereIn("notifications", "fromUserId", uids)),
    ...(await namesWhereIn("callableRateLimits", "userId", [...uids, "anon_everyone"])),
    ...(await namesSince("processedEvents", "processedAt", made.startedAt)),
  ];
  let deleted = await deleteAll([...(await pooled(roots, 10, treeNames)).flat(), ...(await byOwner())]);
  // The deletes set the triggers off, and they write their ledger entries
  // after: swept until a pass finds nothing new.
  for (let pass = 0; pass < 6; pass += 1) {
    await sleep(CLOUD ? 20_000 : 3_000);
    const late = [...(await pooled(roots, 10, async (path) => ((await stillThere(path)) ? treeNames(path) : []))).flat(), ...(await byOwner())];
    if (!late.length) break;
    deleted += await deleteAll(late);
  }
  console.log(`  ${deleted} documents deleted`);
  for (let i = 0; i < uids.length; i += 500) {
    const r = await http("POST", `${AUTH_BASE}/projects/${PROJECT}/accounts:batchDelete`, {
      token: ADMIN.token, body: { localIds: uids.slice(i, i + 500), force: true },
    });
    if (r.status !== 200 || r.json?.errors?.length) throw new Error(`deleting accounts: HTTP ${r.status} ${JSON.stringify(r.json?.errors ?? r.json).slice(0, 200)}`);
  }
  console.log(`  ${uids.length} accounts deleted`);

  const leftRoots = (await pooled(roots, 10, async (path) => ((await adminGet(path)) ? path : null))).filter(Boolean);
  const leftUnder = (await pooled(roots, 10, async (path) => {
    const r = await http("POST", `${FS_ROOT}/${path}:listCollectionIds`, { token: ADMIN.token, body: { pageSize: 10 } });
    return (r.json?.collectionIds ?? []).length ? path : null;
  })).filter(Boolean);
  const leftOwned = await byOwner();
  const leftAccounts = (await accountsTagged()).length;
  check("cleanup: nothing the run made is left", !leftRoots.length && !leftUnder.length && !leftOwned.length && !leftAccounts,
    `${leftRoots.length} documents, ${leftUnder.length} with something under them, ${leftOwned.length} found by owner, ${leftAccounts} accounts`);
}

/** When a count comes out short: the documents it counts, how many say they were counted, and the triggers' ledger. */
async function whySoFew(parent, collectionId, shown) {
  const docs = await adminQuery(parent, collectionId);
  const counted = docs.filter((d) => d.counted === true).length;
  const ledger = (await namesSince("processedEvents", "processedAt", made.startedAt)).length;
  console.log(`         ${collectionId}: ${docs.length} documents, ${counted} marked counted, ${docs.length - counted} not; the post shows ${shown}; ${ledger} ledger entries since the run began`);
  const late = docs.filter((d) => d.counted !== true).slice(0, 3).map((d) => d.id);
  if (late.length) console.log(`         not counted, for instance: ${late.join(", ")}`);
}

/* ---------------------------------------------------------- scenarios --- */

async function scenarios() {
  console.log(`project ${PROJECT} · run ${TAG} · ${N} people · ${PARALLEL ? `at most ${PARALLEL} requests at once` : "everything at once"}\n`);

  // --- Accounts: everyone signs up at once, verifies, makes a profile.
  let users;
  if (process.env.SIM_ADMIN_ACCOUNTS === "1") {
    // Fifty at a time: making accounts is not what is being tested, and
    // hundreds of new connections at once from one machine drop some.
    const accounts = await pooled(Array.from({ length: N }, (_, i) => i), 50, async (i) => {
      const account = await adminCreate(`${TAG}-${i}@petnote.test`);
      made.users.push(account);
      return account;
    });
    users = await pooled(accounts, 50, (a) => timed("sign in", () => signInTimed(a.email)));
    check("accounts: everyone signs in at once (accounts made by the admin API)", users.length === N, `${users.length} of ${N}`);
  } else {
    users = await Promise.all(Array.from({ length: N }, async (_, i) => {
      const user = await signUp(`${TAG}-${i}@petnote.test`);
      made.users.push(user);
      return user;
    }));
    check("accounts: everyone signs up at once", users.length === N, `${users.length} of ${N}`);
    users = await Promise.all(users.map(verifyEmail));
  }
  const profiles = await Promise.all(users.map((u, i) =>
    call(u, "ensureUserProfileCallable", { displayName: `Sim ${TAG.slice(-5)} ${i}`, onboardingComplete: true })));
  const p = tally(profiles);
  check("accounts: everyone makes a profile at once", p.ok === N, `${p.ok} ok, ${p.refused} refused ${p.codes}`);
  const userDocs = await Promise.all(users.map((u) => adminGet(`users/${u.uid}`)));
  check("accounts: one profile each on the server", userDocs.filter(Boolean).length === N, `${userDocs.filter(Boolean).length} of ${N}`);

  // --- Pets: everyone adds a pet at once.
  const petCalls = await Promise.all(users.map((u, i) =>
    call(u, "createPetCallable", { name: `Simpet ${i}`, species: i % 2 ? "cat" : "dog", relationship: "mom" })));
  const pc = tally(petCalls);
  check("pets: everyone adds a pet at once", pc.ok === N, `${pc.ok} ok, ${pc.refused} refused ${pc.codes} ${petCalls.find((c) => !c.ok)?.message ?? ""}`);
  const petIds = petCalls.map((c) => c.result?.petId ?? c.result?.id);
  made.pets.push(...petIds.filter(Boolean));
  if (petIds.some((id) => !id)) throw new Error(`a pet came back without an id: ${JSON.stringify(petCalls[0].result)}`);
  const families = await Promise.all(petIds.map((id) => adminQuery(`pets/${id}`, "family")));
  check("pets: each pet's family is its owner alone", families.every((f) => f.length === 1), `${families.filter((f) => f.length === 1).length} of ${N}`);

  if (want("follows")) {
    // --- Follows: everyone else follows the first pet at once; its owner may not.
    const star = petIds[0];
    const follows = await Promise.all(users.slice(1).map((u) => call(u, "followPetCallable", { petId: star })));
    const fl = tally(follows);
    check("follows: everyone else follows one pet at once", fl.ok === N - 1, `${fl.ok} ok, ${fl.refused} refused ${fl.codes}`);
    const ownFollow = await call(users[0], "followPetCallable", { petId: star });
    check("follows: the owner cannot follow their own pet", !ownFollow.ok, ownFollow.ok ? "SUCCEEDED" : `refused ${ownFollow.code}`);
    const twice = await Promise.all([call(users[1], "followPetCallable", { petId: star }), call(users[1], "followPetCallable", { petId: star })]);
    let starDoc = await settle(() => adminGet(`pets/${star}`), (d) => d?.followerCount === N - 1);
    check("follows: the count is exactly everyone else, a double follow once", starDoc?.followerCount === N - 1,
      `followerCount ${starDoc?.followerCount}, expected ${N - 1} (repeat follows: ${twice.map((t) => (t.ok ? "ok" : t.code)).join("/")})`);
    const leaving = users.slice(1, 1 + Math.floor((N - 1) / 2));
    const unfollows = await Promise.all(leaving.map((u) => call(u, "unfollowPetCallable", { petId: star })));
    const expectedFollowers = N - 1 - leaving.length;
    starDoc = await settle(() => adminGet(`pets/${star}`), (d) => d?.followerCount === expectedFollowers);
    check("follows: half unfollow at once, the count follows", starDoc?.followerCount === expectedFollowers,
      `${tally(unfollows).ok} unfollowed; followerCount ${starDoc?.followerCount}, expected ${expectedFollowers}`);
  }

  // --- Posts: everyone posts twice at once; one person sends the same post twice.
  const postCalls = await Promise.all(users.flatMap((u, i) => [0, 1].map((k) =>
    call(u, "createPostCallable", { text: `TEST CONTENT ${TAG} post ${i}.${k}`, petId: petIds[i], operationId: `${TAG}-${i}-${k}`, media: [] }))));
  const pp = tally(postCalls);
  made.posts.push(...postCalls.map((c) => c.result?.postId ?? c.result?.id).filter(Boolean));
  check("posts: everyone posts twice at once", pp.ok === 2 * N, `${pp.ok} ok, ${pp.refused} refused ${pp.codes} ${postCalls.find((c) => !c.ok)?.message ?? ""}`);
  const dupOp = `${TAG}-dup`;
  const dup = await Promise.all([0, 1, 2].map(() =>
    call(users[2], "createPostCallable", { text: `TEST CONTENT ${TAG} sent three times`, petId: petIds[2], operationId: dupOp, media: [] })));
  const dupPosts = await adminQuery(null, "posts", { where: ["operationId", dupOp] });
  made.posts.push(...dupPosts.map((d) => d.id));
  check("posts: one post sent three times at once makes one", dupPosts.length === 1,
    `${dupPosts.length} post(s); answers ${dup.map((d) => (d.ok ? "ok" : d.code)).join("/")}`);
  const pet2 = await settle(() => adminGet(`pets/${petIds[2]}`), (d) => d?.postCount === 3);
  check("posts: that pet's post count is 3, not 5", pet2?.postCount === 3, `postCount ${pet2?.postCount}`);
  // The post everyone likes and comments on.
  const target = postCalls[0].result?.postId ?? postCalls[0].result?.id;
  if (!target) throw new Error(`a post came back without an id: ${JSON.stringify(postCalls[0].result)}`);

  // Not the pet sent three times (2), nor the one everyone follows (0).
  const otherPet = petIds[N > 5 ? 5 : 1];
  const pet5 = await settle(() => adminGet(`pets/${otherPet}`), (d) => d?.postCount === 2);
  check("posts: another pet's post count is 2", pet5?.postCount === 2, `postCount ${pet5?.postCount}`);

  if (want("likes")) {
    // --- Likes: everyone likes one post at once, the way the app writes a like.
    const likeWrite = (u) => clientCreate(u, `posts/${target}/likes/${u.uid}`, { userId: u.uid, postId: target, counted: false }, { stamp: "createdAt" });
    const likes = await Promise.all(users.map(likeWrite));
    check("likes: everyone likes one post at once", likes.every((r) => r.status === 200), `${likes.filter((r) => r.status === 200).length} of ${N} written`);
    const again = await Promise.all([likeWrite(users[3]), likeWrite(users[3])]);
    check("likes: a second like by the same person is refused", again.every((r) => r.status !== 200), `HTTP ${again.map((r) => r.status).join("/")}`);
    let post = await settle(() => adminGet(`posts/${target}`), (d) => d?.likeCount === N);
    check("likes: the count is exactly everyone", post?.likeCount === N, `likeCount ${post?.likeCount}, expected ${N}`);
    if (post?.likeCount !== N) await whySoFew(`posts/${target}`, "likes", post?.likeCount);
    const unliking = users.slice(0, Math.min(20, N));
    await Promise.all(unliking.map((u) => clientDelete(u, `posts/${target}/likes/${u.uid}`)));
    post = await settle(() => adminGet(`posts/${target}`), (d) => d?.likeCount === N - unliking.length);
    check("likes: twenty take theirs back at once", post?.likeCount === N - unliking.length, `likeCount ${post?.likeCount}, expected ${N - unliking.length}`);
  }

  if (want("comments")) {
    // --- Comments: everyone comments on one post at once; some delete theirs.
    const comments = await Promise.all(users.map((u, i) => call(u, "createCommentCallable", { postId: target, text: `TEST CONTENT ${TAG} comment ${i}` })));
    const cc = tally(comments);
    check("comments: everyone comments on one post at once", cc.ok === N, `${cc.ok} ok, ${cc.refused} refused ${cc.codes}`);
    let post = await settle(() => adminGet(`posts/${target}`), (d) => d?.commentCount === N);
    check("comments: the count is exactly everyone", post?.commentCount === N, `commentCount ${post?.commentCount}, expected ${N}`);
    if (post?.commentCount !== N) await whySoFew(`posts/${target}`, "comments", post?.commentCount);
    const deleting = comments.slice(0, Math.min(10, N)).map((c, i) => ({ user: users[i], id: c.result?.commentId ?? c.result?.id }));
    const dels = await Promise.all(deleting.map((d) => call(d.user, "deleteCommentCallable", { postId: target, commentId: d.id })));
    post = await settle(() => adminGet(`posts/${target}`), (d) => d?.commentCount === N - deleting.length);
    check("comments: ten delete theirs at once", post?.commentCount === N - deleting.length,
      `${tally(dels).ok} deleted; commentCount ${post?.commentCount}, expected ${N - deleting.length}`);
  }

  if (want("meetup")) {
    // --- A meetup for twenty: everyone else tries to join at once.
    const CAP = Math.min(20, N - 1);
    const meetupCall = await call(users[0], "createMeetupCallable", {
      title: `TEST CONTENT ${TAG} meetup`, description: "TEST CONTENT twenty at most",
      dateMillis: Date.now() + 3 * 86_400_000, duration: 60,
      location: { kind: "address", address: "1 Sim St, Medford, MA", label: "" },
      locationVisibility: "everyone",
      requirements: { petType: "any", dogSize: "any", maxPets: CAP, mustHavePosts: false, mustHavePetProfile: false, minFollowers: 0, additionalNotes: "" },
      organizerPetId: petIds[0],
    });
    check("meetup: one is created", meetupCall.ok, meetupCall.ok ? "ok" : `refused ${meetupCall.code}: ${meetupCall.message}`);
    const meetupId = meetupCall.result?.meetupId ?? meetupCall.result?.id;
    if (meetupId) made.meetups.push(meetupId);
    const startCount = (await adminGet(`meetups/${meetupId}`))?.participantCount ?? 0;
    const joins = await Promise.all(users.slice(1).map((u, i) => call(u, "joinMeetupCallable", { meetupId, petId: petIds[i + 1] })));
    const joined = joins.filter((j) => j.ok && j.result?.success !== false).length;
    let meetup = await settle(() => adminGet(`meetups/${meetupId}`), (d) => (d?.participantCount ?? 0) >= Math.min(CAP, startCount + joined));
    const roster = await adminQuery(`meetups/${meetupId}`, "participants");
    check("meetup: no more than room for, however many try at once",
      meetup?.participantCount <= CAP && roster.length <= CAP && meetup?.participantCount === roster.length,
      `${joined} joined of ${N - 1}; participantCount ${meetup?.participantCount}, ${roster.length} on the roster, room for ${CAP}`);
    check("meetup: and it fills up", meetup?.participantCount === CAP, `participantCount ${meetup?.participantCount}, room for ${CAP}`);
    // Everyone who did not get a place should hear that it is full, the way
    // the app tells them, and not get an error because the crowd collided.
    const toldFull = joins.filter((j) => j.ok && j.result?.success === false);
    const failed = tally(joins);
    check("meetup: the ones left out are told it is full, not given an error",
      failed.refused === 0,
      `${toldFull.length} told "${toldFull[0]?.result?.error ?? "-"}"; ${failed.refused} errors${failed.codes ? ` (${failed.codes})` : ""}`);
    if (CLOUD) {
      skip("meetup: five leave at once, the count follows", "the test project has no onParticipantDeleted");
      skip("meetup: the freed places go to the next ones, and no more", "the test project has no onParticipantDeleted");
    } else {
      const leavers = roster.filter((r) => r.id !== users[0].uid).slice(0, 5);
      const byUid = new Map(users.map((u) => [u.uid, u]));
      await Promise.all(leavers.map((r) => clientDelete(byUid.get(r.id), `meetups/${meetupId}/participants/${r.id}`)));
      meetup = await settle(() => adminGet(`meetups/${meetupId}`), (d) => d?.participantCount === CAP - leavers.length);
      check("meetup: five leave at once, the count follows", meetup?.participantCount === CAP - leavers.length,
        `participantCount ${meetup?.participantCount}, expected ${CAP - leavers.length}`);
      const onRoster = new Set((await adminQuery(`meetups/${meetupId}`, "participants")).map((r) => r.id));
      const outside = users.filter((u) => !onRoster.has(u.uid));
      const rejoin = await Promise.all(outside.map((u) => call(u, "joinMeetupCallable", { meetupId, petId: petIds[users.indexOf(u)] })));
      meetup = await settle(() => adminGet(`meetups/${meetupId}`), (d) => d?.participantCount === CAP);
      check("meetup: the freed places go to the next ones, and no more",
        meetup?.participantCount === CAP,
        `${rejoin.filter((j) => j.ok && j.result?.success !== false).length} got in of ${outside.length}; participantCount ${meetup?.participantCount}, room for ${CAP}`);
    }
  }

  if (want("invitation")) {
    // --- One invitation, five people redeeming it at once.
    const invite = await call(users[0], "createInvitationCallable", { petId: petIds[0] });
    const code = invite.result?.code;
    if (code) made.codes.push(code);
    check("invitation: one is made", Boolean(code), code ? "ok" : `refused ${invite.code}: ${invite.message}`);
    const redeemers = users.slice(1, 6);
    const redeems = await Promise.all(redeemers.map((u) => call(u, "redeemInvitationCallable", { code, relationship: "other" })));
    const family = await adminQuery(`pets/${petIds[0]}`, "family");
    check("invitation: one code redeemed by five at once lets in exactly one",
      redeems.filter((r) => r.ok).length === 1 && family.length === 2,
      `${redeems.filter((r) => r.ok).length} redeemed (${tally(redeems).codes}); ${family.length} in the family`);
  }

  if (want("places")) {
    if (CLOUD) {
      skip("check-ins and reviews at one place", "the test project has no media account to vouch for a photo, and no review functions");
    } else {
      // --- One place: everyone checks in and rates it at once.
      const placeId = `${TAG}-place`;
      made.places.push(placeId);
      await http("PATCH", `${FS_ROOT}/locations/${placeId}`, {
        token: ADMIN.token,
        body: { fields: { name: value(`TEST CONTENT ${TAG} park`), category: value("dog_park"), lat: value(42.39), lng: value(-71.1) } },
      });
      const photo = (i) => `https://res.cloudinary.com/dgeunvmmn/image/upload/v1/petnote/sim/${TAG}-${i}.jpg`;
      const checkins = await Promise.all(users.map((u, i) => call(u, "checkInCallable", { locationId: placeId, photoUrl: photo(i), petId: petIds[i] })));
      const ck = tally(checkins);
      check("check-ins: everyone checks in at one place at once", ck.ok === N, `${ck.ok} ok, ${ck.refused} refused ${ck.codes} ${checkins.find((c) => !c.ok)?.message ?? ""}`);
      const again2 = await call(users[4], "checkInCallable", { locationId: placeId, photoUrl: photo(4), petId: petIds[4] });
      check("check-ins: a second one the same day is refused", !again2.ok, again2.ok ? "SUCCEEDED" : `refused ${again2.code}`);
      let place = await settle(() => adminGet(`locations/${placeId}`), (d) => d?.totalCheckins === N);
      check("check-ins: the count is exactly everyone", place?.totalCheckins === N && place?.verifiedByCheckins === true,
        `totalCheckins ${place?.totalCheckins}, expected ${N}; verified ${place?.verifiedByCheckins}`);
      const ratings = users.map((_, i) => 1 + (i % 5));
      const reviews = await Promise.all(users.map((u, i) => call(u, "submitReviewCallable", {
        locationId: placeId, rating: ratings[i], petFriendly: { space: ratings[i], safety: ratings[i], cleanliness: ratings[i] },
      })));
      const rv = tally(reviews);
      check("reviews: everyone rates one place at once", rv.ok === N, `${rv.ok} ok, ${rv.refused} refused ${rv.codes} ${reviews.find((c) => !c.ok)?.message ?? ""}`);
      const mean = ratings.reduce((a, b) => a + b, 0) / N;
      place = await settle(() => adminGet(`locations/${placeId}`), (d) => d?.totalRatings === N);
      check("reviews: the count and the average are exactly right",
        place?.totalRatings === N && Math.abs((place?.averageRating ?? 0) - mean) < 0.01,
        `totalRatings ${place?.totalRatings}, expected ${N}; averageRating ${place?.averageRating}, expected ${mean.toFixed(2)}`);
    }
  }

  if (want("visitors")) {
    // --- Visitors who are not signed in share one budget: many of them at once
    // must all be answered, well inside it.
    const VISITORS = Math.min(30, 120);
    const visits = await Promise.all(Array.from({ length: VISITORS }, () =>
      call(null, "getPetCheckinsCallable", { petId: petIds[0], limitCount: 5 })));
    const vs = tally(visits);
    check(`visitors: ${VISITORS} not signed in open a pet's check-ins at once`, vs.ok === VISITORS,
      `${vs.ok} answered, ${vs.refused} refused ${vs.codes} ${visits.find((v) => !v.ok)?.message ?? ""}`);
  }

  if (want("ratelimit")) {
    // --- The rate limit holds when one person fires many at once.
    const burst = await Promise.all(Array.from({ length: 40 }, (_, k) =>
      call(users[N - 1], "createCommentCallable", { postId: target, text: `TEST CONTENT ${TAG} burst ${k}` })));
    const bt = tally(burst);
    // No more than the limit, however they arrive. Fewer is possible: the
    // emulator's transactions queue far longer than the cloud's, and one that
    // waits too long is aborted.
    check("rate limit: forty comments at once from one person, never more than thirty",
      bt.ok <= 30, `${bt.ok} ok, ${bt.refused} refused ${bt.codes}`);
  }
}

async function main() {
  let stopped = null;
  try {
    await scenarios();
  } catch (error) {
    stopped = error;
    console.error(`stopped: ${error.stack ?? error}`);
  }
  if (CLEANUP) {
    try {
      await cleanup();
    } catch (error) {
      check("cleanup: nothing the run made is left", false, `the cleanup stopped: ${error.message ?? error}`);
    }
  }

  /* ------------------------------------------------------------ report --- */
  console.log("\nhow long each kind of request took (ms):");
  for (const [kind, list] of [...timings.entries()].sort()) {
    const s = [...list].sort((a, b) => a - b);
    const at = (q) => s[Math.min(s.length - 1, Math.floor(q * s.length))].toFixed(0);
    console.log(`  ${kind.padEnd(34)} n=${String(s.length).padStart(4)}  p50 ${at(0.5).padStart(6)}  p95 ${at(0.95).padStart(6)}  max ${s[s.length - 1].toFixed(0).padStart(6)}`);
  }
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length} of ${results.length} checks passed${skipped.length ? `, ${skipped.length} skipped` : ""}${stopped ? "; the scenarios stopped early" : ""}`);
  process.exit(failed.length || stopped ? 1 : 0);
}

main().catch((error) => {
  console.error(`stopped: ${error.stack ?? error}`);
  process.exit(1);
});
