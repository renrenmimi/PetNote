import Testing

@testable import PetNote

/// The three rules that decide whether a moving clock is a picture, checked
/// with the numbers CI's iOS 26.2 simulator produced (run 35801729274, e203196)
/// and with the cases that must not change: an ordinary loop, a first load, a
/// clip that is simply over.
struct VideoStallPolicyTests {
    // MARK: - A clock ahead of its bytes

    /// CI: clock 7.00s, loaded to 5.73s, 14 frames in 3.6s. Not playback.
    @Test func aClockRunningPastItsBytesIsNotPlaying() {
        #expect(VideoStallPolicy.isAheadOfLoaded(clock: 7.00, loadedTo: 5.73))
    }

    /// Normal playback reads the clock a little behind the loaded edge, or at
    /// it; neither is a stall.
    @Test func aClockInsideOrAtItsBytesIsPlaying() {
        #expect(!VideoStallPolicy.isAheadOfLoaded(clock: 3.10, loadedTo: 4.87))
        #expect(!VideoStallPolicy.isAheadOfLoaded(clock: 4.87, loadedTo: 4.87))
        #expect(!VideoStallPolicy.isAheadOfLoaded(clock: 5.00, loadedTo: 4.87), "inside the tolerance")
    }

    /// A first load reports no ranges yet. Unknown decides nothing.
    @Test func noLoadedRangesDecideNothing() {
        #expect(!VideoStallPolicy.isAheadOfLoaded(clock: 0.40, loadedTo: 0))
    }

    // MARK: - What refunds the recovery budget

    @Test func forwardPlaybackOverLoadedBytesCountsInFull() {
        #expect(abs(VideoStallPolicy.refundableProgress(from: 1.0, to: 1.2, loadedTo: 5.0) - 0.2) < 1e-9)
    }

    /// CI: from 4.80s to 7.00s with bytes to 5.73s. Only the 0.93s over real
    /// data is playback; the rest bought the stream a refund it had not earned.
    @Test func onlyTheStretchOverRealBytesCounts() {
        let counted = VideoStallPolicy.refundableProgress(from: 4.80, to: 7.00, loadedTo: 5.73)
        #expect(abs(counted - 0.93) < 1e-9)
        #expect(counted < VideoStallPolicy.healthyProgressToRefundBudget)
    }

    /// A loop or a seek back is not recovering.
    @Test func goingBackwardsRefundsNothing() {
        #expect(VideoStallPolicy.refundableProgress(from: 3.9, to: 0.0, loadedTo: 16.0) == 0)
    }

    @Test func aClockAlreadyPastItsBytesRefundsNothingMore() {
        #expect(VideoStallPolicy.refundableProgress(from: 6.0, to: 6.5, loadedTo: 5.73) == 0)
    }

    // MARK: - Whether the end was the end

    /// An ordinary short clip, fully downloaded, loops as it always did.
    @Test func aFullyLoadedClipReallyEnded() {
        #expect(VideoStallPolicy.endIsReal(loadedTo: 4.0, duration: 4.0))
        #expect(VideoStallPolicy.endIsReal(loadedTo: 3.7, duration: 4.0), "inside the tolerance")
    }

    /// The 16s test clip cut at 35%: "played to the end" with 5.73s loaded is
    /// the stream stopping, and looping it replays the part that arrived.
    @Test func aClipThatRanOutOfBytesDidNotEnd() {
        #expect(!VideoStallPolicy.endIsReal(loadedTo: 5.73, duration: 16.0))
    }

    @Test func anUnknownDurationTrustsTheNotification() {
        #expect(VideoStallPolicy.endIsReal(loadedTo: 0, duration: .nan))
        #expect(VideoStallPolicy.endIsReal(loadedTo: 0, duration: 0))
    }

    /// The tolerances have to keep their relationship: a clock may lag the
    /// loaded edge by the read-ahead, and no recovery seek lands far enough
    /// back to replay a refund's worth.
    @Test func theTolerancesAreSmallerThanWhatTheyGuard() {
        #expect(VideoStallPolicy.aheadOfLoadedTolerance < VideoStallPolicy.feedbackDelay)
        #expect(VideoStallPolicy.endCoverageTolerance < VideoStallPolicy.healthyProgressToRefundBudget)
    }
}
