# Acceptance environment for `fix/review-20260908`

For clicking through the acceptance checklist against **this branch's** frontend
*and* backend. PR [#195](https://github.com/renrenmimi/PetNote/pull/195).

## Which environment runs which code

| | Environment A — local | Environment B — Vercel preview |
|---|---|---|
| Frontend | this branch | this branch |
| Backend | **this branch, real Cloud Functions emulator** | **production, old code** |
| Data | emulator, disposable | unverified — assume production |
| Use it for | everything that writes, deletes, or calls a callable | real Google popup, real verification email, iPhone interactions |
| Never use it for | — | **any delete test, any shared-pet test, any account deletion** |

The branch's Cloud Functions are not deployed anywhere. Functions are deployed
by hand (`npm run deploy` in `functions/`), never by CI — `ci.yml` has no deploy
step — so the Vercel preview serves the **new frontend against the old
production backend**. Nothing about a callable, a trigger or a counter can be
accepted there.

## Environment A — local, and it is the real runtime

Two terminals.

```bash
# 0 — once per checkout: fake secrets for the five functions that declare them.
#     Gitignored on purpose, so a fresh clone has to write it. Never real values.
cat > functions/.secret.local <<'SECRETS'
CLOUDINARY_API_KEY=emulator-fake-key
CLOUDINARY_API_SECRET=emulator-fake-secret
GEOAPIFY_API_KEY=emulator-fake-key
SECRETS

# 1 — emulators: Firestore, Auth, Cloud Functions, Pub/Sub
export JAVA_HOME=/opt/homebrew/opt/openjdk
export PATH="$JAVA_HOME/bin:$PATH"
cd functions && npm run build && cd ..
npx firebase emulators:start --only firestore,auth,functions,pubsub --project petnote-test

# 2 — seed, then the frontend
cd functions && node scripts/seed-acceptance.mjs && cd ..
VITE_FIREBASE_EMULATORS=1 npm run dev
```

Open **http://localhost:5173**. The console prints

```
[PetNote] Firebase emulators: auth :9099, firestore :8088, callables :5101 (host 127.0.0.1).
No production Firebase project is reachable. Cloudinary and Geoapify are NOT emulated.
```

If that line is missing, stop: you are pointed at production. The wiring is
`import.meta.env.DEV`-gated so it is statically removed from production builds;
verified absent from `dist/`.

Ports come from `firebase.json`, which pins the functions emulator to **5101** —
the same port `src/services/firebase.ts` already wires callables to, so nothing
in the app has to change.

### This used to be impossible, and why it now works

firebase-tools proxies `firebase-admin` and answers every `admin.firestore`
access with `admin.firestore.bind(module)`. `bind()` returns a function that
carries none of the original's own properties, so inside its runtime
`admin.firestore.FieldValue` was `undefined`. Every authenticated callable
reaches `assertRateLimit`, which calls `FieldValue.serverTimestamp()`, so every
one of them returned 500 and the emulator was unusable:

```
TypeError: Cannot read properties of undefined (reading 'serverTimestamp')
  at functions/lib/shared.js:384
  at assertRateLimit (functions/lib/shared.js:367)
  at .../firebase-tools/lib/emulator/functionsEmulatorRuntime.js:399
```

`functions/src/platform.ts` now takes `FieldValue`, `Timestamp` and `FieldPath`
from the `firebase-admin/firestore` subpath, which firebase-tools does not stub
(it swaps `require.cache` for the package's main entry only), and every module
imports them from there. These are the *same objects* —
`require("firebase-admin/firestore").FieldValue === admin.firestore.FieldValue`
is `true` — so production behaviour is unchanged by construction, not merely by
argument. `src/__tests__/emulator-compat.test.ts` asserts both that identity and
that no source file reads them off the namespace again, because one innocent
`admin.firestore.FieldValue.serverTimestamp()` would take the real runtime away
without failing any behavioural test.

The emulator loads all 67 functions: 44 HTTP, 20 Firestore triggers, 3
scheduled.

### Seeded accounts — password `Passw0rd!x`

| account | state | for |
|---|---|---|
| `accept-a@example.com` | verified, owns pet "Mochi" | owner side of everything |
| `accept-b@example.com` | verified | co-owner to invite |
| `accept-new@example.com` | **unverified** | the verification gate |
| `accept-admin@example.com` | verified, admin | the suspended repair messages |

Also seeded: pet `accept-pet` ("Mochi") and location `accept-place`
("Acceptance Park"), so place flows have a target without going through
Geoapify. Re-run the seed script any time to reset; starting
`emulators:start` without `--import` is the fastest full reset.

### What Environment A still cannot do

- **Real Cloudinary, and therefore a real media upload.** `.secret.local` holds
  `emulator-fake-key` / `emulator-fake-secret`, and the real runtime mounts
  exactly those, so `getCloudinaryUploadSignature` returns a well-formed
  signature that Cloudinary itself will reject. Composing a post *with media*
  therefore stops at the upload. Posts without media go through the callable
  fine, which is how the trigger and counter paths were exercised.

  Do **not** put production Cloudinary credentials in `.secret.local`. See
  "About CDN deletion" below for why that is worse than it looks.
- **Real Geoapify.** Same mechanism; `searchAddressesCallable` and
  `reverseGeocodeCallable` have a fake key. Use the seeded `accept-place`.
- **Real Google sign-in.** The Auth emulator simulates the provider, so it does
  not exercise the `initializeAuth`/`browserPopupRedirectResolver` change.
- **Real verification email.** The emulator does not send mail; the link is only
  available from its own API. The *gate* is verified — an unverified account
  gets `PERMISSION_DENIED "Verify your email before posting."` from the real
  runtime — but the round trip through an inbox is not.
- **Scheduled functions actually firing.** The three `onSchedule` functions
  register correctly (`pubsub function initialized`, topics
  `firebase-schedule-*` created), which proves they load and their schedule
  declarations are valid. They cannot be *invoked* on demand: publishing to the
  topic gets the message acked without execution, and
  `POST /functions/projects/{p}/triggers/{id}` returns 404. So
  `resumeAbandonedPetDeletions` running on its own timer is still unverified.
  Its body is one `runPetCascade` loop over `petDeletionTasks`, and that cascade
  *is* verified on the real runtime through `deletePetCallable`'s resume path
  plus the 7 tests in `pet-deletion-recovery.test.ts`.
- **Trigger delivery semantics.** The emulator delivers each change once, in
  order. Production guarantees at-least-once and no ordering; the 202 backend
  tests are what cover redelivery and out-of-order cases.

### About CDN deletion — correcting an earlier claim

An earlier version of this document said the local backend was "uploads only —
no delete path is reachable". That was wrong, and the shape of the mistake
matters more than the sentence:

- `functions/src/index.ts` exports `deleteCloudinaryAssetsCallable`;
  `functions/src/media.ts:219` posts to Cloudinary's `/destroy`; eight frontend
  files still call `deleteCloudinaryAssets` (AddPlace, AddPet, EditProfile and
  others). Suspending the *composer's automatic reclaim* removed one caller, not
  the capability.
- The real functions emulator serves that callable like any other. With real
  credentials in `.secret.local` it would delete real production assets.

So: keep the placeholder credentials. If a real upload has to be exercised, use
a separate test Cloudinary account and set its cloud name too — note that
`CLOUDINARY_CLOUD_NAME` is a compile-time constant in `platform.ts`, not an
environment variable, so that is a code edit, not a configuration one.

### The callable shim is now a fallback only

`functions/scripts/callable-shim.mjs` speaks the callable HTTP protocol and
drives compiled handlers through `.run()`. It exists only in case firebase-tools
regresses again. It binds the same port 5101, so it and the emulator cannot both
be up — whichever answers is unambiguous — but it is **not** the Cloud Functions
runtime: no cold starts, no Secret Manager mounting, no per-function memory,
timeout or IAM. It refuses to start unless the Cloudinary variables equal its
own placeholders, and it does not serve `deleteCloudinaryAssetsCallable` at all
(HTTP 501). Prefer the emulator; results from the shim are not runtime evidence.

### Do not run the test suite against a live trigger backend

`functions/npm test` writes to the same Firestore emulator. If a backend with
trigger listeners attached — the real functions emulator, or the shim — is up on
that emulator, its triggers fire on test writes and **21 of the 202 tests fail
on inflated counters**. This is not a real failure and it is easy to misread as
one.

Use `npm run test:emulator` from `functions/`, which starts its own clean
`firestore,auth` pair, and stop the acceptance emulator first. CI is unaffected:
it runs `--only firestore,auth` and never starts functions.

## Environment B — Vercel preview

Vercel mints a new preview URL per commit, so take the current one from the
**Vercel check on PR #195** ("Deployment has completed" → *Details*).

Deployment protection is on: the root path *and every static asset* return 302
to a sign-in. Open it while signed in to the Vercel account that owns the
project.

### Which Firebase project it talks to — still unverified

What is established:

- The **production** frontend at `https://petnote.vercel.app` uses
  `petnote-a9dac` (read out of the public `assets/index-*.js` bundle).
- `.firebaserc` names exactly one project, `petnote-a9dac`. There is no staging
  or preview Firebase project anywhere in this repo.
- The preview's own bundle cannot be read: deployment protection 302s
  unauthenticated asset requests too.
- The Vercel CLI token cached on this machine is rejected
  (`{"error":{"code":"forbidden","invalidToken":true}}`), so the project's
  environment variables could not be queried either.

Narrowed by elimination, read-only: `firebase projects:list` shows exactly one
PetNote project on this account (`petnote-a9dac`; the rest are codelabs and
unrelated work), and `petnote-a9dac` has exactly one web app. So the Preview
either points at `petnote-a9dac` or has no Firebase config at all, in which case
the app would not start. That is not the same as having read it, so it stays
listed as unverified — but its only consequence is whether hand-testing the
preview could touch production data, and the acceptance is automated against the
local emulator instead.

Reading it directly needs a human in **Vercel → Project → Settings →
Environment Variables**, filtered to the *Preview* environment. Nothing in the
release path depends on that, so it is not worth interrupting anyone for. It
only matters if somebody does decide to hand-test a preview, in which case treat
it as production data:

- Use a throwaway account, not a real one.
- Delete nothing: no account deletion, no pet deletion, no leaving a shared pet,
  no removing a family member.
- Remember the backend is the **old** code. A shared-pet or blocking result
  there says nothing about this branch, and `getPublishStatusCallable` does not
  exist yet (the composer only uses it for an informational toast and swallows
  the failure, so nothing visibly breaks).

Pushing this branch does **not** trigger a production deploy: every historical
`Production` deployment targeted a commit on `main`, every other ref gets a
`Preview`, and `ci.yml` contains no deploy step.

## Acceptance, and what it did not cover

`functions/scripts/acceptance-run.mjs` drives the scenarios against the real
Cloud Functions emulator over the callable HTTP protocol, with real ID tokens,
asserting outcomes by reading Firestore. **68/68, repeatable across three
consecutive runs.** Run it yourself:

```bash
cd functions && node scripts/seed-acceptance.mjs && node scripts/acceptance-run.mjs
```

It covers the shared-owner lifecycle (invite, validate, redeem, equal editing by
both owners, revoke a code, transfer primary in both directions, leave, refuse
the last owner's leave, refuse deleting a shared pet, hand the primary role over
on leave, delete as sole owner, resume a half-finished cascade with and without
entitlement), the email-verification gate, the publish flow (counter, idempotent
replay, tag contract, delete back to zero), and the three suspended repairs.

The script tears down its own pets first, because pets are capped at 5 per owner
and the scenarios legitimately leave one behind — without that, the second run
of the day fails on `Maximum 5 pets allowed` and it looks like a defect in the
invite flow.

Two product rules are worth stating, because reading the code the wrong way gets
them backwards: **a shared pet cannot be deleted** (you leave instead), and **a
sole owner cannot leave** (you delete instead). Together: nobody can end a pet
that is not only theirs, and nobody can strand a pet with no owner.

### What no amount of this run establishes

- **Real Google popup sign-in.** The Auth emulator simulates the provider, so
  the `initializeAuth` / `browserPopupRedirectResolver` change is not exercised.
  This is the highest remaining risk in the branch: if it is broken, nobody
  using Google can sign in. It is also visible on the production home page in
  one click, and a frontend rollback is a Vercel *Promote*, so the exposure is
  short.
- **The real verification-email round trip.** The gate itself is verified, and
  so is the claim-refresh mechanism (flip `emailVerified`, re-mint a token,
  publishing unblocks). Mail delivery and the timing of the token refresh after
  clicking the link are not.
- **Real Cloudinary and Geoapify.** Fake credentials by design. The signing
  callable is verified end to end against them, which proves the secret binding,
  not the CDN round trip.
- **iPhone.** No device.
- **Scheduled functions actually firing.** See "What Environment A still cannot
  do" above.
- **At-least-once and out-of-order trigger delivery.** The emulator delivers
  once, in order; the 202 backend tests are what cover redelivery.
- **Rate limiting.** The script clears the counters so runs are deterministic.
- **Index sufficiency.** The Firestore emulator creates indexes on demand, so a
  green run says nothing about production indexes. Those were checked separately
  and read-only; see below.

## Merge and deploy order

**Functions first, from the branch, before merging.** Merging is what deploys
the frontend, so "merge then deploy functions" puts a frontend in production
that calls two callables which do not exist yet.

Verified read-only against production: **63 functions are deployed, this branch
exports 67**, the difference is entirely additive, and of the four new ones two
are live buttons in this branch's frontend with **zero callers in `main`'s** —
`transferPetPrimaryCallable` (`FamilyManageModal.tsx:70`) and
`revokeInvitationCallable` (`InviteCodeModal.tsx:129`). So old-frontend-plus-new-functions
is a usable intermediate state; new-frontend-plus-old-functions is not.

1. **Deploy functions from the branch.**
   ```bash
   git checkout fix/review-20260908 && git pull
   cd functions && npm ci && npm run build && npm run deploy
   ```
   Do **not** pass `--force`; nothing needs deleting. If it reports a partial
   failure, re-run before going further — half-deployed is the worst state to
   sit in. Two behaviours change for the still-live old frontend: tags
   containing `. * ~ / [ ]` now fail the whole post (neither frontend filters
   them client-side, so this is the new behaviour arriving early, not a
   window-specific regression), and the three repairs start refusing admins
   (no caller in `src/`).
2. **Merge PR #195** (squash). Vercel deploys the frontend from `main`.
3. **Do not deploy rules.** The live ruleset
   (`acea436f-2601-4bf9-a7c0-55605c8b444b`) is byte-identical to both
   `origin/main:firestore.rules` and this branch's, and this branch changes no
   rules. Verified with a read-only `GET` against `firebaserules.googleapis.com`.
4. **Do not deploy indexes.** The 25 indexes match item for item, `queryScope`
   included, and this branch changes none. More importantly, production has
   three `fieldOverrides` the repo file does not: the `admin.banned`
   collection-group index and TTL policies on `processedEvents.expiresAt` and
   `userDeletionTombstones.expiresAt`. An index deploy offers to delete what the
   file omits, and `--force` would take out the ban check and both TTL cleanups.
   The reason to skip this step is not that it is unnecessary — it is that it is
   harmful.
5. **Smoke-test with a throwaway account:** publish a post with one photo, check
   the pet's count, delete it, check the count. The photo is also the first real
   Cloudinary verification there has ever been.
6. **Try Google sign-in once.** The one thing automation cannot reach and the
   one whose failure is worst.

Prerequisites confirmed read-only: `CLOUDINARY_API_KEY`, `CLOUDINARY_API_SECRET`
and `GEOAPIFY_API_KEY` all exist and are `ENABLED` in production Secret Manager
(metadata only — no values were read), so the five secret-declaring functions
will not fail to deploy.

### Rolling back

Reverse order: **frontend first.**

- **Frontend** — Vercel → Deployments → the previous production deployment →
  *Promote to Production*. Seconds, no rebuild. Because the functions are purely
  additive, **this alone fully restores the old behaviour**; the four extra
  functions simply sit unused. No backend action is needed for a
  frontend-caused problem.
- **A function itself** — `git revert` on `main` and re-run the functions
  deploy. Cloud Functions has no rollback button. Still do not use `--force` to
  remove the four new functions; leaving them idle beats risking a prune.
- Rules and indexes are not in the deploy list, so they are not in the rollback
  list either.

### Two things this branch left switched off

Neither is restored by any of the above, and both need a decision that is not
part of this PR:

- The composer's **automatic CDN reclaim**. A failed or abandoned publish now
  leaves its uploaded assets in Cloudinary. Cost: orphaned assets accumulate and
  have to be reclaimed by hand.
- All three **online recompute endpoints** (pet post count, post interaction
  counts, location rating aggregates). They return an explicit
  `failed-precondition` to admins. Cost: a counter that has genuinely drifted
  cannot be repaired from the app; it needs a script written against a
  known-idle window.
