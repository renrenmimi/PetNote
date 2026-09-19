import FirebaseCore
import FirebaseFirestore
import Foundation
import OSLog

/// Refuses to run against the wrong backend.
///
/// The failure this prevents is specific and has a name: a build that was meant
/// for the test project, missing its `GoogleService-Info`, silently falling
/// back to whatever plist it can find — and that plist being production's. The
/// app would look fine and write to real users' data.
///
/// So the expected project id is compiled in, and what Firebase actually
/// loaded is compared against it at launch. They disagree, the app stops.
///
/// Identity is not enough on its own, though. A project id says *who* we
/// claim to be, not *where the bytes go*. Two builds can agree on the id and
/// still talk to different machines:
///
///   - an emulator build whose host settings failed to apply reaches
///     `firestore.googleapis.com` — the real cloud — under a name that looks
///     local;
///   - a test-cloud build that still has the emulator host set never leaves
///     the Mac, and every "cloud" result it reports is worthless.
///
/// Neither is caught by comparing ids. So the transport is checked too.
enum EnvironmentGuard {
    private static let log = Logger(subsystem: "dev.local.petnote.native", category: "auth")

    /// Production's project id, hardcoded so it can be recognised and refused
    /// anywhere it is not wanted. It is not a secret — it is in every web
    /// bundle — and having it named here is what lets the check be explicit.
    static let productionProjectID = "petnote-a9dac"

    /// The id the *local emulator* runs under.
    ///
    /// It is named here for one reason: a cloud test project must never be
    /// given this id. If both used the same string, no log line, no crash
    /// report and no check in this file could tell "ran locally" apart from
    /// "ran in the cloud", and the whole point of a separate test environment
    /// is to know which one produced a result.
    static let emulatorProjectID = "petnote-test"

    /// What Firestore's `host` is when no emulator has been configured.
    static let cloudFirestoreHost = "firestore.googleapis.com"

    enum Verdict: Equatable {
        case ok(projectID: String)
        /// Expected one project, Firebase loaded another.
        case mismatch(expected: String, actual: String)
        /// A non-production build ended up pointed at production.
        case unexpectedProduction(backend: String)
        /// A cloud build loaded the emulator's plist, or the other way round.
        /// The id is not production's, so the check above misses it.
        case confusedWithEmulator(backend: String)
        /// The id is right and the bytes still go somewhere else.
        case wrongTransport(backend: String, expected: String, actual: String)
        /// Nothing to check against — no expected id was compiled in.
        case unchecked
    }

    /// Where this configuration's Firestore traffic is supposed to go.
    static func expectedFirestoreHost(for environment: AppEnvironment) -> String {
        switch environment.backend {
        case .emulator: return environment.firestoreHost
        case .testCloud, .production: return cloudFirestoreHost
        }
    }

    /// Pure so it can be tested without a Firebase app.
    ///
    /// `actualFirestoreHost` is nil when the caller could not read it; the
    /// transport check is then skipped rather than guessed at.
    static func verdict(
        environment: AppEnvironment = .current,
        actualProjectID: String?,
        actualFirestoreHost: String? = nil
    ) -> Verdict {
        let expected = environment.expectedProjectID
        let actual = actualProjectID ?? ""
        let backend = environment.backend

        // Any build that is not the production configuration must not be
        // talking to production, whatever its plist says.
        if backend != .production, actual == productionProjectID {
            return .unexpectedProduction(backend: backend.rawValue)
        }

        // A cloud build must not be wearing the emulator's identity. This is
        // not covered above — the emulator's id is not production's — and it
        // is the mistake that produces a green "cloud" run that never left
        // this machine.
        if backend != .emulator, actual == emulatorProjectID {
            return .confusedWithEmulator(backend: backend.rawValue)
        }
        // And the emulator build must not be wearing a cloud identity.
        if backend == .emulator, !actual.isEmpty, actual != emulatorProjectID {
            return .confusedWithEmulator(backend: backend.rawValue)
        }

        if !expected.isEmpty, expected != actual {
            return .mismatch(expected: expected, actual: actual)
        }

        // Identity agreed. Now: do the bytes actually go there?
        if let host = actualFirestoreHost {
            let wanted = expectedFirestoreHost(for: environment)
            guard host == wanted else {
                return .wrongTransport(
                    backend: backend.rawValue, expected: wanted, actual: host
                )
            }
        }

        guard !expected.isEmpty else { return .unchecked }
        return .ok(projectID: actual)
    }

    /// What to show on screen so a screenshot from a device is self-evidencing.
    ///
    /// The *loaded* project id, not the expected one: the expected id is what
    /// the build meant to do, and a screenshot is only worth anything if it
    /// shows what actually happened.
    @MainActor
    static var displayLabel: String {
        let backend = AppEnvironment.current.backend.rawValue.uppercased()
        guard let project = FirebaseApp.app()?.options.projectID else {
            return "\(backend) · no project"
        }
        return "\(backend) · \(project)"
    }

    @MainActor
    static func enforce(_ environment: AppEnvironment = .current) {
        let actual = FirebaseApp.app()?.options.projectID
        // Reading `settings` does not start a connection, so this is safe to
        // do before anything has been queried.
        let host = FirebaseApp.app() == nil ? nil : Firestore.firestore().settings.host

        switch verdict(
            environment: environment, actualProjectID: actual, actualFirestoreHost: host
        ) {
        case .ok(let projectID):
            log.info("environment verified: \(projectID, privacy: .public) via \(host ?? "?", privacy: .public)")
        case .unchecked:
            log.info("environment id unchecked; transport \(host ?? "?", privacy: .public)")
        case .mismatch(let expected, let actual):
            fatalError("""
                Wrong Firebase project. Expected \(expected), loaded \(actual).
                The build's GoogleService-Info does not match the configuration \
                it was built with.
                """)
        case .unexpectedProduction(let backend):
            fatalError("""
                A \(backend) build loaded the production project \
                (\(productionProjectID)). Refusing to run.
                """)
        case .confusedWithEmulator(let backend):
            fatalError("""
                A \(backend) build loaded project \(actual ?? "nil"), which is \
                not the identity that configuration is for. The emulator runs \
                as \(emulatorProjectID); a cloud test project must never reuse \
                that id, because then nothing can tell the two apart.
                """)
        case .wrongTransport(let backend, let expected, let actual):
            fatalError("""
                A \(backend) build has the right project id and the wrong \
                destination. Firestore is pointed at \(actual), expected \
                \(expected). Results from this build would say nothing about \
                the environment it claims to be testing.
                """)
        }
    }
}
