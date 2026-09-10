# Acceptance environment for `fix/review-20260908`

For clicking through the acceptance checklist against **this branch's** frontend
*and* backend. PR [#195](https://github.com/renrenmimi/PetNote/pull/195).

## Why there are two environments, not one

The branch's Cloud Functions are not deployed anywhere. Functions are deployed
by hand (`npm run deploy` in `functions/`), never by CI, so the Vercel preview
serves the **new frontend against the old production backend**. That is not a
valid acceptance environment for anything that touches a callable — and almost
everything does.

The obvious fix, running the functions locally, does not work either. The
Firebase functions emulator cannot run this codebase: firebase-tools 15.13.0
stubs `firebase-admin` through a proxy that does `value.bind(target)` on
`admin.firestore`, `bind()` drops a function's own properties, so
`admin.firestore.FieldValue` is `undefined` inside its runtime. Every
authenticated callable calls `assertRateLimit`, which calls
`FieldValue.serverTimestamp()`, so every one of them returns 500. Reproduced
against this checkout on 2026-09-09:

```
TypeError: Cannot read properties of undefined (reading 'serverTimestamp')
  at functions/lib/shared.js:384
  at assertRateLimit (functions/lib/shared.js:367)
  at .../firebase-tools/lib/emulator/functionsEmulatorRuntime.js:399
```

That is an upstream bug. Fixing it properly means importing `FieldValue` and
`Timestamp` from the `firebase-admin/firestore` subpath, which firebase-tools
does not stub — **95 call sites across 12 modules**, which is not a change to
make inside an already-accepted review branch.

So `functions/scripts/callable-shim.mjs` speaks the callable HTTP protocol and
drives the compiled handlers through the `.run()` hook, which is the same
mechanism the 200 backend tests use. It is a test harness. It exercises handler
logic and client wiring against the real Firestore and Auth emulators; it is
**not** the Cloud Functions runtime — no cold starts, no Secret Manager
mounting, no per-function memory, timeout or IAM. A missing secret binding is
exactly the class of bug it cannot catch.

| | Environment A — local, isolated | Environment B — Vercel preview |
|---|---|---|
| Frontend | this branch | this branch |
| Backend | this branch, via the shim | **production, old code** |
| Data | emulator, disposable | **production Firestore/Auth** |
| Use it for | everything that writes, deletes, or calls a callable | real Google popup, real verification email, iPhone interactions |
| Never use it for | — | **any delete test, any shared-pet test, any account deletion** |

## Environment A — local and isolated

Three terminals. Nothing here can reach production: the emulators are local and
the seed script refuses any project that is not `petnote-test` or `demo-*`.

```bash
# 1 — emulators
export JAVA_HOME=/opt/homebrew/opt/openjdk
export PATH="$JAVA_HOME/bin:$PATH"
npx firebase emulators:start --only firestore,auth --project petnote-test

# 2 — this branch's callables and triggers
cd functions && npm run build && node scripts/callable-shim.mjs
node scripts/seed-acceptance.mjs      # once the shim is up

# 3 — the frontend
VITE_FIREBASE_EMULATORS=1 npm run dev
```

Open **http://localhost:5173**. The console prints
`[PetNote] Firebase emulators: … No production data is reachable.` — if that
line is missing, stop: you are pointed at production.

The emulator wiring is `import.meta.env.DEV`-gated, so it is statically removed
from production builds; verified absent from `dist/` (`VITE_FIREBASE_EMULATORS`
does not appear in any shipped chunk).

### Seeded accounts — password `Passw0rd!x`

| account | state | for |
|---|---|---|
| `accept-a@example.com` | verified, owns pet "Mochi" | owner side of everything |
| `accept-b@example.com` | verified | co-owner to invite |
| `accept-new@example.com` | **unverified** | the verification gate |
| `accept-admin@example.com` | verified, admin | the suspended repair messages |

Also seeded: pet `accept-pet` ("Mochi") and location `accept-place`
("Acceptance Park"), so place flows have a target without going through
Geoapify.

Re-run the seed script any time to reset the accounts; `firebase emulators:start`
without `--import` starts empty, which is the fastest full reset.

### What Environment A cannot do

- **Media upload, and therefore publishing a post.** The composer requires at
  least one file, and the upload needs a real Cloudinary signature. The shim
  runs with obviously fake Cloudinary secrets, so Cloudinary refuses the
  upload. To exercise publishing locally, export real values before starting
  the shim:
  ```bash
  CLOUDINARY_API_KEY=… CLOUDINARY_API_SECRET=… node scripts/callable-shim.mjs
  ```
  That writes **real assets to the production Cloudinary account**. Uploads
  only — no delete path is reachable, since the composer's automatic reclaim is
  suspended — but those assets will persist. Your call.
- **Real Google sign-in.** The Auth emulator simulates the provider, so it does
  not exercise the `initializeAuth`/`browserPopupRedirectResolver` change.
- **Real verification email.** The emulator does not send mail; the link is
  only available from its own API.
- **Scheduled functions.** `resumeAbandonedPetDeletions` is not driven. Invoke
  it by hand if it needs exercising.
- **Trigger delivery semantics.** The shim delivers each change once, in order.
  Production guarantees at-least-once and no ordering; the 200 backend tests
  are what cover redelivery and out-of-order cases.

## Environment B — Vercel preview

Vercel mints a new preview URL per commit, so take the current one from the
**Vercel check on PR #195** ("Deployment has completed" → *Details*) rather
than from a link written down here.

Deployment protection is on — a preview URL returns 302 to a sign-in — so open
it while signed in to the Vercel account that owns the project.

**Before using it, check in Vercel → Project → Settings → Environment Variables
which Firebase project the Preview environment points at.** It could not be
determined from outside, and it should be assumed to be production until
checked. If it is production:

- Use a throwaway account, not a real one.
- Do not delete anything: no account deletion, no pet deletion, no leaving a
  shared pet, no removing a family member.
- Remember the backend is the **old** code. A shared-pet or blocking result
  there says nothing about this branch, and `getPublishStatusCallable` does not
  exist yet (the composer only uses it for an informational toast and swallows
  the failure, so nothing breaks).

Pushing this branch does **not** trigger a production deploy: every historical
`Production` deployment targeted a commit on `main`, every other ref gets a
`Preview`, and `ci.yml` contains no deploy step.
