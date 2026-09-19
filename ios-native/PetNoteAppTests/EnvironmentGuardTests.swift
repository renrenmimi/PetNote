import Foundation
import Testing

@testable import PetNote

/// The guard that stops a misconfigured build reaching production.
///
/// Worth its own tests because it is the one piece of code whose failure is
/// silent and expensive: a test build that quietly loads production's plist
/// writes to real people's data and looks completely normal doing it.
struct EnvironmentGuardTests {
    private func environment(
        backend: String,
        expectedProject: String
    ) -> AppEnvironment {
        AppEnvironment(bundle: StubBundle(values: [
            "PetNoteBackend": backend,
            "PetNoteExpectedProject": expectedProject,
            "PetNoteEmulatorHost": "127.0.0.1",
            "PetNoteBuildStamp": "test",
        ]))
    }

    @Test func matchingProjectPasses() {
        let verdict = EnvironmentGuard.verdict(
            environment: environment(backend: "testcloud", expectedProject: "petnote-test-1"),
            actualProjectID: "petnote-test-1"
        )
        #expect(verdict == .ok(projectID: "petnote-test-1"))
    }

    /// The case that matters most: a test build that ended up with
    /// production's configuration.
    @Test func aTestBuildLoadingProductionIsRefused() {
        let verdict = EnvironmentGuard.verdict(
            environment: environment(backend: "testcloud", expectedProject: "petnote-test-1"),
            actualProjectID: EnvironmentGuard.productionProjectID
        )
        #expect(verdict == .unexpectedProduction(backend: "testcloud"))
    }

    /// And an emulator build, which has no expected id, must still not be
    /// allowed to talk to production.
    @Test func anEmulatorBuildLoadingProductionIsRefused() {
        let verdict = EnvironmentGuard.verdict(
            environment: environment(backend: "emulator", expectedProject: ""),
            actualProjectID: EnvironmentGuard.productionProjectID
        )
        #expect(verdict == .unexpectedProduction(backend: "emulator"))
    }

    @Test func theWrongTestProjectIsRefused() {
        let verdict = EnvironmentGuard.verdict(
            environment: environment(backend: "testcloud", expectedProject: "petnote-test-1"),
            actualProjectID: "petnote-test-2"
        )
        #expect(verdict == .mismatch(expected: "petnote-test-1", actual: "petnote-test-2"))
    }

    /// A missing plist shows up as no project id at all, which must not pass.
    @Test func aMissingProjectIsRefused() {
        let verdict = EnvironmentGuard.verdict(
            environment: environment(backend: "testcloud", expectedProject: "petnote-test-1"),
            actualProjectID: nil
        )
        #expect(verdict == .mismatch(expected: "petnote-test-1", actual: ""))
    }

    /// Emulator builds have nothing to check against: the project id is
    /// whatever the emulator was started with.
    @Test func emulatorBuildsAreUnchecked() {
        let verdict = EnvironmentGuard.verdict(
            environment: environment(backend: "emulator", expectedProject: ""),
            actualProjectID: "petnote-test"
        )
        #expect(verdict == .unchecked)
    }

    @Test func productionBuildsMayLoadProduction() {
        let verdict = EnvironmentGuard.verdict(
            environment: environment(
                backend: "production",
                expectedProject: EnvironmentGuard.productionProjectID
            ),
            actualProjectID: EnvironmentGuard.productionProjectID
        )
        #expect(verdict == .ok(projectID: EnvironmentGuard.productionProjectID))
    }

    /// The test project is allowed to be written to; production is not.
    @Test func onlyNonProductionBackendsAllowWrites() {
        #expect(environment(backend: "emulator", expectedProject: "").allowsWrites)
        #expect(environment(backend: "testcloud", expectedProject: "p").allowsWrites)
        #expect(!environment(backend: "production", expectedProject: "p").allowsWrites)
    }
}

/// A Bundle whose infoDictionary is whatever the test says it is.
private final class StubBundle: Bundle, @unchecked Sendable {
    private let values: [String: Any]

    init(values: [String: Any]) {
        self.values = values
        super.init()
    }

    override var infoDictionary: [String: Any]? { values }
}
