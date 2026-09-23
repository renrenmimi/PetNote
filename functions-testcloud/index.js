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

// Exactly the authorized set: a name added here by accident is a deployment
// nobody approved.
const EXPECTED_COUNT = 34;
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

const boundSecrets = new Set();
for (const [name, fn] of Object.entries(EXPORTS)) {
  const bound = fn?.__endpoint?.secretEnvironmentVariables ?? [];
  for (const s of bound) boundSecrets.add(`${name}:${s.key ?? s}`);
}
if (boundSecrets.size > 0) {
  throw new Error(
    "testcloud entry: one of these functions now binds a secret — "
    + [...boundSecrets].join(", ")
    + ". Stripping declarations would deploy it without that secret. "
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
  const dropped = declared.map((p) => p.name);
  declared.length = 0;
  // Printed, not silent: a deploy that removes declarations should say which.
  console.log(`[testcloud entry] no function here uses a parameter; dropped ${dropped.join(", ")}`);
}
