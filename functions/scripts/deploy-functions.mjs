#!/usr/bin/env node
/**
 * `firebase deploy --only functions`, with a retry and an unambiguous summary.
 *
 * Why this exists. Three consecutive deploys of this codebase each had exactly
 * one function fail — a different function each time, with a different error
 * each time (a Cloud Build "unexpected error", a Cloud Functions API request
 * failure). Pushing 60+ functions in one run appears to bump into a rate or
 * quota ceiling. The failures were transient: re-running deployed the
 * stragglers with no code change.
 *
 * The transience is not the dangerous part. The dangerous part is the SHAPE of
 * the failure: firebase exits non-zero *after* dozens of functions have already
 * updated. That reads as "nothing deployed" when in fact almost everything did,
 * and someone already misread it that way on this project — concluding from a
 * truncated log that seven callables had been left behind when they had not.
 *
 * So this script does three things:
 *
 *   1. Retries. The deploy is idempotent and skips unchanged functions, so a
 *      second pass is cheap and usually clears a transient straggler.
 *   2. Writes the FULL output to a log file. Never pipe a deploy through
 *      `tail` — truncation is what caused the misreading.
 *   3. Prints a summary that names what succeeded and what did not, so a
 *      non-zero exit can never be confused with "nothing happened".
 *
 * Usage:  npm run deploy               (from functions/)
 *         npm run deploy -- --attempts 5
 *         npm run deploy -- --project petnote-a9dac
 */
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const args = process.argv.slice(2);
function flag(name, fallback) {
  const i = args.indexOf(`--${name}`);
  return i !== -1 && args[i + 1] ? args[i + 1] : fallback;
}

const MAX_ATTEMPTS = Number(flag("attempts", "3"));
const PROJECT = flag("project", "");

const logDir = fs.mkdtempSync(path.join(os.tmpdir(), "petnote-deploy-"));

/** Runs one deploy attempt, teeing output to the console and a log file. */
function runOnce(attempt) {
  return new Promise((resolve) => {
    const logPath = path.join(logDir, `attempt-${attempt}.log`);
    const log = fs.createWriteStream(logPath);
    const argv = ["deploy", "--only", "functions"];
    if (PROJECT) argv.push("--project", PROJECT);

    console.log(`\n=== deploy attempt ${attempt}/${MAX_ATTEMPTS} ===`);
    console.log(`    full log: ${logPath}\n`);

    const child = spawn("firebase", argv, { stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    const capture = (chunk) => {
      const text = chunk.toString();
      out += text;
      process.stdout.write(text);
      log.write(text);
    };
    child.stdout.on("data", capture);
    child.stderr.on("data", capture);
    child.on("close", (code) => {
      log.end();
      resolve({ code, out, logPath });
    });
  });
}

/** Pulls the outcome out of a deploy log rather than trusting the exit code. */
function summarise(out) {
  const succeeded = [
    ...out.matchAll(/functions\[([^\]]+)\] Successful (update|create) operation/g),
  ].map((m) => m[1]);
  const skipped = [
    ...out.matchAll(/functions\[([^\]]+)\] Skipped \(No changes detected\)/g),
  ].map((m) => m[1]);

  // firebase lists the failures under a header, one tab-indented name per line.
  const failed = [];
  const block = out.split("Functions deploy had errors with the following functions:")[1];
  if (block) {
    for (const line of block.split("\n").slice(1)) {
      const name = line.trim();
      if (!name || line.startsWith("Error:") || !/^\s/.test(line)) break;
      failed.push(name);
    }
  }
  return { succeeded, skipped, failed };
}

let last = null;
let stillFailing = [];

for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
  last = await runOnce(attempt);
  const { succeeded, skipped, failed } = summarise(last.out);
  stillFailing = failed;

  console.log(`\n--- attempt ${attempt} result ---`);
  console.log(`    deployed: ${succeeded.length}`);
  console.log(`    unchanged: ${skipped.length}`);
  console.log(`    failed: ${failed.length}${failed.length ? ` (${failed.join(", ")})` : ""}`);
  console.log(`    firebase exit code: ${last.code}`);

  if (last.code === 0 && failed.length === 0) {
    console.log(`\n✔ deploy complete on attempt ${attempt}`);
    process.exit(0);
  }

  if (failed.length === 0) {
    // Non-zero exit with nothing named. Retrying blind could mask something
    // real, so stop and make the operator look.
    console.error(
      `\n✘ firebase exited ${last.code} but named no failing function.` +
        `\n  Not retrying — read the log before assuming this was transient:` +
        `\n  ${last.logPath}`
    );
    process.exit(last.code || 1);
  }

  if (attempt < MAX_ATTEMPTS) {
    console.log(
      `\n${failed.length} function(s) failed; retrying. These failures have been` +
        `\ntransient on this project, and the deploy skips anything already current.`
    );
  }
}

console.error(
  `\n✘ still failing after ${MAX_ATTEMPTS} attempts: ${stillFailing.join(", ")}` +
    `\n\n  NOTE: everything else IS deployed. A non-zero exit here does not mean` +
    `\n  the deploy did nothing — check the per-attempt summaries above.` +
    `\n  Logs: ${logDir}`
);
process.exit(1);
