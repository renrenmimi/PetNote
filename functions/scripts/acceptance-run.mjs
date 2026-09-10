/**
 * Drives the acceptance scenarios against the real Cloud Functions emulator.
 *
 * This is the automated half of docs/acceptance-environment.md's checklist: the
 * shared-owner lifecycle (invite, edit, transfer, leave, delete and recovery),
 * the email-verification gate, and the publish flow. It talks to the callables
 * over the callable HTTP protocol with real ID tokens from the Auth emulator,
 * and asserts outcomes by reading Firestore — so a passing run means the
 * deployed-shaped request produced the deployed-shaped state change, not that a
 * handler returned without throwing.
 *
 *     # with the emulator suite up (firestore, auth, functions, pubsub)
 *     node scripts/seed-acceptance.mjs
 *     node scripts/acceptance-run.mjs
 *
 * What a green run does NOT establish, and no amount of it ever will:
 *   - real Google popup sign-in (the Auth emulator simulates the provider)
 *   - the real verification-email round trip (no mail is sent; the gate is
 *     exercised by flipping the claim and re-minting a token, which is the
 *     mechanism, not the delivery)
 *   - real Cloudinary or Geoapify (fake credentials by design)
 *   - at-least-once or out-of-order trigger delivery (the emulator delivers
 *     once, in order; the unit tests cover redelivery)
 *   - rate limiting (this script clears the counters between scenarios so runs
 *     are deterministic; the limiter has its own unit coverage)
 *
 * Emulator only. Refuses to run against anything else.
 */

import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const functionsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const PROJECT = process.env.GCLOUD_PROJECT || "petnote-test";
const FIRESTORE_HOST = process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8088";
const AUTH_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST || "127.0.0.1:9099";
const FUNCTIONS_HOST = process.env.FUNCTIONS_EMULATOR_HOST || "127.0.0.1:5101";

if (!/^(petnote-test|demo-)/.test(PROJECT)) {
  console.error(
    `Refusing to run against project "${PROJECT}". Emulator only: use ` +
      `petnote-test or a demo-* project.`
  );
  process.exit(1);
}
process.env.GCLOUD_PROJECT = PROJECT;
process.env.FIRESTORE_EMULATOR_HOST = FIRESTORE_HOST;
process.env.FIREBASE_AUTH_EMULATOR_HOST = AUTH_HOST;

const admin = require(path.join(functionsRoot, "node_modules", "firebase-admin"));
if (admin.apps.length === 0) admin.initializeApp({ projectId: PROJECT });
const auth = admin.auth();
const db = admin.firestore();

const BASE = `http://${FUNCTIONS_HOST}/${PROJECT}/us-central1`;
const PASSWORD = "Passw0rd!x";

// ── plumbing ────────────────────────────────────────────────────────────────

let currentScenario = "";
const results = [];
let failures = 0;

function scenario(name) {
  currentScenario = name;
  console.log(`\n── ${name}`);
}

function record(ok, label, detail) {
  results.push({ scenario: currentScenario, ok, label });
  if (!ok) failures += 1;
  console.log(`   ${ok ? "PASS" : "FAIL"}  ${label}${detail ? `  — ${detail}` : ""}`);
}

function check(ok, label, detail) {
  record(Boolean(ok), label, detail);
  return Boolean(ok);
}

/** Mints a fresh ID token, so a claim change since the last one is picked up. */
async function tokenFor(email) {
  const response = await fetch(
    `http://${AUTH_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake-api-key`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, password: PASSWORD, returnSecureToken: true }),
    }
  );
  const body = await response.json();
  if (!body.idToken) throw new Error(`sign-in failed for ${email}: ${JSON.stringify(body)}`);
  return body.idToken;
}

async function call(name, idToken, data) {
  const response = await fetch(`${BASE}/${name}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(idToken ? { Authorization: `Bearer ${idToken}` } : {}),
    },
    body: JSON.stringify({ data }),
  });
  const text = await response.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    body = { raw: text };
  }
  if (body.error) {
    return { ok: false, status: body.error.status ?? String(response.status), message: body.error.message ?? "" };
  }
  return { ok: true, result: body.result };
}

/**
 * Asserts a rejection *and its reason*. A rejection for the wrong reason once
 * made a tag test pass while the contract was still broken, so the reason is
 * part of the assertion here, never just "it threw".
 */
function expectRejected(outcome, status, messageFragment, label) {
  if (outcome.ok) {
    return check(false, label, `expected ${status}, got success: ${JSON.stringify(outcome.result)}`);
  }
  const statusOk = outcome.status === status;
  const messageOk = !messageFragment || outcome.message.includes(messageFragment);
  return check(
    statusOk && messageOk,
    label,
    statusOk && messageOk ? outcome.status : `got ${outcome.status} "${outcome.message}"`
  );
}

async function familyOf(petId) {
  const snap = await db.collection(`pets/${petId}/family`).get();
  return snap.docs.map((d) => ({ userId: d.id, ...d.data() }));
}

async function primariesOf(petId) {
  const family = await familyOf(petId);
  return family.filter((m) => m.role === "primary").map((m) => m.userId);
}

async function petField(petId, field) {
  const snap = await db.doc(`pets/${petId}`).get();
  return snap.exists ? snap.data()[field] : undefined;
}

/** Deterministic runs: the limiter has unit coverage, this script is not it. */
async function clearRateLimits() {
  const snap = await db.collection("callableRateLimits").get();
  await Promise.all(snap.docs.map((d) => d.ref.delete()));
}

async function ensureUser(email, name, { verified = true } = {}) {
  let record;
  try {
    record = await auth.getUserByEmail(email);
    await auth.updateUser(record.uid, { password: PASSWORD, emailVerified: verified, displayName: name });
  } catch {
    record = await auth.createUser({ email, password: PASSWORD, emailVerified: verified, displayName: name });
  }
  await db.doc(`users/${record.uid}`).set(
    {
      displayName: name,
      displayNameLower: name.toLowerCase(),
      avatarUrl: "",
      bio: "",
      onboardingComplete: true,
    },
    { merge: true }
  );
  return record.uid;
}

/** Waits for a trigger to land, so a slow delivery is not read as a wrong one. */
async function waitFor(predicate, { label, timeoutMs = 8000 } = {}) {
  const deadline = Date.now() + timeoutMs;
  let last;
  for (;;) {
    last = await predicate();
    if (last.ok) return last;
    if (Date.now() > deadline) return { ...last, timedOut: true, label };
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
}

/**
 * Makes a run independent of how the previous one ended.
 *
 * Pets are capped per owner (5), and the scenarios legitimately leave one
 * behind — S5 ends with A as the sole owner of the shared pet. Without this,
 * the second run of the day fails on "Maximum 5 pets allowed" and the failure
 * looks like a defect in the invite flow. Direct Firestore deletes rather than
 * callables: this is teardown, not a scenario, and it must work even if a
 * callable is the thing that is broken.
 */
async function resetTestPets(uids) {
  const owned = new Set();
  const testUids = [uids.a, uids.b, uids.outsider, uids.newcomer].filter(Boolean);
  for (const uid of testUids) {
    const memberships = await db.collectionGroup("family").where("userId", "==", uid).get();
    for (const doc of memberships.docs) {
      const petId = doc.ref.parent.parent?.id;
      if (petId && petId !== "accept-pet") owned.add(petId);
    }
  }
  for (const petId of owned) {
    const family = await db.collection(`pets/${petId}/family`).get();
    await Promise.all(family.docs.map((d) => d.ref.delete()));
    await db.doc(`pets/${petId}`).delete().catch(() => undefined);
    await db.doc(`petDeletionTasks/${petId}`).delete().catch(() => undefined);
  }
  const strayTasks = await db.collection("petDeletionTasks").get();
  await Promise.all(strayTasks.docs.map((d) => d.ref.delete()));
  return owned.size;
}

// ── scenarios ───────────────────────────────────────────────────────────────

async function publishFlow(uids) {
  scenario("S1 发布流程：发帖、计数、幂等、删除、tag 契约");
  await clearRateLimits();
  const tokenA = await tokenFor("accept-a@example.com");
  const petId = "accept-pet";

  await db.doc(`pets/${petId}`).update({ postCount: 0 });

  const operationId = `accept-${Date.now()}`;
  const first = await call("createPostCallable", tokenA, {
    text: "acceptance run",
    tags: ["walks"],
    media: [],
    petId,
    operationId,
  });
  if (!check(first.ok, "已验证账号可以发帖", first.ok ? first.result.id : first.message)) return;
  const postId = first.result.id;

  const counted = await waitFor(async () => {
    const value = await petField(petId, "postCount");
    return { ok: value === 1, value };
  });
  check(counted.ok, "onPostWritten 把 postCount 推到 1", `postCount=${counted.value}`);

  const replay = await call("createPostCallable", tokenA, {
    text: "acceptance run",
    tags: ["walks"],
    media: [],
    petId,
    operationId,
  });
  check(
    replay.ok && replay.result.id === postId && replay.result.deduplicated === true,
    "同一 operationId 重放返回同一帖且标记 deduplicated",
    replay.ok ? JSON.stringify(replay.result) : replay.message
  );
  const afterReplay = await petField(petId, "postCount");
  check(afterReplay === 1, "重放没有把计数变成 2", `postCount=${afterReplay}`);

  const stored = await db.doc(`posts/${postId}`).get();
  check(
    Array.isArray(stored.data()?.tags) && stored.data().tags.includes("walks"),
    "合法 tag 已存下",
    JSON.stringify(stored.data()?.tags)
  );

  const badTag = await call("createPostCallable", tokenA, {
    text: "slash tag",
    tags: ["dogs/cats"],
    media: [],
    petId,
  });
  expectRejected(
    badTag,
    "INVALID_ARGUMENT",
    "Tags",
    "含 / 的 tag 被以 tag 为理由拒绝（不是因为别的字段）"
  );

  const deleted = await call("deletePostCallable", tokenA, { postId });
  check(deleted.ok, "作者可以删自己的帖", deleted.ok ? "" : deleted.message);
  const backToZero = await waitFor(async () => {
    const value = await petField(petId, "postCount");
    return { ok: value === 0, value };
  });
  check(backToZero.ok, "删除后计数回到 0 且不为负", `postCount=${backToZero.value}`);
}

async function verificationGate() {
  scenario("S2 注册验证门禁");
  await clearRateLimits();

  // Reset to unverified so the run is repeatable regardless of how it ended.
  const unverified = await auth.getUserByEmail("accept-new@example.com");
  await auth.updateUser(unverified.uid, { emailVerified: false });

  const before = await tokenFor("accept-new@example.com");
  const blockedPost = await call("createPostCallable", before, {
    text: "should not publish",
    tags: [],
    media: [],
    petId: "accept-pet",
  });
  expectRejected(
    blockedPost,
    "PERMISSION_DENIED",
    "Verify your email before posting.",
    "未验证邮箱发帖被拒，且理由是验证而非权限"
  );

  const blockedComment = await call("createCommentCallable", before, {
    postId: "whatever",
    text: "hi",
  });
  check(
    !blockedComment.ok,
    "未验证邮箱评论同样被拒",
    blockedComment.ok ? "unexpectedly succeeded" : `${blockedComment.status} ${blockedComment.message}`
  );

  // Flipping the claim and re-minting a token is the *mechanism* the real
  // verification link triggers. It is not the delivery, and this run makes no
  // claim about the delivery.
  await auth.updateUser(unverified.uid, { emailVerified: true });
  await clearRateLimits();
  const after = await tokenFor("accept-new@example.com");
  const ownPet = await call("createPetCallable", after, {
    name: "Gatekeep",
    species: "dog",
    gender: "male",
    relationship: "dad",
  });
  if (check(ownPet.ok, "验证后可以建宠物", ownPet.ok ? ownPet.result.id : ownPet.message)) {
    const allowed = await call("createPostCallable", after, {
      text: "now allowed",
      tags: [],
      media: [],
      petId: ownPet.result.id,
    });
    check(allowed.ok, "验证后发帖解锁（claim 生效路径）", allowed.ok ? allowed.result.id : allowed.message);
    await call("deletePetCallable", after, { petId: ownPet.result.id });
  }
}

async function sharedOwnership(uids) {
  scenario("S3 共同主人：邀请、加入、平等编辑、撤销邀请码");
  await clearRateLimits();
  const tokenA = await tokenFor("accept-a@example.com");
  const tokenB = await tokenFor("accept-b@example.com");
  const tokenOutsider = await tokenFor("accept-outsider@example.com");

  // A fresh pet, so the run does not depend on what a previous run left.
  const created = await call("createPetCallable", tokenA, {
    name: "Shared",
    species: "cat",
    gender: "female",
    relationship: "mom",
  });
  if (!check(created.ok, "A 建宠物", created.ok ? created.result.id : created.message)) return null;
  const petId = created.result.id;

  const invite = await call("createInvitationCallable", tokenA, { petId });
  if (!check(invite.ok, "A 生成邀请码", invite.ok ? invite.result.code : invite.message)) return null;
  const code = invite.result.code;

  const validated = await call("validateInvitationCallable", tokenB, { code });
  check(validated.ok, "B 可以校验邀请码", validated.ok ? JSON.stringify(validated.result) : validated.message);

  const redeemed = await call("redeemInvitationCallable", tokenB, { code, relationship: "dad" });
  if (!check(redeemed.ok, "B 兑换邀请码加入家庭", redeemed.ok ? redeemed.result.petName : redeemed.message)) {
    return null;
  }

  const family = await familyOf(petId);
  check(family.length === 2, "family 子集合有两名成员", `count=${family.length}`);
  const primaries = await primariesOf(petId);
  check(
    primaries.length === 1 && primaries[0] === uids.a,
    "恰好一名 primary，且仍是 A",
    JSON.stringify(primaries)
  );

  // The product core: both humans are owners, so both can edit.
  const editByA = await call("updatePetCallable", tokenA, { petId, bio: "edited by A" });
  check(editByA.ok, "A 可以编辑", editByA.ok ? "" : editByA.message);
  const editByB = await call("updatePetCallable", tokenB, { petId, bio: "edited by B" });
  check(editByB.ok, "B（非 primary 的共同主人）同样可以编辑", editByB.ok ? "" : editByB.message);
  check((await petField(petId, "bio")) === "edited by B", "B 的编辑真的落盘了");

  const postByB = await call("createPostCallable", tokenB, {
    text: "co-owner post",
    tags: [],
    media: [],
    petId,
  });
  check(postByB.ok, "B 可以为共同宠物发帖", postByB.ok ? postByB.result.id : postByB.message);

  const editByOutsider = await call("updatePetCallable", tokenOutsider, { petId, bio: "hijack" });
  expectRejected(editByOutsider, "PERMISSION_DENIED", undefined, "非成员编辑被拒");
  check((await petField(petId, "bio")) === "edited by B", "非成员的编辑没有落盘");

  // Revoke: a code that was handed out must stop working.
  const second = await call("createInvitationCallable", tokenA, { petId });
  if (second.ok) {
    const revoked = await call("revokeInvitationCallable", tokenA, { petId, code: second.result.code });
    check(revoked.ok, "A 可以撤销邀请码", revoked.ok ? "" : revoked.message);
    const afterRevoke = await call("redeemInvitationCallable", tokenOutsider, {
      code: second.result.code,
      relationship: "friend",
    });
    check(!afterRevoke.ok, "已撤销的邀请码无法再兑换", afterRevoke.ok ? "still redeemable" : afterRevoke.status);
    const stillTwo = await familyOf(petId);
    check(stillTwo.length === 2, "撤销后家庭成员数没变", `count=${stillTwo.length}`);
  } else {
    check(false, "A 生成第二个邀请码", second.message);
  }

  return petId;
}

async function transferPrimary(petId, uids) {
  scenario("S4 primary 转让：唯一性与授权");
  await clearRateLimits();
  const tokenA = await tokenFor("accept-a@example.com");
  const tokenB = await tokenFor("accept-b@example.com");
  const tokenOutsider = await tokenFor("accept-outsider@example.com");

  const toB = await call("transferPetPrimaryCallable", tokenA, { petId, targetUserId: uids.b });
  check(toB.ok, "A 把 primary 转给 B", toB.ok ? JSON.stringify(toB.result) : toB.message);
  let primaries = await primariesOf(petId);
  check(primaries.length === 1 && primaries[0] === uids.b, "转让后恰好一名 primary = B", JSON.stringify(primaries));
  const familyAfter = await familyOf(petId);
  check(familyAfter.length === 2, "A 被降级但仍是成员", `count=${familyAfter.length}`);
  check((await petField(petId, "primaryOwnerId")) === uids.b, "宠物文档的 primaryOwnerId 同步了");

  const byOutsider = await call("transferPetPrimaryCallable", tokenOutsider, { petId, targetUserId: uids.a });
  expectRejected(byOutsider, "PERMISSION_DENIED", undefined, "非成员不能转让 primary");
  primaries = await primariesOf(petId);
  check(primaries.length === 1 && primaries[0] === uids.b, "被拒后 primary 未被改动", JSON.stringify(primaries));

  // A is no longer primary and must not be able to take the role back. Note
  // what the callable actually answers: targeting yourself short-circuits to
  // `{success:true, alreadyPrimary:true}` without checking whether you are in
  // fact the primary. The *state* is what matters for authorisation, so that is
  // what is asserted; the misleading response is recorded as a finding rather
  // than asserted away.
  const byDemoted = await call("transferPetPrimaryCallable", tokenA, { petId, targetUserId: uids.a });
  primaries = await primariesOf(petId);
  check(
    primaries.length === 1 && primaries[0] === uids.b,
    "已降级的 A 无法把 primary 抢回去（状态未变）",
    `response=${JSON.stringify(byDemoted.result ?? byDemoted.status)} primaries=${JSON.stringify(primaries)}`
  );
  check(
    (await petField(petId, "primaryOwnerId")) === uids.b,
    "宠物文档的 primaryOwnerId 也未被改动"
  );

  const back = await call("transferPetPrimaryCallable", tokenB, { petId, targetUserId: uids.a });
  check(back.ok, "B 把 primary 转回 A", back.ok ? "" : back.message);
  primaries = await primariesOf(petId);
  check(primaries.length === 1 && primaries[0] === uids.a, "转回后仍恰好一名 primary = A", JSON.stringify(primaries));
}

async function leaving(petId, uids) {
  scenario("S5 退出：非最后一人可退，最后一人被拒，宠物不被误删");
  await clearRateLimits();
  const tokenA = await tokenFor("accept-a@example.com");
  const tokenB = await tokenFor("accept-b@example.com");

  const bLeaves = await call("removeFamilyMemberCallable", tokenB, { petId, targetUserId: uids.b });
  check(bLeaves.ok, "B 自行退出", bLeaves.ok ? JSON.stringify(bLeaves.result) : bLeaves.message);
  const family = await familyOf(petId);
  check(family.length === 1 && family[0].userId === uids.a, "只剩 A", JSON.stringify(family.map((m) => m.userId)));
  check((await db.doc(`pets/${petId}`).get()).exists, "宠物没有因为有人退出而被删除");
  const primaries = await primariesOf(petId);
  check(primaries.length === 1 && primaries[0] === uids.a, "A 仍是 primary", JSON.stringify(primaries));

  const lastLeaves = await call("removeFamilyMemberCallable", tokenA, { petId, targetUserId: uids.a });
  expectRejected(
    lastLeaves,
    "FAILED_PRECONDITION",
    "only owner",
    "最后一名主人退出被拒，并被告知改用删除"
  );
  check((await db.doc(`pets/${petId}`).get()).exists, "被拒后宠物仍在");

  // Take the route the refusal points at, which is also this scenario's cleanup.
  const deleted = await call("deletePetCallable", tokenA, { petId });
  check(deleted.ok, "改用删除后成功（拒绝里给的建议是可行的）", deleted.ok ? "" : deleted.message);
}

async function deletionAndRecovery(uids) {
  scenario("S6 删除与恢复");
  await clearRateLimits();
  const tokenA = await tokenFor("accept-a@example.com");
  const tokenB = await tokenFor("accept-b@example.com");
  const tokenOutsider = await tokenFor("accept-outsider@example.com");

  // A shared pet: one owner "deleting" it must only release themselves.
  const created = await call("createPetCallable", tokenA, {
    name: "Doomed",
    species: "dog",
    gender: "male",
    relationship: "dad",
  });
  if (!check(created.ok, "A 建共享宠物", created.ok ? created.result.id : created.message)) return;
  const petId = created.result.id;

  const invite = await call("createInvitationCallable", tokenA, { petId });
  if (!check(invite.ok, "生成邀请码", invite.ok ? "" : invite.message)) return;
  const joined = await call("redeemInvitationCallable", tokenB, {
    code: invite.result.code,
    relationship: "mom",
  });
  if (!check(joined.ok, "B 加入", joined.ok ? "" : joined.message)) return;

  const byOutsider = await call("deletePetCallable", tokenOutsider, { petId });
  expectRejected(byOutsider, "PERMISSION_DENIED", undefined, "非成员不能删除宠物");
  check((await db.doc(`pets/${petId}`).get()).exists, "被拒后宠物仍在");

  // One owner may not destroy a pet the others still co-own. This is the
  // complement of S5's rule: shared pet → leave; sole owner → delete. Together
  // they mean no single person can end a pet that is not only theirs, and
  // nobody can strand a pet with no owner at all.
  const aDeletes = await call("deletePetCallable", tokenA, { petId });
  expectRejected(
    aDeletes,
    "FAILED_PRECONDITION",
    "other owners",
    "共享宠物被拒绝删除，并被告知改用退出"
  );
  const survives = await db.doc(`pets/${petId}`).get();
  check(survives.exists, "被拒后宠物仍在");
  const bothStill = await familyOf(petId);
  check(bothStill.length === 2, "两名成员都还在（删除没有偷偷释放发起人）", `count=${bothStill.length}`);

  // A leaves instead — and A is the primary, so the role has to be handed over.
  const aLeaves = await call("removeFamilyMemberCallable", tokenA, { petId, targetUserId: uids.a });
  check(aLeaves.ok, "A 改用退出", aLeaves.ok ? JSON.stringify(aLeaves.result) : aLeaves.message);
  const remaining = await familyOf(petId);
  check(
    remaining.length === 1 && remaining[0].userId === uids.b && remaining[0].role === "primary",
    "只剩 B，且 primary 已自动交接给 B",
    JSON.stringify(remaining.map((m) => `${m.userId}:${m.role}`))
  );
  check((await petField(petId, "primaryOwnerId")) === uids.b, "宠物文档的 primaryOwnerId 已交接");

  const bDeletes = await call("deletePetCallable", tokenB, { petId });
  check(bDeletes.ok, "成为唯一主人的 B 可以删除", bDeletes.ok ? "" : bDeletes.message);
  const gone = await waitFor(async () => {
    const snap = await db.doc(`pets/${petId}`).get();
    return { ok: !snap.exists, value: snap.exists };
  });
  check(gone.ok, "宠物文档已删除");
  const familyGone = await familyOf(petId);
  check(familyGone.length === 0, "family 子集合已清空", `count=${familyGone.length}`);
  const taskGone = await db.doc(`petDeletionTasks/${petId}`).get();
  check(!taskGone.exists, "petDeletionTasks 记录已清除");

  // Recovery: a cascade that stopped halfway leaves a task record, and only an
  // entitled caller may finish it.
  scenario("S6b 级联部分失败后的授权恢复");
  await clearRateLimits();
  const stuckPetId = `stuck-${Date.now()}`;
  await db.doc(`pets/${stuckPetId}/family/${uids.a}`).set({ userId: uids.a, role: "primary" });
  await db.doc(`invitationCodes/stuck-${stuckPetId}`).set({ petId: stuckPetId, code: "STUCK1" });
  await db.doc(`petDeletionTasks/${stuckPetId}`).set({
    petId: stuckPetId,
    requestedBy: uids.a,
    requestedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  const byStranger = await call("deletePetCallable", tokenOutsider, { petId: stuckPetId });
  const strangerLeaked = byStranger.ok && byStranger.result?.resumed === true;
  check(!strangerLeaked, "无关账号无法恢复别人的半成品删除", JSON.stringify(byStranger.result ?? byStranger.status));
  check(
    (await db.doc(`petDeletionTasks/${stuckPetId}`).get()).exists,
    "任务记录仍在（未被无关账号推进）"
  );

  const byRequester = await call("deletePetCallable", tokenA, { petId: stuckPetId });
  check(
    byRequester.ok && byRequester.result?.resumed === true,
    "发起人可以恢复并完成删除",
    JSON.stringify(byRequester.result ?? byRequester.message)
  );
  check(!(await db.doc(`petDeletionTasks/${stuckPetId}`).get()).exists, "恢复后任务记录已清除");
  check(!(await db.doc(`pets/${stuckPetId}/family/${uids.a}`).get()).exists, "残留的 family 文档已清掉");
  check(
    !(await db.doc(`invitationCodes/stuck-${stuckPetId}`).get()).exists,
    "残留的 invitationCodes 已清掉"
  );
}

async function suspendedRepairs() {
  scenario("S7 本轮停用的三个重算入口");
  await clearRateLimits();
  const tokenAdmin = await tokenFor("accept-admin@example.com");
  const cases = [
    ["recomputePetPostCountCallable", { petId: "accept-pet" }],
    ["recomputePostInteractionCountsCallable", { postId: "any" }],
    ["recomputeLocationReviewAggregatesCallable", { locationId: "accept-place" }],
  ];
  for (const [name, data] of cases) {
    const outcome = await call(name, tokenAdmin, data);
    expectRejected(outcome, "FAILED_PRECONDITION", "temporarily unavailable", `${name} 明确拒绝管理员`);
  }
}

// ── run ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log(`Acceptance run against ${PROJECT}`);
  console.log(`  firestore ${FIRESTORE_HOST}   auth ${AUTH_HOST}   functions ${FUNCTIONS_HOST}`);

  const uids = {
    a: (await auth.getUserByEmail("accept-a@example.com")).uid,
    b: (await auth.getUserByEmail("accept-b@example.com")).uid,
    outsider: await ensureUser("accept-outsider@example.com", "Accept Outsider"),
  };
  uids.newcomer = (await auth.getUserByEmail("accept-new@example.com")).uid;
  console.log(`  A=${uids.a}  B=${uids.b}  outsider=${uids.outsider}`);
  const cleaned = await resetTestPets(uids);
  console.log(`  teardown: 清掉上一轮遗留的 ${cleaned} 只测试宠物`);

  await publishFlow(uids);
  await verificationGate();
  const sharedPetId = await sharedOwnership(uids);
  if (sharedPetId) {
    await transferPrimary(sharedPetId, uids);
    await leaving(sharedPetId, uids);
  } else {
    scenario("S4/S5 跳过");
    check(false, "共同主人场景未建立，转让与退出无法执行");
  }
  await deletionAndRecovery(uids);
  await suspendedRepairs();

  const total = results.length;
  console.log(`\n${"─".repeat(60)}`);
  console.log(`${total - failures}/${total} 断言通过`);
  if (failures > 0) {
    console.log("\n失败项：");
    for (const r of results.filter((r) => !r.ok)) {
      console.log(`  [${r.scenario}] ${r.label}`);
    }
  }
  console.log(
    "\n本次运行不构成以下任何一项的验证：真实 Google 登录、真实验证邮件往返、" +
      "真实 Cloudinary/Geoapify、iPhone 真机、触发器的至少一次与乱序投递、限流。"
  );
  process.exit(failures > 0 ? 1 : 0);
}

main().catch((error) => {
  console.error("\nAcceptance run crashed:", error);
  process.exit(2);
});
