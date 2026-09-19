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
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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
        // Before anything reads or writes: a build pointed at the wrong project
        // stops here rather than finding out later.
        EnvironmentGuard.enforce(environment)

        guard environment.backend == .emulator else {
            log.info("Firebase configured against production, read-only")
            return
        }

        Auth.auth().useEmulator(withHost: environment.emulatorHost, port: 9099)

        let settings = Firestore.firestore().settings
        settings.host = environment.firestoreHost
        settings.isSSLEnabled = false
        // Stage 1 matches the web client: no offline persistence. Turning it on
        // is a later decision that needs measured benefit on a weak network.
        settings.cacheSettings = MemoryCacheSettings()
        Firestore.firestore().settings = settings

        Functions.functions().useEmulator(withHost: environment.emulatorHost, port: environment.functionsPort)

        log.info("Firebase configured against emulator at \(environment.emulatorHost, privacy: .public)")
    }
}
