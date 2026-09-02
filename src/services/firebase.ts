import { initializeApp } from "firebase/app";
import {
  initializeAppCheck,
  ReCaptchaEnterpriseProvider,
} from "firebase/app-check";
import { getAuth } from "firebase/auth";
import { getFunctions } from "firebase/functions";
import { getFirestore } from "firebase/firestore";

const requiredEnv = {
  VITE_FIREBASE_API_KEY: import.meta.env.VITE_FIREBASE_API_KEY,
  VITE_FIREBASE_AUTH_DOMAIN: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
  VITE_FIREBASE_PROJECT_ID: import.meta.env.VITE_FIREBASE_PROJECT_ID,
  VITE_FIREBASE_STORAGE_BUCKET: import.meta.env.VITE_FIREBASE_STORAGE_BUCKET,
  VITE_FIREBASE_MESSAGING_SENDER_ID: import.meta.env
    .VITE_FIREBASE_MESSAGING_SENDER_ID,
  VITE_FIREBASE_APP_ID: import.meta.env.VITE_FIREBASE_APP_ID,
};

const missing = Object.entries(requiredEnv)
  .filter(([, value]) => typeof value !== "string" || value.length === 0)
  .map(([key]) => key);

if (missing.length > 0) {
  // Fail loudly at startup rather than silently initialising Firebase with
  // undefined fields and blowing up deep inside a Firestore call later.
  throw new Error(
    `Missing required Firebase env vars: ${missing.join(", ")}. Copy .env.example to .env.local and fill them in.`
  );
}

const firebaseConfig = {
  apiKey: requiredEnv.VITE_FIREBASE_API_KEY,
  authDomain: requiredEnv.VITE_FIREBASE_AUTH_DOMAIN,
  projectId: requiredEnv.VITE_FIREBASE_PROJECT_ID,
  storageBucket: requiredEnv.VITE_FIREBASE_STORAGE_BUCKET,
  messagingSenderId: requiredEnv.VITE_FIREBASE_MESSAGING_SENDER_ID,
  appId: requiredEnv.VITE_FIREBASE_APP_ID,
};

const app = initializeApp(firebaseConfig);

// App Check attests that a request came from this app rather than from a script
// hitting the API directly. It sits above the per-uid rate limiting in
// shared.ts, which is transactional and works well but can only throttle
// requests that already carry a real uid.
//
// Deliberately optional and deliberately unenforced. Firebase's own rollout
// order is: attach the provider, watch the valid/invalid split against real
// traffic, and only then turn enforcement on, one surface at a time. Turning
// enforcement on first locks out every client that has not shipped a token yet
// — including anyone running cached JS.
//
// With no site key set this is a no-op, which is what every environment does
// until a reCAPTCHA Enterprise key exists in the Firebase console. Nothing
// server-side sets enforceAppCheck yet, so an absent or invalid token changes
// nothing about whether a request succeeds.
//
// Must run before the first Firestore or callable request so the SDK can
// attach a token to it, which is why it sits above the getters below.
const appCheckSiteKey = import.meta.env.VITE_FIREBASE_APPCHECK_SITE_KEY;
const appCheckDebugToken = import.meta.env.VITE_FIREBASE_APPCHECK_DEBUG_TOKEN;

if (typeof appCheckSiteKey === "string" && appCheckSiteKey.length > 0) {
  if (import.meta.env.DEV && typeof appCheckDebugToken === "string" && appCheckDebugToken.length > 0) {
    // reCAPTCHA Enterprise cannot attest localhost, so development uses a debug
    // token registered in the console instead. Guarded on DEV so a debug token
    // can never be shipped in a production bundle.
    (
      globalThis as unknown as { FIREBASE_APPCHECK_DEBUG_TOKEN?: string }
    ).FIREBASE_APPCHECK_DEBUG_TOKEN = appCheckDebugToken;
  }

  try {
    initializeAppCheck(app, {
      provider: new ReCaptchaEnterpriseProvider(appCheckSiteKey),
      isTokenAutoRefreshEnabled: true,
    });
  } catch (error) {
    // Only catches a synchronous construction failure — a malformed key, or the
    // provider refusing to build. A key that is well-formed but wrong fails
    // later and asynchronously, when the SDK tries to exchange it for a token,
    // and the SDK swallows that itself.
    //
    // Either way the app must still boot. Verified in a headless browser: built
    // with a deliberately bogus site key, the full UI renders with no uncaught
    // exceptions. While enforcement is off a missing token costs nothing, and
    // taking the site down over an attestation provider would be worse than
    // what it guards against.
    console.error("App Check failed to initialise; continuing without it", error);
  }
}

export const auth = getAuth(app);
export const db = getFirestore(app);
export const functions = getFunctions(app);
