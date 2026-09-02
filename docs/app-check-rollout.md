# App Check rollout

Server-side rate limiting already exists — `assertRateLimit` in
`functions/src/shared.ts` is transactional and keyed by uid plus action, and it
works. But it can only throttle a request that already carries a real uid. App
Check is the layer above it: it attests that a request came from this app at
all, rather than from a script holding a stolen ID token or hitting the API
directly.

The client integration has shipped **unenforced**. Nothing server-side sets
`enforceAppCheck`, and with no site key configured App Check does not initialise
at all. That is deliberate and it is step 1 of 3.

**Do not skip to step 3.** Turning enforcement on before you have watched real
traffic locks out every client that has not shipped a token yet — including
anyone running JS cached from before the key was configured, and any surface you
forgot to attach the provider to. The failure mode is every request from real
users being rejected, with no gradual signal first.

---

## Step 1 — attach the provider, unenforced

Already implemented in `src/services/firebase.ts`. It is inert until you set a
key.

1. In the Google Cloud console, create a **reCAPTCHA Enterprise** key of type
   **Website**, with `petnote.vercel.app` in the allowed domains. Add
   `localhost` too if you want it to work in `npm run dev` without a debug
   token.
2. In the Firebase console, under **App Check → Apps**, register the web app
   with that key.
3. Set `VITE_FIREBASE_APPCHECK_SITE_KEY` in Vercel's environment variables and
   redeploy. The site key is public — it ships in the client bundle by design,
   which is why it is a `VITE_` variable. The reCAPTCHA *secret* is never used
   here.

For local development, reCAPTCHA Enterprise cannot attest `localhost`. Register
a debug token in **App Check → Apps → Manage debug tokens** and put it in
`.env.local` as `VITE_FIREBASE_APPCHECK_DEBUG_TOKEN`. It is only read when
`import.meta.env.DEV` is true, so it cannot reach a production bundle.

Verify: the browser console should show no App Check errors, and
**App Check → APIs** in the Firebase console should start showing requests.

---

## Step 2 — watch, and do nothing else

Leave it alone for at least a week of real traffic. In **App Check → APIs**,
each of Firestore, Cloud Functions and Identity Toolkit reports a split of
verified / unverified / outdated-client requests.

You are waiting for verified requests to reach essentially all of them. What you
are looking for:

- **Unverified requests that are actually yours.** A surface you forgot, a
  service worker, anything that talks to Firebase outside
  `src/services/firebase.ts`.
- **Outdated clients.** Users on a cached bundle from before step 1. This
  number only falls as they reload; enforcing while it is high locks them out.
- **A stable floor of unverified requests that are not yours.** That is the
  traffic App Check exists to stop, and its size tells you whether enforcement
  is worth the risk at all.

Do not enforce while any of those is unresolved.

---

## Step 3 — enforce, one surface at a time

In **App Check → APIs**, enforce in this order, leaving a few days between each
so a regression is attributable:

1. **Cloud Functions.** Smallest blast radius and the highest-value target —
   40 callables, several of them writes. On the server, add
   `{ enforceAppCheck: true }` to the `onCall` options once the console setting
   is on.
2. **Cloud Firestore.** Affects every direct client read and write, including
   likes, bookmarks and settings. Rules keep working exactly as they do now;
   this only adds a requirement that the request be attested.
3. **Authentication.** Last, because getting it wrong stops people signing in,
   and a signed-out user cannot report the problem through the in-app form.

After each one, check the console for a jump in rejected requests, and roll back
that surface if you see it. Enforcement is a toggle, not a deploy.

---

## What this does not do

App Check attests the *app*, not the *user*. It does not replace
`assertRateLimit`, the field allowlists in `firestore.rules`, or the ban checks
in the callables — a genuine user of the real app is fully attested while doing
something they should not be allowed to do. It raises the cost of automated
abuse from outside the app; it is not a permission system.
