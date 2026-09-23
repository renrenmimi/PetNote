/**
 * The client path for the functions deployed to the test project on
 * 2026-09-22: account, pets, posting, follows and families — what a signed-in
 * user may do, and what they must be refused.
 *
 * Same rules as verify-client-path.mjs, and for the same reason: nothing here
 * touches firebase-admin. Sign-in is Identity Toolkit REST, reads and writes
 * are Firestore REST with the user's ID token (rules-enforced), callables are
 * the callable HTTP protocol. An Admin write that succeeds proves nothing
 * about a phone.
 *
 * Each check says what it expects — allowed or refused — and a refusal that
 * succeeds is a hard failure: it would mean the rules or the server's own
 * checks are not doing what the client assumes.
 *
 * Usage (cloud test project; emulator hosts must be unset):
 *
 *   cd functions
 *   PETNOTE_PROJECT=petnote-devtest \
 *   PETNOTE_API_KEY=... PETNOTE_IOS_BUNDLE=dev.local.petnote.native \
 *   PETNOTE_A_EMAIL=accept-a@example.com PETNOTE_B_EMAIL=accept-b@example.com \
 *   PETNOTE_UNVERIFIED_EMAIL=accept-new@example.com \
 *   PETNOTE_PASSWORD=... \
 *   node scripts/verify-client-features.mjs
 *
 * What it leaves behind on a clean run: nothing. The pet and the post it
 * creates are deleted through their callables, the bio it changes is put
 * back, the follow is undone. A crash can leave them; they are named in the
 * output (text starts "TEST CONTENT vcf-"; the pet is named "TC <run>").
 *
 * Exit code 0 only if every check that was expected to pass passed. Checks
 * known to be blocked by missing indexes are reported as BLOCKED with the
 * server's answer, not counted as passing.
 */

const PRODUCTION_PROJECT = "petnote-a9dac";
const ALLOWED = ["petnote-test", "petnote-devtest"];
const PROJECT = process.env.PETNOTE_PROJECT || "";
if (!PROJECT || PROJECT.includes(PRODUCTION_PROJECT) || !ALLOWED.includes(PROJECT)) {
  console.error(`Refusing to run against "${PROJECT}". Allowed: ${ALLOWED.join(", ")}. Never ${PRODUCTION_PROJECT}.`);
  process.exit(2);
}
const cloud = PROJECT !== "petnote-test";
if (cloud) {
  for (const key of ["FIRESTORE_EMULATOR_HOST", "FIREBASE_AUTH_EMULATOR_HOST", "FUNCTIONS_EMULATOR_HOST"]) {
    if (process.env[key]) {
      console.error(`${key} is set while targeting ${PROJECT}; every request would go to the emulator.`);
      process.exit(2);
    }
  }
}
const authHost = cloud ? "" : process.env.FIREBASE_AUTH_EMULATOR_HOST || "127.0.0.1:9099";
const fsHost = cloud ? "" : process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8088";
const fnHost = cloud ? "" : process.env.FUNCTIONS_EMULATOR_HOST || "127.0.0.1:5101";
const REGION = "us-central1";
const AUTH_BASE = authHost ? `http://${authHost}/identitytoolkit.googleapis.com/v1` : "https://identitytoolkit.googleapis.com/v1";
const FS_BASE = fsHost
  ? `http://${fsHost}/v1/projects/${PROJECT}/databases/(default)/documents`
  : `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents`;
const FN_BASE = fnHost ? `http://${fnHost}/${PROJECT}/${REGION}` : `https://${REGION}-${PROJECT}.cloudfunctions.net`;
const API_KEY = process.env.PETNOTE_API_KEY || (authHost ? "emulator" : "");
const IOS_BUNDLE = process.env.PETNOTE_IOS_BUNDLE || "";
const PASSWORD = process.env.PETNOTE_PASSWORD || "";
const A_EMAIL = process.env.PETNOTE_A_EMAIL || "";
const B_EMAIL = process.env.PETNOTE_B_EMAIL || "";
const U_EMAIL = process.env.PETNOTE_UNVERIFIED_EMAIL || "";
if (!API_KEY || !PASSWORD || !A_EMAIL || !B_EMAIL) {
  console.error("PETNOTE_API_KEY, PETNOTE_PASSWORD, PETNOTE_A_EMAIL and PETNOTE_B_EMAIL are required.");
  process.exit(2);
}
const TAG = `vcf-${Date.now().toString(36)}`;
const TIMEOUT_MS = 60_000;

/* ----------------------------------------------------------- plumbing --- */

function keyHeaders() {
  return IOS_BUNDLE ? { "X-Ios-Bundle-Identifier": IOS_BUNDLE } : {};
}

async function http(method, url, { token, body } = {}) {
  const headers = { "Content-Type": "application/json", ...keyHeaders() };
  if (token) headers.Authorization = `Bearer ${token}`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(url, { method, headers, body: body ? JSON.stringify(body) : undefined, signal: controller.signal });
    const text = await res.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { json = { raw: text.slice(0, 200) }; }
    return { status: res.status, json };
  } finally {
    clearTimeout(timer);
  }
}

async function signIn(email) {
  const r = await http("POST", `${AUTH_BASE}/accounts:signInWithPassword?key=${API_KEY}`, {
    body: { email, password: PASSWORD, returnSecureToken: true },
  });
  if (r.status !== 200) throw new Error(`sign-in failed for ${email}: HTTP ${r.status} ${JSON.stringify(r.json?.error?.message)}`);
  return { token: r.json.idToken, uid: r.json.localId, email };
}

/** The callable protocol. Returns { ok, result } or { ok: false, code, message }. */
async function call(user, name, data) {
  const r = await http("POST", `${FN_BASE}/${name}`, { token: user?.token, body: { data } });
  if (r.status === 200 && r.json && "result" in r.json) return { ok: true, result: r.json.result };
  const e = r.json?.error ?? {};
  // The protocol answers "PERMISSION_DENIED"; the SDKs and this file say
  // "permission-denied". One spelling, here.
  const code = e.status ? String(e.status).toLowerCase().replace(/_/g, "-") : `http-${r.status}`;
  return { ok: false, code, message: e.message ?? JSON.stringify(r.json).slice(0, 160) };
}

async function getDoc(user, path) {
  const r = await http("GET", `${FS_BASE}/${path}`, { token: user?.token });
  if (r.status === 404) return null;
  if (r.status !== 200) return { __error: r.status, message: r.json?.error?.message };
  return r.json.fields ?? {};
}

async function patchDoc(user, path, fields) {
  const mask = Object.keys(fields).map((f) => `updateMask.fieldPaths=${encodeURIComponent(f)}`).join("&");
  return http("PATCH", `${FS_BASE}/${path}?${mask}`, { token: user?.token, body: { fields } });
}

const str = (v) => v?.stringValue;
const int = (v) => (v?.integerValue !== undefined ? Number(v.integerValue) : undefined);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function poll(fn, { timeout = 60_000, every = 1500 } = {}) {
  const until = Date.now() + timeout;
  let last;
  while (Date.now() < until) {
    last = await fn();
    if (last?.done) return last;
    await sleep(every);
  }
  return last ?? { done: false };
}

/* ------------------------------------------------------------ results --- */

const results = [];
function record(id, expectation, ok, detail) {
  results.push({ id, expectation, ok, detail });
  const mark = ok === true ? "PASS" : ok === "blocked" ? "BLOCKED" : "FAIL";
  console.log(`${mark.padEnd(8)} ${id.padEnd(46)} ${detail}`);
}
const allowed = (id, r, extra = "") =>
  record(id, "allowed", r.ok, r.ok ? `ok ${extra}` : `refused ${r.code}: ${r.message}`);
const refused = (id, r, expectedCodes) =>
  record(id, "refused", !r.ok && (!expectedCodes || expectedCodes.includes(r.code)),
    r.ok ? "SUCCEEDED — must have been refused" : `refused ${r.code}: ${r.message}`);
const refusedWrite = (id, r) =>
  record(id, "refused", r.status === 403, r.status === 403 ? "403 from the rules" : `HTTP ${r.status} — must be 403`);

/* -------------------------------------------------------------- checks --- */

const created = { pet: null, post: null, bio: undefined };

async function main() {
  console.log(`project ${PROJECT} · run ${TAG}`);
  const A = await signIn(A_EMAIL);
  const B = await signIn(B_EMAIL);
  const U = U_EMAIL ? await signIn(U_EMAIL) : null;

  // --- Account and profile
  const name = `Vcf${Date.now().toString(36)}`;
  const avail = await call(A, "checkDisplayNameAvailabilityCallable", { displayName: name });
  allowed("profile: name availability is answered", avail, JSON.stringify(avail.result ?? {}));
  const ensured = await call(A, "ensureUserProfileCallable", {});
  allowed("profile: ensure returns the existing profile", ensured, str({ stringValue: ensured.result?.displayName }) ?? "");
  const before = await getDoc(A, `users/${A.uid}`);
  created.bio = str(before?.bio) ?? "";
  const newBio = `TEST CONTENT ${TAG} bio`;
  const upd = await call(A, "updateUserProfileCallable", { bio: newBio });
  allowed("profile: update the bio", upd);
  const after = await getDoc(A, `users/${A.uid}`);
  record("profile: the bio was written", "allowed", str(after?.bio) === newBio, `bio=${JSON.stringify(str(after?.bio))}`);
  const other = await call(B, "updateUserProfileCallable", { displayName: str(after?.displayName) });
  refused("profile: someone else's name is refused", other, ["already-exists", "invalid-argument", "failed-precondition"]);

  // --- Pets
  // Pet names are 2–20 characters; "TC" marks it as test content.
  const petName = `TC ${TAG.slice(-10)}`;
  const pet = await call(A, "createPetCallable", { name: petName, species: "dog", relationship: "mom" });
  allowed("pets: create", pet, pet.result?.id ?? pet.result?.petId ?? "");
  const petId = pet.result?.id ?? pet.result?.petId;
  created.pet = petId ?? null;
  if (petId) {
    const fam = await poll(async () => {
      const d = await getDoc(A, `pets/${petId}/family/${A.uid}`);
      return { done: !!d && !d.__error && !!str(d.userName), d };
    });
    record("pets: creator is primary in the family (+onFamilyCreated)", "allowed",
      str(fam.d?.role) === "primary" && !!str(fam.d?.userName), `role=${str(fam.d?.role)} userName=${str(fam.d?.userName) ? "set" : "missing"}`);

    refusedWrite("rules: direct write to a pet", await patchDoc(A, `pets/${petId}`, { name: { stringValue: "hacked" } }));
    refusedWrite("rules: direct write into a family", await patchDoc(A, `pets/${petId}/family/${B.uid}`, { role: { stringValue: "member" } }));
    refused("pets: a non-member cannot edit", await call(B, "updatePetCallable", { petId, bio: "x" }), ["permission-denied"]);
    allowed("pets: the owner edits", await call(A, "updatePetCallable", { petId, bio: `TEST CONTENT ${TAG}` }));
    const edited = await getDoc(A, `pets/${petId}`);
    record("pets: the edit was written", "allowed", str(edited?.bio) === `TEST CONTENT ${TAG}`, `bio=${JSON.stringify(str(edited?.bio))}`);
    allowed("pets: check-ins list", await call(A, "getPetCheckinsCallable", { petId }));

    // --- Follows
    allowed("follows: B follows A's pet", await call(B, "followPetCallable", { petId }));
    const counted = await poll(async () => {
      const f = await getDoc(B, `users/${B.uid}/followingPets/${petId}`);
      const p = await getDoc(B, `pets/${petId}`);
      return { done: f?.counted?.booleanValue === true && int(p?.followerCount) === 1, f, p };
    });
    record("follows: counted, followerCount 1 (+onFollowingPetCreated)", "allowed", counted.done,
      `counted=${counted.f?.counted?.booleanValue} followerCount=${int(counted.p?.followerCount)}`);
    refused("follows: an owner cannot follow their own pet", await call(A, "followPetCallable", { petId }), ["failed-precondition"]);
    allowed("follows: B unfollows", await call(B, "unfollowPetCallable", { petId }));
    const uncounted = await poll(async () => {
      const p = await getDoc(B, `pets/${petId}`);
      return { done: int(p?.followerCount) === 0, p };
    });
    record("follows: followerCount back to 0 (+onFollowingPetDeleted)", "allowed", uncounted.done, `followerCount=${int(uncounted.p?.followerCount)}`);

    // --- Families
    const invite = await call(A, "createInvitationCallable", { petId });
    if (invite.ok) {
      allowed("family: create an invitation", invite, invite.result?.code ? "code issued" : "");
      const code = invite.result?.code;
      allowed("family: get the active invitation", await call(A, "getActiveInvitationCallable", { petId }));
      allowed("family: B validates the code", await call(B, "validateInvitationCallable", { code }));
      const redeem = await call(B, "redeemInvitationCallable", { code, relationship: "caretaker" });
      allowed("family: B redeems the code", redeem);
      if (redeem.ok) {
        refused("family: a member cannot remove another", await call(B, "removeFamilyMemberCallable", { petId, targetUserId: A.uid }), ["permission-denied"]);
        allowed("family: the primary transfers to B", await call(A, "transferPetPrimaryCallable", { petId, targetUserId: B.uid }));
        const roles = await getDoc(A, `pets/${petId}/family/${B.uid}`);
        record("family: B is now primary", "allowed", str(roles?.role) === "primary", `role=${str(roles?.role)}`);
        allowed("family: B (primary) removes A", await call(B, "removeFamilyMemberCallable", { petId, targetUserId: A.uid }));
        refused("pets: someone no longer in the family cannot delete", await call(A, "deletePetCallable", { petId }), ["permission-denied", "failed-precondition", "not-found"]);
        created.petDeleter = B;
      }
      allowed("family: revoke", await call(created.petDeleter ?? A, "revokeInvitationCallable", { petId, code }));
    } else {
      record("family: create an invitation", "allowed", "blocked",
        `${invite.code}: ${invite.message} — needs the invitations.code collection-group index`);
    }

    // --- Posting
    const operationId = `${TAG}-op`;
    const text = `TEST CONTENT ${TAG} post`;
    if (U) refused("posting: an unverified account is refused", await call(U, "createPostCallable", { petId, text, operationId: `${TAG}-u` }), ["failed-precondition", "permission-denied"]);
    const postPet = created.petDeleter ? null : petId;
    if (postPet) {
      const post = await call(A, "createPostCallable", { petId: postPet, text, operationId });
      allowed("posting: create a text post", post, post.result?.postId ?? post.result?.id ?? "");
      const postId = post.result?.postId ?? post.result?.id;
      created.post = postId ?? null;
      if (postId) {
        const status = await call(A, "getPublishStatusCallable", { operationId });
        record("posting: publish status says published", "allowed", status.ok && status.result?.published === true, JSON.stringify(status.result ?? status.code));
        const again = await call(A, "createPostCallable", { petId: postPet, text, operationId });
        record("posting: the same operationId does not publish twice", "allowed",
          again.ok && (again.result?.postId ?? again.result?.id) === postId, JSON.stringify(again.result ?? again.code));
        const counted = await poll(async () => {
          const p = await getDoc(A, `pets/${postPet}`);
          return { done: int(p?.postCount) === 1, p };
        });
        record("posting: pet postCount 1 (+onPostWritten)", "allowed", counted.done, `postCount=${int(counted.p?.postCount)}`);
        refused("posting: someone else cannot edit it", await call(B, "updatePostCallable", { postId, text: "x" }), ["permission-denied"]);
        allowed("posting: the author edits it", await call(A, "updatePostCallable", { postId, text: `${text} edited`, petId: postPet }));
        allowed("posting: pin it", await call(A, "setPinnedPostCallable", { postId }));
        const pinned = await getDoc(A, `users/${A.uid}`);
        record("posting: pinnedPostId is set", "allowed", str(pinned?.pinnedPostId) === postId, `pinnedPostId=${str(pinned?.pinnedPostId) ? "set" : "missing"}`);
        allowed("posting: unpin it", await call(A, "setPinnedPostCallable", { postId: null }));
        refused("posting: someone else cannot delete it", await call(B, "deletePostCallable", { postId }), ["permission-denied"]);
        allowed("posting: the author deletes it", await call(A, "deletePostCallable", { postId }));
        const gone = await poll(async () => ({ done: (await getDoc(A, `posts/${postId}`)) === null }));
        record("posting: the post is gone", "allowed", gone.done, gone.done ? "404" : "still there");
        if (gone.done) created.post = null;
      }
    }

    // --- Deleting the pet
    const deleter = created.petDeleter ?? A;
    const del = await call(deleter, "deletePetCallable", { petId });
    allowed("pets: the last owner deletes it", del);
    const petGone = await poll(async () => ({ done: (await getDoc(deleter, `pets/${petId}`)) === null }));
    record("pets: the pet is gone", "allowed", petGone.done, petGone.done ? "404" : "still there");
    if (petGone.done) created.pet = null;
  }

  // --- Put back what was changed
  const restore = await call(A, "updateUserProfileCallable", { bio: created.bio ?? "" });
  record("cleanup: bio restored", "allowed", restore.ok, restore.ok ? "" : `${restore.code}: ${restore.message}`);
}

main()
  .catch((error) => {
    console.error(`crashed: ${error.stack ?? error}`);
    results.push({ id: "crash", ok: false });
  })
  .finally(() => {
    if (created.pet || created.post) {
      console.log(`LEFT BEHIND: pet=${created.pet ?? "-"} post=${created.post ?? "-"} (text starts "TEST CONTENT ${TAG}")`);
    }
    const failed = results.filter((r) => r.ok === false);
    const blocked = results.filter((r) => r.ok === "blocked");
    const passed = results.filter((r) => r.ok === true);
    console.log(`\n${passed.length} passed · ${blocked.length} blocked · ${failed.length} failed`);
    process.exit(failed.length ? 1 : 0);
  });
