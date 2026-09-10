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

So the Preview target's `VITE_FIREBASE_PROJECT_ID` has to be read by a human, in
**Vercel → Project → Settings → Environment Variables**, filtered to the
*Preview* environment. Until then assume it is `petnote-a9dac`, i.e. production
data. If it is:

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

## Hands-on acceptance checklist

Three tiers. Tier 1 needs nobody; it is listed so you know what not to re-do.

### Tier 1 — already verified on the real runtime, no action needed

Recorded in `PetNote-review-20260908/REAL-RUNTIME-VERIFICATION.md`. Spot-check
any of these if you want, but they are done.

### Tier 2 — Environment A, you click through it (~20 min)

1. Sign in as `accept-a@example.com`. Confirm the emulator console line above.
2. Publish a post for Mochi **without** media (media upload needs real
   Cloudinary). Confirm Mochi's post count goes to 1.
3. Delete that post. Confirm the count goes back to 0 and does not go negative.
4. Invite `accept-b@example.com` to Mochi. Accept as B. Confirm **both** owners
   see Mochi as theirs and both can edit it — this is the equal-owners core.
5. As B, transfer primary to A, then back. Confirm there is never more than one
   primary and never zero.
6. As B, leave Mochi. Confirm A keeps the pet and it is not deleted.
7. As A, delete Mochi. Confirm the pet is gone, the family subcollection is
   empty, and any posts it had are still there with the pet fields stripped
   (this is deliberate — posts outlive pets).
8. Sign in as `accept-new@example.com` (unverified) and try to publish.
   Expect "Verify your email before posting."
9. Sign in as `accept-admin@example.com` and trigger any of the three repair
   actions. Expect an explicit "temporarily unavailable" message, not a silent
   failure and not a wrong number.
10. Block/unblock between A and B. Confirm the message is the same in both
    directions and reveals nothing about who blocked whom.

### Tier 3 — needs your Google account, your inbox, or your iPhone

None of this can be done without you, and none of it has been done.

1. **Read the Preview's Firebase project id** in the Vercel dashboard (above).
   Everything else in this tier depends on knowing the answer.
2. **Real Google popup sign-in** on the preview URL: sign in, then cancel the
   popup mid-flow, then sign in again. This is the only test of the
   `initializeAuth` / `browserPopupRedirectResolver` change.
3. **Real verification email**: sign up with a throwaway address, receive the
   mail, click the link, come back, and confirm publishing is unblocked without
   a manual reload (the token refresh path).
4. **Real media upload** through Cloudinary — production credentials only exist
   in production, so this is preview-only, and it writes real assets.
5. **iPhone Safari**: photo picker, HEIC conversion, video, geolocation prompt,
   and the composer on a real touch keyboard.

Because the preview backend is old code, treat tier 3 as verifying *frontend and
provider integration only*. Re-run tier 2 against the deployed functions after
they ship.

## Merge and deploy order, and how to get back

Frontend and backend deploy separately and the backend is not automatic, so the
order matters. Functions first, always: the new frontend calls
`getPublishStatusCallable`, which does not exist in production yet.

1. **Merge PR #195 into `main`** (squash). This deploys the **frontend** to
   production by itself, via the Vercel Git integration. Nothing deploys the
   backend.
2. **Deploy functions immediately after**, from `main`:
   ```bash
   cd functions && npm ci && npm run build && npm run deploy
   ```
   `npm run deploy` retries once and reports partial failures per function
   (added in #192). If it reports a partial failure, re-run it before doing
   anything else — a half-deployed function set is the worst state to sit in.
3. **Check the deployed rules match the file.** Never verified in any round:
   ```bash
   npx firebase deploy --only firestore:rules --project petnote-a9dac
   ```
   Deploying them is idempotent and cheaper than proving they already match.
4. **Smoke-test production** with a throwaway account: publish a post with one
   photo, check the pet's count, delete the post, check the count.

### Rolling back

- **Frontend only** — Vercel → Deployments → the previous production deployment
  → *Promote to Production*. Seconds, no rebuild.
- **Backend only** — `git revert` the merge commit on `main`, then re-run the
  functions deploy from that state. There is no "previous version" button for
  Cloud Functions.
- **Both** — revert the merge commit on `main` and push. That redeploys the old
  frontend automatically; the functions deploy is still manual.

Order matters here too, in reverse: roll the **frontend** back first. An old
frontend against new functions is fine — the new callables are additive. A new
frontend against reverted functions is not.

### Two things this branch left switched off

Neither is restored by any of the above, and both need a decision that is not
part of this PR:

- The composer's **automatic CDN reclaim**. A failed or abandoned publish now
  leaves its uploaded assets in Cloudinary. Cost: orphaned assets accumulate and
  have to be reclaimed by hand.
- All three **online recompute endpoints** (pet post count, post interaction
  counts, location rating aggregates). They return an explicit
  `failed-precondition` to admins. Cost: a counter that has genuinely drifted
  cannot be repaired from the app; it needs a script written against a known-idle
  window.
