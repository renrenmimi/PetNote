/**
 * Serves this branch's callables and Firestore triggers locally, for
 * acceptance testing.
 *
 * ## Why this exists
 *
 * The Firebase functions emulator cannot run this codebase. firebase-tools
 * 15.13.0 stubs `firebase-admin` through a proxy that does `value.bind(target)`
 * on `admin.firestore`, and `Function.prototype.bind` does not copy a
 * function's own properties — so `admin.firestore.FieldValue` is `undefined`
 * inside that runtime. `assertRateLimit` calls
 * `FieldValue.serverTimestamp()`, and every authenticated callable calls
 * `assertRateLimit`, so every one of them returns 500. Reproduced against this
 * checkout:
 *
 *     TypeError: Cannot read properties of undefined (reading 'serverTimestamp')
 *       at functions/lib/shared.js:384
 *       at assertRateLimit (functions/lib/shared.js:367)
 *       at .../firebase-tools/lib/emulator/functionsEmulatorRuntime.js:399
 *
 * That is an upstream bug. The real fix is importing FieldValue/Timestamp from
 * the `firebase-admin/firestore` subpath, which firebase-tools does not stub —
 * 95 call sites across 12 modules, which is not a change to make inside an
 * already-accepted review branch.
 *
 * So this speaks the callable HTTP protocol itself and invokes the compiled
 * handlers through the `.run()` hook firebase-functions v2 attaches to them.
 * That is the same mechanism the 200 backend tests use.
 *
 * ## What it is and is not
 *
 * It exercises **handler logic and client wiring** against the real Firestore
 * and Auth emulators. It is **not** the Cloud Functions runtime: no cold
 * starts, no Secret Manager mounting, no per-function memory or timeout, no
 * IAM. A callable that works here can still fail in production for those
 * reasons — the missing-secret-binding class of bug is exactly one this cannot
 * catch.
 *
 * Test-only. Never deployed; nothing in `src/` imports it.
 *
 * ## Usage
 *
 *     # terminal 1
 *     export JAVA_HOME=/opt/homebrew/opt/openjdk
 *     npx firebase emulators:start --only firestore,auth --project petnote-test
 *
 *     # terminal 2, from functions/
 *     npm run build && node scripts/callable-shim.mjs
 */

import http from "node:http";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const functionsRoot = path.resolve(here, "..");

const PORT = Number(process.env.SHIM_PORT || 5101);
const PROJECT = process.env.GCLOUD_PROJECT || "petnote-test";
const REGION = "us-central1";

process.env.FIRESTORE_EMULATOR_HOST ||= "127.0.0.1:8088";
process.env.FIREBASE_AUTH_EMULATOR_HOST ||= "127.0.0.1:9099";
process.env.GCLOUD_PROJECT = PROJECT;
process.env.FIREBASE_CONFIG ||= JSON.stringify({ projectId: PROJECT });
// The signature callable reads these through defineSecret().value(). Left
// obviously fake unless the operator exports real ones: with fakes the
// signature is refused by Cloudinary, so media upload cannot be exercised
// here. That limitation is documented rather than papered over.
process.env.CLOUDINARY_API_KEY ||= "shim-fake-key";
process.env.CLOUDINARY_API_SECRET ||= "shim-fake-secret";

const lib = require(path.join(functionsRoot, "lib", "index.js"));
const { admin, db } = require(path.join(functionsRoot, "lib", "platform.js"));

/* ------------------------------------------------------------------ auth --- */

/**
 * Reads the uid and claims out of an Auth-emulator ID token.
 *
 * The emulator issues unsigned tokens, so this decodes rather than verifies —
 * correct here and wrong anywhere else. Real deployments verify through the
 * Admin SDK; this shim exists only in front of an emulator.
 */
function decodeEmulatorToken(header) {
  if (!header?.startsWith("Bearer ")) return undefined;
  const raw = header.slice("Bearer ".length).trim();
  if (!raw || raw === "owner") return undefined;
  const payload = raw.split(".")[1];
  if (!payload) return undefined;
  try {
    const claims = JSON.parse(
      Buffer.from(payload.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8")
    );
    const uid = claims.user_id || claims.sub || claims.uid;
    if (!uid) return undefined;
    return { uid, token: { ...claims, uid } };
  } catch {
    return undefined;
  }
}

/* -------------------------------------------------------------- callables --- */

const callables = new Map();
for (const [name, value] of Object.entries(lib)) {
  if (value && typeof value.run === "function" && !value.__trigger?.eventTrigger) {
    callables.set(name, value);
  }
}

function errorBody(error) {
  const code = error?.httpErrorCode?.canonicalName || "INTERNAL";
  const status = error?.httpErrorCode?.status || 500;
  return {
    status,
    body: {
      error: {
        message: error?.message || "INTERNAL",
        status: code,
        ...(error?.details === undefined ? {} : { details: error.details }),
      },
    },
  };
}

const server = http.createServer((req, res) => {
  const cors = {
    "Access-Control-Allow-Origin": req.headers.origin || "*",
    "Access-Control-Allow-Headers":
      "Content-Type,Authorization,X-Firebase-AppCheck,X-Firebase-Client",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
    "Access-Control-Max-Age": "3600",
  };
  if (req.method === "OPTIONS") {
    res.writeHead(204, cors);
    res.end();
    return;
  }

  const name = (req.url || "").split("?")[0].split("/").filter(Boolean).pop();
  const fn = name ? callables.get(name) : undefined;
  if (!fn) {
    res.writeHead(404, { ...cors, "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { message: `No callable ${name}`, status: "NOT_FOUND" } }));
    return;
  }

  let raw = "";
  req.on("data", (chunk) => {
    raw += chunk;
  });
  req.on("end", async () => {
    let data;
    try {
      data = raw ? JSON.parse(raw).data : undefined;
    } catch {
      res.writeHead(400, { ...cors, "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: { message: "Bad JSON", status: "INVALID_ARGUMENT" } }));
      return;
    }
    const auth = decodeEmulatorToken(req.headers.authorization);
    try {
      const result = await fn.run({
        data,
        auth,
        rawRequest: req,
        acceptsStreaming: false,
      });
      console.log(`  ${name} -> ok`);
      res.writeHead(200, { ...cors, "Content-Type": "application/json" });
      res.end(JSON.stringify({ result: result ?? null }));
    } catch (error) {
      const { status, body } = errorBody(error);
      console.log(`  ${name} -> ${body.error.status}: ${body.error.message}`);
      res.writeHead(status, { ...cors, "Content-Type": "application/json" });
      res.end(JSON.stringify(body));
    }
  });
});

/* --------------------------------------------------------------- triggers --- */

/**
 * Firestore triggers, driven from emulator snapshot listeners.
 *
 * Each entry says which export to call, what to listen to, and how to turn a
 * document id into the trigger's `params`. `onDocumentWritten` handlers get
 * before/after snapshots, so the previous snapshot per document is cached
 * here.
 *
 * Delivery here is best-effort and in-order, which is *weaker* than what
 * production guarantees (at least once, no ordering). The 200 backend tests
 * are what cover redelivery and out-of-order cases; this only exists so that
 * counters and notifications move while somebody clicks through the app.
 *
 * Scheduled functions are not driven at all — `resumeAbandonedPetDeletions`
 * has to be invoked by hand if it needs exercising.
 */
const triggers = [
  { fn: "onPostWritten", group: false, path: "posts", kind: "written", params: (id) => ({ postId: id }) },
  { fn: "onPostDeleted", group: false, path: "posts", kind: "deleted", params: (id) => ({ postId: id }) },
  { fn: "onPetDeleted", group: false, path: "pets", kind: "deleted", params: (id) => ({ petId: id }) },
  { fn: "onLikeCreated", group: true, path: "likes", kind: "created", params: (id, ref) => ({ postId: ref.parent.parent.id, likeId: id }) },
  { fn: "onLikeDeleted", group: true, path: "likes", kind: "deleted", params: (id, ref) => ({ postId: ref.parent.parent.id, likeId: id }) },
  { fn: "onCommentCreated", group: true, path: "comments", kind: "created", params: (id, ref) => ({ postId: ref.parent.parent.id, commentId: id }) },
  { fn: "onCommentDeleted", group: true, path: "comments", kind: "deleted", params: (id, ref) => ({ postId: ref.parent.parent.id, commentId: id }) },
  { fn: "onFollowingPetCreated", group: true, path: "followingPets", kind: "created", params: (id, ref) => ({ userId: ref.parent.parent.id, petId: id }) },
  { fn: "onFollowingPetDeleted", group: true, path: "followingPets", kind: "deleted", params: (id, ref) => ({ userId: ref.parent.parent.id, petId: id }) },
  { fn: "onFamilyCreated", group: true, path: "family", kind: "created", params: (id, ref) => ({ petId: ref.parent.parent.id, userId: id }) },
  { fn: "onMeetupParticipantCreated", group: true, path: "participants", kind: "created", params: (id, ref) => ({ meetupId: ref.parent.parent.id, userId: id }) },
  { fn: "onParticipantDeleted", group: true, path: "participants", kind: "deleted", params: (id, ref) => ({ meetupId: ref.parent.parent.id, userId: id }) },
  { fn: "onReviewCreated", group: true, path: "reviews", kind: "created", params: (id, ref) => ({ locationId: ref.parent.parent.id, reviewId: id }) },
  { fn: "onReviewDeleted", group: true, path: "reviews", kind: "deleted", params: (id, ref) => ({ locationId: ref.parent.parent.id, reviewId: id }) },
  { fn: "onCheckinCreated", group: true, path: "checkins", kind: "created", params: (id, ref) => ({ locationId: ref.parent.parent.id, checkinId: id }) },
  { fn: "onCheckinDeleted", group: true, path: "checkins", kind: "deleted", params: (id, ref) => ({ locationId: ref.parent.parent.id, checkinId: id }) },
  { fn: "onLocationDeleted", group: false, path: "locations", kind: "deleted", params: (id) => ({ locationId: id }) },
  { fn: "onMeetupUpdated", group: false, path: "meetups", kind: "written", params: (id) => ({ meetupId: id }) },
  { fn: "onUserUpdated", group: false, path: "users", kind: "written", params: (id) => ({ userId: id }) },
];

let eventSeq = 0;
const previous = new Map();

function watch(entry) {
  const fn = lib[entry.fn];
  if (!fn || typeof fn.run !== "function") {
    console.warn(`  (no export ${entry.fn}; its trigger will not fire)`);
    return;
  }
  const query = entry.group ? db.collectionGroup(entry.path) : db.collection(entry.path);
  let primed = false;
  query.onSnapshot(
    (snapshot) => {
      // The first callback reports every existing document as "added". Prime
      // the cache from it instead of replaying history as fresh events.
      if (!primed) {
        primed = true;
        for (const docSnap of snapshot.docs) previous.set(docSnap.ref.path, docSnap);
        return;
      }
      for (const change of snapshot.docChanges()) {
        const ref = change.doc.ref;
        const before = previous.get(ref.path);
        const wanted =
          (entry.kind === "created" && change.type === "added") ||
          (entry.kind === "deleted" && change.type === "removed") ||
          entry.kind === "written";
        if (change.type === "removed") previous.delete(ref.path);
        else previous.set(ref.path, change.doc);
        if (!wanted) continue;

        const id = `shim-${entry.fn}-${++eventSeq}`;
        const params = entry.params(ref.id, ref);
        const event =
          entry.kind === "written"
            ? { id, params, data: { before, after: change.type === "removed" ? change.doc : change.doc } }
            : { id, params, data: change.doc };
        // For a written event the "after" must be absent when the document is
        // gone, or the handler cannot tell a delete from an update.
        if (entry.kind === "written" && change.type === "removed") {
          event.data = { before: before ?? change.doc, after: undefined };
        }
        Promise.resolve(fn.run(event)).catch((error) => {
          console.error(`  ${entry.fn} failed:`, error?.message || error);
        });
      }
    },
    (error) => console.error(`  watch ${entry.path} failed:`, error?.message || error)
  );
}

/* ------------------------------------------------------------------ boot --- */

server.listen(PORT, "127.0.0.1", () => {
  console.log(`callable shim: http://127.0.0.1:${PORT}/${PROJECT}/${REGION}/<name>`);
  console.log(`  firestore ${process.env.FIRESTORE_EMULATOR_HOST}, auth ${process.env.FIREBASE_AUTH_EMULATOR_HOST}`);
  console.log(`  ${callables.size} callables, ${triggers.length} triggers`);
  if (process.env.CLOUDINARY_API_SECRET === "shim-fake-secret") {
    console.log("  Cloudinary secrets are fake: media upload will be refused by Cloudinary.");
  }
  for (const entry of triggers) watch(entry);
});

process.on("SIGINT", () => {
  console.log("\nshutting down");
  server.close(() => process.exit(0));
});
