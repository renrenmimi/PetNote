import type { CapacitorConfig } from "@capacitor/cli";

const config: CapacitorConfig = {
  // Local development placeholder, deliberately not a registered App Store
  // identifier. Free Personal Team signing registers this under the personal
  // team only; choosing the real identifier is a separate decision.
  appId: "dev.local.petnote",
  appName: "PetNote",
  // The built web app ships inside the bundle. No server.url on purpose: a
  // device build must not be a shell that loads the production website.
  webDir: "dist",
};

export default config;
