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

    // MARK: - Identity is not enough

    /// The confusion this whole naming rule exists to prevent: the emulator
    /// runs as `petnote-test`, so a *cloud* project may never be given that
    /// id. If one were, a green cloud run and a green local run would be
    /// indistinguishable in every log we have.
    @Test func aCloudBuildWearingTheEmulatorsIdentityIsRefused() {
        let verdict = EnvironmentGuard.verdict(
            environment: environment(backend: "testcloud", expectedProject: "petnote-test"),
            actualProjectID: EnvironmentGuard.emulatorProjectID
        )
        #expect(verdict == .confusedWithEmulator(backend: "testcloud"))
    }

    /// And the other direction: an emulator build that somehow loaded a cloud
    /// project's plist.
    @Test func anEmulatorBuildWearingACloudIdentityIsRefused() {
        let verdict = EnvironmentGuard.verdict(
            environment: environment(backend: "emulator", expectedProject: ""),
            actualProjectID: "petnote-devtest-7"
        )
        #expect(verdict == .confusedWithEmulator(backend: "emulator"))
    }

    // MARK: - Where the bytes actually go

    /// An emulator build whose host settings did not take. The id is right,
    /// and every read and write goes to the real cloud.
    @Test func anEmulatorBuildTalkingToTheCloudIsRefused() {
        let verdict = EnvironmentGuard.verdict(
            environment: environment(backend: "emulator", expectedProject: ""),
            actualProjectID: EnvironmentGuard.emulatorProjectID,
            actualFirestoreHost: EnvironmentGuard.cloudFirestoreHost
        )
        #expect(verdict == .wrongTransport(
            backend: "emulator",
            expected: "127.0.0.1:8088",
            actual: EnvironmentGuard.cloudFirestoreHost
        ))
    }

    /// The reverse, which is quieter and worse: a build that reports "tested
    /// against the cloud test project" having never left this machine.
    @Test func aCloudBuildStillPointedAtTheEmulatorIsRefused() {
        let verdict = EnvironmentGuard.verdict(
            environment: environment(backend: "testcloud", expectedProject: "petnote-devtest-7"),
            actualProjectID: "petnote-devtest-7",
            actualFirestoreHost: "127.0.0.1:8088"
        )
        #expect(verdict == .wrongTransport(
            backend: "testcloud",
            expected: EnvironmentGuard.cloudFirestoreHost,
            actual: "127.0.0.1:8088"
        ))
    }

    @Test func theRightIdOverTheRightHostPasses() {
        #expect(EnvironmentGuard.verdict(
            environment: environment(backend: "testcloud", expectedProject: "petnote-devtest-7"),
            actualProjectID: "petnote-devtest-7",
            actualFirestoreHost: EnvironmentGuard.cloudFirestoreHost
        ) == .ok(projectID: "petnote-devtest-7"))

        #expect(EnvironmentGuard.verdict(
            environment: environment(backend: "emulator", expectedProject: ""),
            actualProjectID: EnvironmentGuard.emulatorProjectID,
            actualFirestoreHost: "127.0.0.1:8088"
        ) == .unchecked)
    }

    /// A host we could not read is not a host we may assume is correct — but
    /// it is also not evidence of a fault. Skipped, not guessed.
    @Test func anUnreadableHostSkipsTheTransportCheck() {
        let verdict = EnvironmentGuard.verdict(
            environment: environment(backend: "testcloud", expectedProject: "petnote-devtest-7"),
            actualProjectID: "petnote-devtest-7",
            actualFirestoreHost: nil
        )
        #expect(verdict == .ok(projectID: "petnote-devtest-7"))
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
