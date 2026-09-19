import FirebaseCore
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
enum EnvironmentGuard {
    private static let log = Logger(subsystem: "dev.local.petnote.native", category: "auth")

    /// Production's project id, hardcoded so it can be recognised and refused
    /// anywhere it is not wanted. It is not a secret — it is in every web
    /// bundle — and having it named here is what lets the check be explicit.
    static let productionProjectID = "petnote-a9dac"

    enum Verdict: Equatable {
        case ok(projectID: String)
        /// Expected one project, Firebase loaded another.
        case mismatch(expected: String, actual: String)
        /// A non-production build ended up pointed at production.
        case unexpectedProduction(backend: String)
        /// Nothing to check against — emulator builds, where the project id is
        /// whatever the emulator was told to use.
        case unchecked
    }

    static func verdict(
        environment: AppEnvironment = .current,
        actualProjectID: String?
    ) -> Verdict {
        let expected = environment.expectedProjectID
        let actual = actualProjectID ?? ""

        // Any build that is not the production configuration must not be
        // talking to production, whatever its plist says.
        if environment.backend != .production, actual == productionProjectID {
            return .unexpectedProduction(backend: environment.backend.rawValue)
        }
        guard !expected.isEmpty else { return .unchecked }
        guard expected == actual else {
            return .mismatch(expected: expected, actual: actual)
        }
        return .ok(projectID: actual)
    }

    @MainActor
    static func enforce(_ environment: AppEnvironment = .current) {
        let actual = FirebaseApp.app()?.options.projectID
        switch verdict(environment: environment, actualProjectID: actual) {
        case .ok(let projectID):
            log.info("environment verified: \(projectID, privacy: .public)")
        case .unchecked:
            log.info("environment unchecked (emulator build)")
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
        }
    }
}
