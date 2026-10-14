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
 * Usage (local emulators, with the functions emulator so the triggers run):
 *
 *   firebase emulators:exec --config firebase.scenarios.json \
 *     --only auth,firestore,functions --project petnote-test \
 *     "node functions/scripts/scenario-many-users.mjs"
 *
 *   SIM_USERS     how many people (default 50)
 *   SIM_PARALLEL  at most this many requests in flight (default: no limit).
 *                 The emulator's transactions lock far more than the cloud's
 *                 (a query inside one locks the whole collection), so many
 *                 at once time out there that would not in the cloud; a run
 *                 for the counts at scale uses about 6.
 *
 * Only petnote-test, the emulator. Production is refused by name; the cloud
 * test project is not wired in yet.
 *
 * Exit code 0 only if every check passed.
 */

const PRODUCTION_PROJECT = "petnote-a9dac";
const PROJECT = process.env.PETNOTE_PROJECT || process.env.GCLOUD_PROJECT || "petnote-test";
if (PROJECT.includes(PRODUCTION_PROJECT) || PROJECT !== "petnote-test") {
  console.error(`Refusing to run against "${PROJECT}". Only petnote-test, the emulator. Never ${PRODUCTION_PROJECT}.`);
  process.exit(2);
}
const AUTH_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST || "127.0.0.1:9299";
const FS_HOST = process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8288";
const FN_HOST = process.env.FUNCTIONS_EMULATOR_HOST || "127.0.0.1:5301";
for (const host of [AUTH_HOST, FS_HOST, FN_HOST]) {
  if (!/^(127\.0\.0\.1|localhost):\d+$/.test(host)) {
    console.error(`Refusing a non-local host: ${host}`);
    process.exit(2);
  }
}
const REGION = "us-central1";
const AUTH_BASE = `http://${AUTH_HOST}/identitytoolkit.googleapis.com/v1`;
const DOCS = `projects/${PROJECT}/databases/(default)/documents`;
const FS_ROOT = `http://${FS_HOST}/v1/${DOCS}`;
const FN_BASE = `http://${FN_HOST}/${PROJECT}/${REGION}`;
const API_KEY = "emulator";
const PASSWORD = "Sim-passw0rd!";
const N = Number(process.env.SIM_USERS || 50);
const TAG = `sim${Date.now().toString(36)}`;
const TIMEOUT_MS = 120_000;
// The emulator's admin token: reads past the rules, for the checks only.
const ADMIN = { token: "owner" };

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
  await slot();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  const started = performance.now();
  try {
    const res = await fetch(url, { method, headers, body: body ? JSON.stringify(body) : undefined, signal: controller.signal });
    const text = await res.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { json = { raw: text.slice(0, 200) }; }
    return { status: res.status, json, ms: performance.now() - started };
  } finally {
    clearTimeout(timer);
    release();
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

async function signIn(email) {
  const r = await http("POST", `${AUTH_BASE}/accounts:signInWithPassword?key=${API_KEY}`, {
    body: { email, password: PASSWORD, returnSecureToken: true },
  });
  if (r.status !== 200) throw new Error(`sign-in failed for ${email}: HTTP ${r.status}`);
  return { token: r.json.idToken, uid: r.json.localId, email };
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
async function settle(read, done, { timeout = 60_000, every = 500 } = {}) {
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
const tally = (outcomes) => ({
  ok: outcomes.filter((o) => o.ok).length,
  refused: outcomes.filter((o) => !o.ok).length,
  codes: [...new Set(outcomes.filter((o) => !o.ok).map((o) => o.code))].join(","),
});

/* ---------------------------------------------------------- scenarios --- */

async function main() {
  console.log(`project ${PROJECT} · run ${TAG} · ${N} people · ${PARALLEL ? `at most ${PARALLEL} requests at once` : "everything at once"}\n`);

  // --- Accounts: everyone signs up at once, verifies, makes a profile.
  let users = await Promise.all(Array.from({ length: N }, (_, i) => signUp(`${TAG}-${i}@petnote.test`)));
  check("accounts: everyone signs up at once", users.length === N, `${users.length} of ${N}`);
  users = await Promise.all(users.map(verifyEmail));
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
  if (petIds.some((id) => !id)) throw new Error(`a pet came back without an id: ${JSON.stringify(petCalls[0].result)}`);
  const families = await Promise.all(petIds.map((id) => adminQuery(`pets/${id}`, "family")));
  check("pets: each pet's family is its owner alone", families.every((f) => f.length === 1), `${families.filter((f) => f.length === 1).length} of ${N}`);

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

  // --- Posts: everyone posts twice at once; one person sends the same post twice.
  const postCalls = await Promise.all(users.flatMap((u, i) => [0, 1].map((k) =>
    call(u, "createPostCallable", { text: `TEST CONTENT ${TAG} post ${i}.${k}`, petId: petIds[i], operationId: `${TAG}-${i}-${k}`, media: [] }))));
  const pp = tally(postCalls);
  check("posts: everyone posts twice at once", pp.ok === 2 * N, `${pp.ok} ok, ${pp.refused} refused ${pp.codes} ${postCalls.find((c) => !c.ok)?.message ?? ""}`);
  const dupOp = `${TAG}-dup`;
  const dup = await Promise.all([0, 1, 2].map(() =>
    call(users[2], "createPostCallable", { text: `TEST CONTENT ${TAG} sent three times`, petId: petIds[2], operationId: dupOp, media: [] })));
  const dupPosts = await adminQuery(null, "posts", { where: ["operationId", dupOp] });
  check("posts: one post sent three times at once makes one", dupPosts.length === 1,
    `${dupPosts.length} post(s); answers ${dup.map((d) => (d.ok ? "ok" : d.code)).join("/")}`);
  const pet2 = await settle(() => adminGet(`pets/${petIds[2]}`), (d) => d?.postCount === 3);
  check("posts: that pet's post count is 3, not 5", pet2?.postCount === 3, `postCount ${pet2?.postCount}`);
  const pet5 = await settle(() => adminGet(`pets/${petIds[5]}`), (d) => d?.postCount === 2);
  check("posts: another pet's post count is 2", pet5?.postCount === 2, `postCount ${pet5?.postCount}`);

  // --- Likes: everyone likes one post at once, the way the app writes a like.
  const target = postCalls[0].result?.postId ?? postCalls[0].result?.id;
  if (!target) throw new Error(`a post came back without an id: ${JSON.stringify(postCalls[0].result)}`);
  const likeWrite = (u) => clientCreate(u, `posts/${target}/likes/${u.uid}`, { userId: u.uid, postId: target, counted: false }, { stamp: "createdAt" });
  const likes = await Promise.all(users.map(likeWrite));
  check("likes: everyone likes one post at once", likes.every((r) => r.status === 200), `${likes.filter((r) => r.status === 200).length} of ${N} written`);
  const again = await Promise.all([likeWrite(users[3]), likeWrite(users[3])]);
  check("likes: a second like by the same person is refused", again.every((r) => r.status !== 200), `HTTP ${again.map((r) => r.status).join("/")}`);
  let post = await settle(() => adminGet(`posts/${target}`), (d) => d?.likeCount === N);
  check("likes: the count is exactly everyone", post?.likeCount === N, `likeCount ${post?.likeCount}, expected ${N}`);
  const unliking = users.slice(0, Math.min(20, N));
  await Promise.all(unliking.map((u) => clientDelete(u, `posts/${target}/likes/${u.uid}`)));
  post = await settle(() => adminGet(`posts/${target}`), (d) => d?.likeCount === N - unliking.length);
  check("likes: twenty take theirs back at once", post?.likeCount === N - unliking.length, `likeCount ${post?.likeCount}, expected ${N - unliking.length}`);

  // --- Comments: everyone comments on one post at once; some delete theirs.
  const comments = await Promise.all(users.map((u, i) => call(u, "createCommentCallable", { postId: target, text: `TEST CONTENT ${TAG} comment ${i}` })));
  const cc = tally(comments);
  check("comments: everyone comments on one post at once", cc.ok === N, `${cc.ok} ok, ${cc.refused} refused ${cc.codes}`);
  post = await settle(() => adminGet(`posts/${target}`), (d) => d?.commentCount === N);
  check("comments: the count is exactly everyone", post?.commentCount === N, `commentCount ${post?.commentCount}, expected ${N}`);
  const deleting = comments.slice(0, Math.min(10, N)).map((c, i) => ({ user: users[i], id: c.result?.commentId ?? c.result?.id }));
  const dels = await Promise.all(deleting.map((d) => call(d.user, "deleteCommentCallable", { postId: target, commentId: d.id })));
  post = await settle(() => adminGet(`posts/${target}`), (d) => d?.commentCount === N - deleting.length);
  check("comments: ten delete theirs at once", post?.commentCount === N - deleting.length,
    `${tally(dels).ok} deleted; commentCount ${post?.commentCount}, expected ${N - deleting.length}`);

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
  const startCount = (await adminGet(`meetups/${meetupId}`))?.participantCount ?? 0;
  const joins = await Promise.all(users.slice(1).map((u, i) => call(u, "joinMeetupCallable", { meetupId, petId: petIds[i + 1] })));
  const joined = joins.filter((j) => j.ok && j.result?.success !== false).length;
  let meetup = await settle(() => adminGet(`meetups/${meetupId}`), (d) => (d?.participantCount ?? 0) >= Math.min(CAP, startCount + joined));
  const roster = await adminQuery(`meetups/${meetupId}`, "participants");
  check("meetup: no more than room for, however many try at once",
    meetup?.participantCount <= CAP && roster.length <= CAP && meetup?.participantCount === roster.length,
    `${joined} joined of ${N - 1}; participantCount ${meetup?.participantCount}, ${roster.length} on the roster, room for ${CAP}`);
  check("meetup: and it fills up", meetup?.participantCount === CAP, `participantCount ${meetup?.participantCount}, room for ${CAP}`);
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

  // --- One invitation, five people redeeming it at once.
  const invite = await call(users[0], "createInvitationCallable", { petId: petIds[0] });
  const code = invite.result?.code;
  check("invitation: one is made", Boolean(code), code ? "ok" : `refused ${invite.code}: ${invite.message}`);
  const redeemers = users.slice(1, 6);
  const redeems = await Promise.all(redeemers.map((u) => call(u, "redeemInvitationCallable", { code, relationship: "other" })));
  const family = await adminQuery(`pets/${petIds[0]}`, "family");
  check("invitation: one code redeemed by five at once lets in exactly one",
    redeems.filter((r) => r.ok).length === 1 && family.length === 2,
    `${redeems.filter((r) => r.ok).length} redeemed (${tally(redeems).codes}); ${family.length} in the family`);

  // --- One place: everyone checks in and rates it at once.
  const placeId = `${TAG}-place`;
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

  // --- Visitors who are not signed in share one budget: many of them at once
  // must all be answered, well inside it.
  const VISITORS = Math.min(30, 120);
  const visits = await Promise.all(Array.from({ length: VISITORS }, () =>
    call(null, "getPetCheckinsCallable", { petId: petIds[0], limitCount: 5 })));
  const vs = tally(visits);
  check(`visitors: ${VISITORS} not signed in open a pet's check-ins at once`, vs.ok === VISITORS,
    `${vs.ok} answered, ${vs.refused} refused ${vs.codes} ${visits.find((v) => !v.ok)?.message ?? ""}`);

  // --- The rate limit holds when one person fires many at once.
  const burst = await Promise.all(Array.from({ length: 40 }, (_, k) =>
    call(users[N - 1], "createCommentCallable", { postId: target, text: `TEST CONTENT ${TAG} burst ${k}` })));
  const bt = tally(burst);
  // No more than the limit, however they arrive. Fewer is possible: the
  // emulator's transactions queue far longer than the cloud's, and one that
  // waits too long is aborted.
  check("rate limit: forty comments at once from one person, never more than thirty",
    bt.ok <= 30, `${bt.ok} ok, ${bt.refused} refused ${bt.codes}`);

  /* ------------------------------------------------------------ report --- */
  console.log("\nhow long each kind of request took (ms):");
  for (const [kind, list] of [...timings.entries()].sort()) {
    const s = [...list].sort((a, b) => a - b);
    const at = (q) => s[Math.min(s.length - 1, Math.floor(q * s.length))].toFixed(0);
    console.log(`  ${kind.padEnd(34)} n=${String(s.length).padStart(4)}  p50 ${at(0.5).padStart(6)}  p95 ${at(0.95).padStart(6)}  max ${s[s.length - 1].toFixed(0).padStart(6)}`);
  }
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length} of ${results.length} checks passed`);
  process.exit(failed.length ? 1 : 0);
}

main().catch((error) => {
  console.error(`stopped: ${error.stack ?? error}`);
  process.exit(1);
});
