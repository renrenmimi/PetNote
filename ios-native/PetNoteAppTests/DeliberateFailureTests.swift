import Testing

/// **Temporary, and not for merging.** This exists to prove that the unit-test
/// gate in `.github/workflows/ios-native.yml` can actually fail the job.
///
/// Before `53f325e` it could not: the step ended `| grep … || true`, which
/// discarded xcodebuild's exit status, so the only red states were "no tests
/// ran" and "fewer than the floor ran". A count guard proves a suite ran; it
/// cannot prove the suite passed, and those are different claims.
///
/// This branch is opened as a pull request, the job is observed to fail, and
/// then the branch is closed and deleted. It never reaches the candidate.
struct DeliberateFailureTests {
    @Test func theGateCanFailTheJob() {
        #expect(Bool(false), "deliberate failure: proving the CI gate reports it")
    }
}
