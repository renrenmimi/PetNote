/**
 * The six functions the independent test project needs, and nothing else.
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

const EXPORTS = {
  createCommentCallable: posts.createCommentCallable,
  deleteCommentCallable: posts.deleteCommentCallable,
  onLikeCreated: notifications.onLikeCreated,
  onLikeDeleted: notifications.onLikeDeleted,
  onCommentCreated: notifications.onCommentCreated,
  onCommentDeleted: notifications.onCommentDeleted,
};

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
    "testcloud entry: one of the six functions now binds a secret — "
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
