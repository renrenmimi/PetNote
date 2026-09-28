/**
 * Stages the compiled functions for the test-project-only deploy entry.
 *
 * `functions-testcloud/` holds a package.json and an index.js that re-export
 * six functions. It cannot `require("../functions/lib/…")`, because a deploy
 * uploads only the source directory it was pointed at — the parent would not
 * travel with it and the functions would fail at runtime. So the compiled
 * output is copied in.
 *
 * What is copied is build output, not source. `functions/src` remains the only
 * place the logic lives, `functions-testcloud/lib` is gitignored, and this
 * script rebuilds it every time rather than trusting whatever was there.
 *
 *   node functions/scripts/prepare-testcloud-deploy.mjs
 */
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const functionsDir = path.join(root, "functions");
const stageDir = path.join(root, "functions-testcloud");
const lib = path.join(functionsDir, "lib");
const stagedLib = path.join(stageDir, "lib");

console.log("building functions/…");
execFileSync("npm", ["--prefix", functionsDir, "run", "build"], { stdio: "inherit" });

if (!fs.existsSync(path.join(lib, "posts.js")) || !fs.existsSync(path.join(lib, "notifications.js"))) {
  throw new Error("functions/lib is missing posts.js or notifications.js after the build");
}

// Dependencies must match, or the staged copy runs against a different SDK
// than the one it was compiled with — which would fail somewhere far from
// here, at runtime, in the cloud.
const fnPkg = JSON.parse(fs.readFileSync(path.join(functionsDir, "package.json"), "utf8"));
const stagePkg = JSON.parse(fs.readFileSync(path.join(stageDir, "package.json"), "utf8"));
for (const [name, want] of Object.entries(fnPkg.dependencies ?? {})) {
  const have = stagePkg.dependencies?.[name];
  if (have !== want) {
    throw new Error(
      `dependency drift: functions/ wants ${name}@${want}, `
      + `functions-testcloud/ has ${have ?? "nothing"}. Update the staging package.json deliberately.`
    );
  }
}
if (fnPkg.engines?.node !== stagePkg.engines?.node) {
  throw new Error(`engine drift: functions/ is node ${fnPkg.engines?.node}, staging is ${stagePkg.engines?.node}`);
}

// A symlink, not a second install. firebase-tools needs firebase-functions
// resolvable from the source directory to run discovery, and installing it
// again would put a few hundred megabytes of the same packages on a machine
// that is already short of room — and could drift from the versions this code
// was compiled against. `node_modules` is in the config's ignore list, so it
// never travels with the upload; the cloud installs from package.json.
const stagedModules = path.join(stageDir, "node_modules");
if (!fs.existsSync(stagedModules)) {
  fs.symlinkSync("../functions/node_modules", stagedModules);
  console.log("linked functions-testcloud/node_modules -> ../functions/node_modules");
}

fs.rmSync(stagedLib, { recursive: true, force: true });
fs.cpSync(lib, stagedLib, { recursive: true });

const files = fs.readdirSync(stagedLib).filter((f) => f.endsWith(".js")).length;
console.log(`staged ${files} compiled modules into functions-testcloud/lib`);
console.log("now: firebase deploy --config firebase.testcloud.json --project petnote-devtest --only functions");
