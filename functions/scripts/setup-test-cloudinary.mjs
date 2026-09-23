#!/usr/bin/env node
/**
 * One-time setup of the TEST Cloudinary account for petnote-devtest.
 * Run by the account owner, in their own terminal:
 *
 *     node functions/scripts/setup-test-cloudinary.mjs
 *
 * It asks for the test account's cloud name, then its API key and API secret
 * with hidden input. It never prints the key, the secret, a signature or a raw
 * Cloudinary response, and writes nothing to disk.
 *
 * What it does, in order, stopping at the first failure:
 *   1. Refuses production's cloud name (`dgeunvmmn`) before any network call,
 *      and again if the credentials turn out to belong to it.
 *   2. Checks the key and secret belong to that cloud (GET /config).
 *   3. Creates or overwrites the two presets the app signs for,
 *      `petnote_image_signed` and `petnote_video_signed`, as SIGNED presets
 *      with nothing else set — no folder, no public-id prefix, no filename
 *      rule — because the server's URL check needs `folder` to end up in the
 *      public id (functions/src/shared.ts, assertOwnCloudinaryAsset).
 *   4. Reads them back and checks exactly that.
 *   5. Uploads one tiny image and one short sample video the way the app does
 *      (signed folder/timestamp/upload_preset, folder petnote/users/setup-probe),
 *      checks the returned address has the shape the server accepts, checks
 *      the size transformations the apps request are served (so strict
 *      transformations are off), then deletes both probes.
 *   6. Only if you answer "y": stores the key and secret as Firebase secrets of
 *      petnote-devtest — the project id is fixed here, so a forgotten
 *      `--project` cannot write them into production — with
 *      `--non-interactive`, which makes firebase-tools neither redeploy
 *      functions nor destroy older secret versions.
 *
 * Afterwards, send only the cloud name. It is public: it appears in every
 * image address the account serves.
 */
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import readline from "node:readline";

const PRODUCTION_CLOUD = "dgeunvmmn";
const TEST_PROJECT = "petnote-devtest";
const PRESETS = ["petnote_image_signed", "petnote_video_signed"];
// Settings that would stop `folder` becoming the public id's prefix, or add a
// filename to it. None may be set on either preset.
const PATH_SETTINGS = ["folder", "asset_folder", "public_id_prefix", "public_id", "use_asset_folder_as_public_id_prefix", "use_filename"];
const PROBE_FOLDER = "petnote/users/setup-probe";
// 1x1 transparent PNG.
const PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";
// Cloudinary's public sample clip, which the emulator seed already uses.
const SAMPLE_VIDEO = "https://res.cloudinary.com/demo/video/upload/v1/dog.mp4";

let failed = false;
const pass = (what) => console.log(`PASS  ${what}`);
const fail = (what) => { failed = true; console.log(`FAIL  ${what}`); };

function ask(question, { hidden = false } = {}) {
  return new Promise((resolve) => {
    if (!hidden) {
      const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
      rl.question(question, (answer) => { rl.close(); resolve(answer.trim()); });
      return;
    }
    process.stdout.write(question);
    const input = process.stdin;
    let value = "";
    input.setRawMode(true);
    input.resume();
    input.setEncoding("utf8");
    const onData = (chunk) => {
      for (const ch of chunk) {
        if (ch === "\r" || ch === "\n" || ch === "\u0004") {
          input.setRawMode(false);
          input.pause();
          input.removeListener("data", onData);
          process.stdout.write("\n");
          resolve(value.trim());
          return;
        }
        if (ch === "\u0003") { process.stdout.write("\n"); process.exit(130); }
        if (ch === "\u007f" || ch === "\b") { value = value.slice(0, -1); continue; }
        value += ch;
      }
    };
    input.on("data", onData);
  });
}

function sign(params, secret) {
  const toSign = Object.keys(params).sort().map((k) => `${k}=${params[k]}`).join("&");
  return createHash("sha1").update(`${toSign}${secret}`).digest("hex");
}

/** Only Cloudinary's error message ever leaves this function, never a body. */
async function cloudinary(method, url, { auth, form } = {}) {
  const headers = {};
  if (auth) headers.Authorization = `Basic ${Buffer.from(`${auth.key}:${auth.secret}`).toString("base64")}`;
  let body;
  if (form) {
    body = new URLSearchParams(form).toString();
    headers["Content-Type"] = "application/x-www-form-urlencoded";
  }
  const res = await fetch(url, { method, headers, body });
  let json = null;
  try { json = await res.json(); } catch { /* not JSON */ }
  return { status: res.status, json, error: json?.error?.message ?? (res.ok ? null : `HTTP ${res.status}`) };
}

async function setSecret(name, value) {
  return new Promise((resolve) => {
    const child = spawn(
      "npx",
      ["firebase", "functions:secrets:set", name, "--project", TEST_PROJECT, "--data-file", "-", "--non-interactive"],
      { stdio: ["pipe", "inherit", "inherit"] }
    );
    // No trailing newline: firebase-tools stores stdin as it arrives.
    child.stdin.end(value);
    child.on("close", (code) => resolve(code === 0));
  });
}

async function main() {
  const cloud = (await ask("Test account cloud name: ")).toLowerCase();
  if (!/^[a-z0-9-]+$/.test(cloud)) { fail("the cloud name has characters a cloud name cannot have"); return; }
  if (cloud === PRODUCTION_CLOUD) { fail(`${PRODUCTION_CLOUD} is PRODUCTION's account; this script only sets up the test one`); return; }
  const key = await ask("API key (hidden): ", { hidden: true });
  const secret = await ask("API secret (hidden): ", { hidden: true });
  if (!key || !secret) { fail("the key and the secret are both needed"); return; }
  const auth = { key, secret };
  const api = `https://api.cloudinary.com/v1_1/${cloud}`;

  // 2. The credentials belong to this cloud, and it is not production.
  const config = await cloudinary("GET", `${api}/config?settings=true`, { auth });
  if (config.status !== 200) { fail(`the key and secret were not accepted for ${cloud}: ${config.error}`); return; }
  if (config.json?.cloud_name === PRODUCTION_CLOUD) { fail("these credentials belong to production"); return; }
  pass(`credentials accepted for ${cloud} (folder mode: ${config.json?.settings?.folder_mode ?? "unknown"})`);

  const existing = await cloudinary("GET", `${api}/upload_presets?max_results=500`, { auth });
  const unsigned = (existing.json?.presets ?? []).filter((p) => p.unsigned).map((p) => p.name);
  if (unsigned.length) {
    console.log(`NOTE  unsigned presets in this account (anyone could upload with them): ${unsigned.join(", ")}`);
  }

  // 3–4. Both presets, signed, nothing else; then read back.
  for (const name of PRESETS) {
    const made = await cloudinary("POST", `${api}/upload_presets`, { auth, form: { name, unsigned: "false" } });
    if (made.status !== 200) { fail(`creating ${name}: ${made.error}`); return; }
    const back = await cloudinary("GET", `${api}/upload_presets/${name}`, { auth });
    if (back.status !== 200) { fail(`reading ${name} back: ${back.error}`); return; }
    const settings = back.json?.settings ?? {};
    const pathSet = PATH_SETTINGS.filter((k) => settings[k] !== undefined && settings[k] !== false && settings[k] !== "");
    if (back.json?.name !== name || back.json?.unsigned !== false || pathSet.length) {
      fail(`${name} is not a plain signed preset (unsigned=${back.json?.unsigned}; set: ${pathSet.join(", ") || "none"})`);
      return;
    }
    pass(`${name}: signed, no folder or public-id settings (${Object.keys(settings).join(", ") || "no settings"})`);
  }

  // 5. Upload as the app does, check the address, check transformations, delete.
  const probes = [
    { resource: "image", preset: PRESETS[0], file: PNG, variant: (u) => u.replace("/upload/", "/upload/w_300,h_300,c_fill,q_auto,f_auto/") },
    { resource: "video", preset: PRESETS[1], file: SAMPLE_VIDEO, variant: (u) => u.replace("/upload/", "/upload/so_0,w_800,q_auto,f_auto/").replace(/\.[a-z0-9]+$/, ".jpg") },
  ];
  for (const probe of probes) {
    const timestamp = String(Math.floor(Date.now() / 1000));
    const signed = { folder: PROBE_FOLDER, timestamp, upload_preset: probe.preset };
    const up = await cloudinary("POST", `${api}/${probe.resource}/upload`, {
      form: { ...signed, file: probe.file, api_key: key, signature: sign(signed, secret) },
    });
    if (up.status !== 200) { fail(`${probe.resource} upload: ${up.error}`); continue; }
    const publicId = up.json?.public_id ?? "";
    const path = (() => { try { return new URL(up.json?.secure_url ?? "").pathname; } catch { return ""; } })();
    if (publicId.startsWith(`${PROBE_FOLDER}/`) && path.startsWith(`/${cloud}/`) && path.includes("/petnote/")) {
      pass(`${probe.resource} upload lands under /${cloud}/…/${PROBE_FOLDER}/ — the shape the server accepts`);
    } else {
      fail(`${probe.resource} upload landed at public id "${publicId}"; the server needs /${cloud}/ and /petnote/ in the path`);
    }
    const variant = await fetch(probe.variant(up.json?.secure_url ?? ""), { method: "GET" });
    const type = variant.headers.get("content-type") ?? "";
    if (variant.status === 200 && type.startsWith("image/")) {
      pass(`${probe.resource}: the app's size transformation is served (${type})`);
    } else {
      fail(`${probe.resource}: the app's transformation came back HTTP ${variant.status} ${type} — strict transformations may be on`);
    }
    const destroyTs = String(Math.floor(Date.now() / 1000));
    const destroyParams = { public_id: publicId, timestamp: destroyTs };
    const gone = await cloudinary("POST", `${api}/${probe.resource}/destroy`, {
      form: { ...destroyParams, api_key: key, signature: sign(destroyParams, secret) },
    });
    if (gone.json?.result === "ok") pass(`${probe.resource} probe deleted`);
    else fail(`deleting the ${probe.resource} probe: ${gone.error ?? gone.json?.result}`);
  }

  if (failed) return;

  // 6. Optional: store the two secrets in the TEST project.
  const answer = (await ask(`Store the key and secret as secrets of ${TEST_PROJECT} now? [y/N] `)).toLowerCase();
  if (answer === "y") {
    for (const [name, value] of [["CLOUDINARY_API_KEY", key], ["CLOUDINARY_API_SECRET", secret]]) {
      if (await setSecret(name, value)) pass(`${name} stored in ${TEST_PROJECT}`);
      else fail(`storing ${name} in ${TEST_PROJECT}`);
    }
  } else {
    console.log(`SKIP  secrets not stored. To store them yourself, keep --project ${TEST_PROJECT} on both:`);
    console.log(`      npx firebase functions:secrets:set CLOUDINARY_API_KEY --project ${TEST_PROJECT}`);
    console.log(`      npx firebase functions:secrets:set CLOUDINARY_API_SECRET --project ${TEST_PROJECT}`);
  }
}

main()
  .catch((error) => { fail(`crashed: ${error?.message ?? error}`); })
  .finally(() => {
    console.log(failed ? "\nNot finished — see FAIL above. Nothing secret was printed." : "\nDone. Send only the cloud name.");
    process.exit(failed ? 1 : 0);
  });
