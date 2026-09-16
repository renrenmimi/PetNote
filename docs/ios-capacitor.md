# iOS build (Capacitor)

The iOS app is the existing web app running in a native shell. The built web
assets ship **inside the app bundle** — there is no `server.url`, so an
installed build does not depend on a Vite dev server or on loading the
production website over the network. Reading posts, pets and images still
needs the network, because that content comes from Firebase and Cloudinary.

Status: development / personal-device prototype. Not TestFlight, not the
App Store. See `IPHONE-V1-PROGRESS.md` in the review folder for what has
actually been run.

## Versions this was set up against

| Component | Version |
| --- | --- |
| Capacitor (`core` / `ios` / `cli`) | 8.5.1 |
| Xcode | 26.6 (build 17F113) |
| iOS SDK | 26.5 |
| Node | 22.21.1 (`@capacitor/cli` requires >= 22) |
| Deployment target | iOS 15.0 (Capacitor 8's floor) |

Native dependencies resolve through **Swift Package Manager**, pinned to
`capacitor-swift-pm` 8.5.1 in `ios/App/App.xcodeproj/.../Package.resolved`.
CocoaPods is not used.

Xcode ships the iOS SDK but not the iOS platform support. Without it `ibtool`
fails with `iOS 26.5 Platform Not Installed` and no iOS destination — device
or simulator — is selectable. Install it once with:

```sh
xcodebuild -downloadPlatform iOS   # ~8.5 GB
```

## Build and run

`webDir` is `dist`, so the web app must be built before every sync:

```sh
npm run ios:sync          # npm run build && cap sync ios
npm run ios:open          # open the workspace in Xcode
```

To build and run on a simulator without opening Xcode:

```sh
SIM=$(xcrun simctl list devices available -j \
  | python3 -c 'import json,sys;print([d["udid"] for r in json.load(sys.stdin)["devices"].values() for d in r if d["name"]=="iPhone 17 Pro"][0])')

npm run ios:sync
xcodebuild -project ios/App/App.xcodeproj -scheme App -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIM" build
xcrun simctl boot "$SIM"
xcrun simctl install "$SIM" \
  ~/Library/Developer/Xcode/DerivedData/App-*/Build/Products/Debug-iphonesimulator/App.app
xcrun simctl launch "$SIM" dev.local.petnote
```

## Signing for a personal device

`DEVELOPMENT_TEAM` is deliberately unset in the repository, so a fresh
checkout does not carry someone else's team. To install on your own iPhone
with a **free** Apple ID:

1. Xcode → Settings → Accounts → add your Apple ID. A "Personal Team" appears.
2. Open `ios/App/App.xcodeproj`, select the `App` target → Signing &
   Capabilities → tick *Automatically manage signing* → pick the Personal Team.
3. Connect the iPhone, trust the Mac, and enable Developer Mode on the phone
   (Settings → Privacy & Security → Developer Mode; requires a restart).
4. Select the device as the run destination and press Run.

Free provisioning profiles expire after about 7 days. When the app stops
launching, rebuild and reinstall from Xcode — nothing needs to be re-registered
and no Apple Developer Program membership is involved.

## Bundle identifier

`dev.local.petnote` is a local development placeholder, not a registered App
Store identifier. Free Personal Team signing registers it under the personal
team only. Choosing the real identifier is a separate decision, and changing it
later also means revisiting anything keyed to it (Firebase iOS app, OAuth
redirect URIs, universal links).

## What the native shell does not change

Business rules, Firestore security rules and callable functions are untouched;
the app talks to the same backend as the website. Anything that depends on
browser-only behaviour — notably Google sign-in via `signInWithPopup` — needs
a real iOS adaptation before it works here.
