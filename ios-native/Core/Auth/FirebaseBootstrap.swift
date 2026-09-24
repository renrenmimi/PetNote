import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OSLog

/// Configures Firebase once, for the environment this build was compiled for.
///
/// Emulator wiring happens **before** any Firestore or Functions instance is
/// created: `Firestore.settings` is ignored once the first request has gone
/// out, and a missed setting here means a debug build silently talking to
/// production.
enum FirebaseBootstrap {
    private static let log = Logger(subsystem: "dev.local.petnote.native", category: "auth")
    /// Main-actor isolated rather than a bare global: strict concurrency is
    /// right that a mutable static is shared state, and configuration only ever
    /// happens once, from the app's init, on the main actor.
    @MainActor private static var isConfigured = false

    /// True when this process was launched by XCTest to host unit tests.
    ///
    /// Unit tests are pure logic over fakes — decoding, routing, palette,
    /// view models — and none of them touch Firebase. They run in-process in
    /// the app, though, so without this the app's init configures Firebase and
    /// points it at an emulator that is not there. On CI that crashed the test
    /// runner with a SIGTRAP before a single test ran.
    ///
    /// UI tests are unaffected: they launch the app as its own process, which
    /// has no XCTest configuration in its environment, so it configures
    /// normally and really does talk to the emulator.
    private static var isUnitTestHost: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        // A shipped build is never a unit-test host, and saying so at compile
        // time keeps the environment key out of the binary. It is a test hook
        // like any other: harmless to evaluate, and still the sort of string
        // that has no business in a candidate package.
        return false
        #endif
    }

    /// False in a unit-test host, where nothing that needs a running app
    /// should start.
    @MainActor
    static var isConfiguredForRunning: Bool { !isUnitTestHost }

    @MainActor
    static func configure(_ environment: AppEnvironment = .current) {
        guard !isConfigured else { return }
        guard !isUnitTestHost else {
            log.info("unit-test host: skipping Firebase configuration")
            isConfigured = true
            return
        }
        isConfigured = true

        let plistName: String
        switch environment.backend {
        case .emulator:
            plistName = "GoogleService-Info-Emulator"
        case .testCloud:
            plistName = "GoogleService-Info-Test"
        case .production:
            plistName = "GoogleService-Info"
        }

        guard let path = Bundle.main.path(forResource: plistName, ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path) else {
            // Production builds need a GoogleService-Info.plist that is not in
            // the repository; say which file is missing rather than crashing in
            // the SDK with something less specific.
            // Must be inside a folder the project synchronises (Support/), not
            // Config/: Config is a plain group, so anything in it is visible in
            // Xcode but never copied into the bundle. That mistake crashed
            // every UI test with a SIGTRAP in this function.
            fatalError(
                "Missing \(plistName).plist for the \(environment.backend.rawValue) backend. "
                + "It belongs in ios-native/Support/."
            )
        }
        FirebaseApp.configure(options: options)

        guard environment.backend == .emulator else {
            // Memory only, as for the emulator below and as the web client
            // does. That was always the stated intent, and the cloud path
            // skipped it: its builds used the SDK's on-disk cache, which kept
            // query results — posts, profiles, notifications — on the phone
            // after sign-out (legal review, A1).
            Firestore.firestore().settings = Self.memoryOnly(Firestore.firestore().settings)
            Self.dropOnDiskCacheOnce()
            // Nothing to redirect: a cloud configuration talks to the cloud.
            // Checked here rather than before the guard below so that both
            // halves of the check — which project, and which host — always
            // run against the settings the app will actually use.
            EnvironmentGuard.enforce(environment)
            log.info("Firebase configured against \(environment.backend.rawValue, privacy: .public)")
            return
        }

        Auth.auth().useEmulator(withHost: environment.emulatorHost, port: 9099)

        let settings = Self.memoryOnly(Firestore.firestore().settings)
        settings.host = environment.firestoreHost
        settings.isSSLEnabled = false
        Firestore.firestore().settings = settings

        Functions.functions().useEmulator(withHost: environment.emulatorHost, port: environment.functionsPort)

        // After the redirect, not before. Checking the transport before the
        // emulator settings are applied would only ever read the default
        // cloud host, which is what this is supposed to catch.
        EnvironmentGuard.enforce(environment)

        log.info("Firebase configured against emulator at \(environment.emulatorHost, privacy: .public)")
    }

    /// Stage 1 matches the web client: no offline persistence, in every
    /// build. Turning it on is a later decision that needs measured benefit
    /// on a weak network.
    static func memoryOnly(_ settings: FirestoreSettings) -> FirestoreSettings {
        settings.cacheSettings = MemoryCacheSettings()
        return settings
    }

    static let droppedDiskCacheKey = "petnoteDroppedFirestoreDiskCache"

    /// Builds before this one wrote Firestore's cache to disk. Memory-only
    /// stops new writes; this removes what an earlier build left, once,
    /// before anything reads — `clearPersistence` must run before the first
    /// query, and here nothing has queried yet.
    private static func dropOnDiskCacheOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: droppedDiskCacheKey) else { return }
        Firestore.firestore().clearPersistence { error in
            if let error {
                log.error("could not drop the old on-disk cache: \(String(describing: error), privacy: .public)")
            } else {
                defaults.set(true, forKey: droppedDiskCacheKey)
                log.info("dropped the on-disk Firestore cache an earlier build left")
            }
        }
    }
}
