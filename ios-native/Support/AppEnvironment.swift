import Foundation

/// Which backend this build talks to, and how to reach it.
///
/// Read once from the bundle, which gets its values from the xcconfig for the
/// active configuration. There is deliberately no runtime switch and no `if`
/// on environment anywhere else: the Capacitor client's compile-time
/// VITE_PASSWORD_RESET_OTP taught us that a flag you cannot flip without a new
/// build is a flag you will forget is off — but the fix for that is
/// server-delivered config, not a code branch that could point a debug build
/// at production data by accident.
struct AppEnvironment: Sendable {
    enum Backend: String, Sendable {
        case emulator
        /// The independent test Firebase project: a real project over HTTPS,
        /// separate from production, used for device acceptance.
        case testCloud = "testcloud"
        case production
    }

    let backend: Backend
    /// The Mac's LAN address, as configured. Used as-is on a device; the
    /// simulator overrides it — see `emulatorHost`.
    let configuredEmulatorHost: String
    let buildStamp: String
    /// What project this build must be talking to. Empty for emulator builds.
    let expectedProjectID: String

    /// Where to reach the emulator.
    ///
    /// **The simulator uses loopback even though a LAN address would also
    /// reach the Mac.** The Functions SDK refuses to attach an auth token to
    /// an HTTP request bound for anything that is not loopback — measured, it
    /// fails the call locally with
    ///
    ///     com.firebase.functions code=16
    ///     "Refusing to send Auth, FCM, and AppCheck tokens over HTTP to
    ///      non-loopback host."
    ///
    /// and never sends a request at all. The server then never sees the
    /// caller, so every gate reports "Must be logged in", which looks exactly
    /// like a sign-in bug and is not one.
    ///
    /// The simulator shares the Mac's network stack, so 127.0.0.1 reaches the
    /// same emulator and keeps callables working.
    ///
    /// **A real device cannot do this.** It has to use the LAN address, which
    /// means callables — comments — cannot work against the emulator on a
    /// device over plain HTTP. See docs/device-emulator-limits.md.
    var emulatorHost: String {
        #if targetEnvironment(simulator)
        "127.0.0.1"
        #else
        configuredEmulatorHost
        #endif
    }

    /// False on a device against the emulator: callables are unreachable there
    /// for the reason above, so the UI can say so instead of showing a
    /// misleading "sign in" message.
    var supportsCallables: Bool {
        // The test project is HTTPS, so the SDK's plaintext-token refusal does
        // not apply — which is the whole reason for having it.
        guard backend == .emulator else { return true }
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    static let current = AppEnvironment(bundle: .main)

    init(bundle: Bundle) {
        let info = bundle.infoDictionary
        let raw = info?["PetNoteBackend"] as? String ?? ""
        backend = Backend(rawValue: raw) ?? .emulator
        configuredEmulatorHost = (info?["PetNoteEmulatorHost"] as? String) ?? "127.0.0.1"
        expectedProjectID = (info?["PetNoteExpectedProject"] as? String) ?? ""
        buildStamp = (info?["PetNoteBuildStamp"] as? String) ?? "unknown"
    }

    /// Stage 1 writes to the emulator and to the independent test project.
    /// Production stays read-only.
    /// Whether this build may write.
    ///
    /// Not `backend != .production`. Widening a rule that said "emulator only"
    /// into one that says "anything that is not production" is how a guard
    /// stops guarding: a test-cloud build with no project pinned would pass
    /// it, and what such a build actually talks to is whatever plist it
    /// happened to find.
    ///
    /// So the test cloud is allowed *by having been named*. An id has to be
    /// compiled in, and it has to not be production's. EnvironmentGuard then
    /// checks that the id Firebase really loaded matches, and that the traffic
    /// really goes where that id lives.
    ///
    /// Honest note: nothing in the app reads this yet. It is asserted in tests
    /// and is the rule the seed script enforces independently. Saying so here
    /// because a flag that looks load-bearing and is not — `supportsCallables`
    /// was exactly that — misleads the next person more than its absence would.
    var allowsWrites: Bool {
        switch backend {
        case .emulator:
            return true
        case .testCloud:
            return !expectedProjectID.isEmpty
                && expectedProjectID != EnvironmentGuard.productionProjectID
        case .production:
            return false
        }
    }

    var firestoreHost: String { "\(emulatorHost):8088" }
    var authHost: String { "\(emulatorHost):9099" }
    var functionsHost: String { emulatorHost }
    var functionsPort: Int { 5101 }
}
