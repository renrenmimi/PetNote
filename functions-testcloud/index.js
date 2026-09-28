/**
 * The functions the independent test project needs, and nothing else.
 *
 * Six since 4ba1c57 (comments and likes); 28 more authorized by the owner on
 * 2026-09-22 for account, pets, posting, follows and families — each audited
 * first for secrets (none), network calls (none), schedules (none) and side
 * effects outside Firestore (Firebase Auth updateUser in the two profile
 * callables). Nothing that binds a secret, runs on a schedule, or deletes
 * media belongs here; the guards below refuse the first two.
 *
 * Why this file exists at all
 * ---------------------------
 * `firebase deploy --only functions:a,b,c` filters which functions are
 * *deployed*. It does not filter which parameters are *resolved*:
 * firebase-tools calls `resolveParams(build.params, …)` over everything the
 * codebase declared, before any filtering. `functions/src/platform.ts`
 * declares three secrets at module scope — CLOUDINARY_API_KEY,
 * CLOUDINARY_API_SECRET, GEOAPIFY_API_KEY — for the media and places
 * functions, and every module imports platform. So deploying six functions
 * that use no secrets still demanded all three, and the only offered remedy
 * was to create them in the test project.
 *
 * That was refused. The test project has no Cloudinary account, no Geoapify
 * key, and no business holding a copy of production's credentials.
 *
 * What it does
 * ------------
 * Re-exports the real implementations — this file contains no logic of its
 * own and never will — then removes the parameter declarations that came
 * along for the ride.
 *
 * The removal is guarded. `firebase-functions` records each endpoint's bound
 * secrets on `__endpoint.secretEnvironmentVariables`. If any of these six ever
 * starts using a secret, this refuses to strip anything and the deploy fails
 * loudly, rather than quietly shipping a function whose secret was dropped.
 */
// This entry deploys to the test project and nowhere else. `.firebaserc`
// defaults to production, so a deploy that forgot `--project petnote-devtest`
// would otherwise ship the test codebase there. firebase-tools sets the
// target project in the environment before it loads this file, at deploy and
// in the cloud; anything else refuses here, before a single function exists.
const platform = require("./lib/platform");
const TEST_PROJECT = "petnote-devtest";
if (platform.runningProjectId() !== TEST_PROJECT) {
  throw new Error(
    `testcloud entry: loaded for project "${platform.runningProjectId() ?? "(none)"}"; `
    + `this entry deploys to ${TEST_PROJECT} only`
  );
}

const posts = require("./lib/posts");
const notifications = require("./lib/notifications");
const users = require("./lib/users");
const pets = require("./lib/pets");
const places = require("./lib/places");
const cleanup = require("./lib/cleanup");
const invitations = require("./lib/invitations");
const family = require("./lib/family");

const EXPORTS = {
  // The original six.
  createCommentCallable: posts.createCommentCallable,
  deleteCommentCallable: posts.deleteCommentCallable,
  onLikeCreated: notifications.onLikeCreated,
  onLikeDeleted: notifications.onLikeDeleted,
  onCommentCreated: notifications.onCommentCreated,
  onCommentDeleted: notifications.onCommentDeleted,

  // Account and profile.
  ensureUserProfileCallable: users.ensureUserProfileCallable,
  checkDisplayNameAvailabilityCallable: users.checkDisplayNameAvailabilityCallable,
  updateUserProfileCallable: users.updateUserProfileCallable,
  onUserUpdated: users.onUserUpdated,
  onFamilyCreated: users.onFamilyCreated,

  // Pets.
  createPetCallable: pets.createPetCallable,
  updatePetCallable: pets.updatePetCallable,
  deletePetCallable: pets.deletePetCallable,
  getPetCheckinsCallable: places.getPetCheckinsCallable,
  onPetDeleted: cleanup.onPetDeleted,

  // Posting and managing posts.
  createPostCallable: posts.createPostCallable,
  updatePostCallable: posts.updatePostCallable,
  deletePostCallable: posts.deletePostCallable,
  getPublishStatusCallable: posts.getPublishStatusCallable,
  setPinnedPostCallable: posts.setPinnedPostCallable,
  onPostWritten: posts.onPostWritten,
  onPostDeleted: cleanup.onPostDeleted,

  // Follows and families.
  followPetCallable: pets.followPetCallable,
  unfollowPetCallable: pets.unfollowPetCallable,
  onFollowingPetCreated: notifications.onFollowingPetCreated,
  onFollowingPetDeleted: notifications.onFollowingPetDeleted,
  createInvitationCallable: invitations.createInvitationCallable,
  getActiveInvitationCallable: invitations.getActiveInvitationCallable,
  validateInvitationCallable: invitations.validateInvitationCallable,
  redeemInvitationCallable: invitations.redeemInvitationCallable,
  revokeInvitationCallable: invitations.revokeInvitationCallable,
  removeFamilyMemberCallable: family.removeFamilyMemberCallable,
  transferPetPrimaryCallable: family.transferPetPrimaryCallable,
};

// The test project never resolves to production's Cloudinary account. With
// no account of its own every media path refuses (platform.ts); this makes a
// table edit that pointed it at production fail the deploy instead.
const testAccount = platform.cloudinaryAccountFor(TEST_PROJECT);
if (testAccount && testAccount.cloudName === platform.PRODUCTION_CLOUDINARY.cloudName) {
  throw new Error("testcloud entry: petnote-devtest resolves to production's Cloudinary account");
}

// The two media functions the owner authorized for the test project
// (2026-09-23), and only once the test project has its own Cloudinary
// account in platform.ts. Until then they are not exported at all, so a
// deploy that names them finds nothing to deploy.
//   getCloudinaryUploadSignature   signs an upload into petnote/users/{uid}/
//   deleteCloudinaryAssetsCallable deletes the caller's own assets there
const MEDIA_FUNCTIONS = ["getCloudinaryUploadSignature", "deleteCloudinaryAssetsCallable"];
const MEDIA_SECRETS = ["CLOUDINARY_API_KEY", "CLOUDINARY_API_SECRET"];
if (testAccount) {
  const media = require("./lib/media");
  for (const name of MEDIA_FUNCTIONS) EXPORTS[name] = media[name];
}

// Exactly the authorized set: a name added here by accident is a deployment
// nobody approved.
const EXPECTED_COUNT = 34 + (testAccount ? MEDIA_FUNCTIONS.length : 0);
if (Object.keys(EXPORTS).length !== EXPECTED_COUNT) {
  throw new Error(`testcloud entry: ${Object.keys(EXPORTS).length} exports, ${EXPECTED_COUNT} authorized`);
}

// No schedules. Two scheduled functions (resumeAbandonedPetDeletions,
// cleanupOldReadNotifications) are constructed when these modules load; they
// deploy only if exported, and this makes exporting one fail the deploy.
for (const [name, fn] of Object.entries(EXPORTS)) {
  if (fn?.__endpoint?.scheduleTrigger) {
    throw new Error(`testcloud entry: ${name} is a scheduled function; none is authorized here`);
  }
}

for (const [name, fn] of Object.entries(EXPORTS)) {
  if (typeof fn !== "function" && typeof fn !== "object") {
    throw new Error(`testcloud entry: ${name} is missing from the compiled output`);
  }
  exports[name] = fn;
}

// --- parameter hygiene -----------------------------------------------------

// Secrets: the two media functions bind exactly the two Cloudinary secrets,
// and nothing else binds anything.
const unexpectedSecrets = [];
const usedSecrets = new Set();
for (const [name, fn] of Object.entries(EXPORTS)) {
  const bound = (fn?.__endpoint?.secretEnvironmentVariables ?? []).map((s) => s.key ?? s);
  bound.forEach((key) => usedSecrets.add(key));
  const allowed = MEDIA_FUNCTIONS.includes(name) ? MEDIA_SECRETS : [];
  for (const key of bound) if (!allowed.includes(key)) unexpectedSecrets.push(`${name}:${key}`);
  if (MEDIA_FUNCTIONS.includes(name) && MEDIA_SECRETS.some((key) => !bound.includes(key))) {
    unexpectedSecrets.push(`${name}: does not bind ${MEDIA_SECRETS.join(" and ")}`);
  }
}
if (unexpectedSecrets.length > 0) {
  throw new Error(
    "testcloud entry: secrets other than the authorized ones — "
    + unexpectedSecrets.join(", ")
    + ". Stripping declarations would deploy a function without its secret. "
    + "Decide deliberately instead of letting this file guess."
  );
}

// Found by description rather than by composing the symbol from a version
// number. `require("firebase-functions/package.json")` is blocked by that
// package's `exports` map — it throws ERR_PACKAGE_PATH_NOT_EXPORTED, here and
// in the cloud — and hardcoding a major version would rot at the next upgrade
// without saying so.
const paramsSymbol = Object.getOwnPropertySymbols(globalThis).find((s) =>
  String(s.description ?? "").startsWith("firebase-functions:params:declaredParams:")
);
const declared = paramsSymbol ? globalThis[paramsSymbol] : undefined;
if (Array.isArray(declared) && declared.length > 0) {
  // Only the declarations no exported function binds: GEOAPIFY_API_KEY
  // always, and the Cloudinary pair while the media functions are not here.
  const dropped = declared.filter((p) => !usedSecrets.has(p.name)).map((p) => p.name);
  const kept = declared.filter((p) => usedSecrets.has(p.name));
  declared.length = 0;
  declared.push(...kept);
  // Printed, not silent: a deploy that removes declarations should say which.
  console.log(`[testcloud entry] dropped ${dropped.join(", ") || "nothing"}; kept ${kept.map((p) => p.name).join(", ") || "nothing"}`);
}
