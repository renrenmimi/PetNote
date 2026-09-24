import Foundation
import Testing

/// The test clock itself: passing a deadline reaches only the ones already
/// parked. The control half shows the failure the like tests had — a pass
/// made before the timer parked releases nothing — so the fix is shown to
/// address a real gap rather than a guessed one.
struct ManualDeadlineTests {
    /// Ordered for certain rather than by luck: the pass comes first and the
    /// timer after it — which is what happened on the slow runner, where the
    /// test passed as soon as the request went out.
    @Test func aPassBeforeTheTimerParksReleasesNothing() async throws {
        let deadline = ManualDeadline()
        let released = Released()
        deadline.pass()
        let timer = Task { try? await deadline.sleeper(.seconds(12)); await released.mark() }
        #expect(await deadline.waitUntilArmed(), "the timer never parked")
        #expect(deadline.armed == 1)
        for _ in 0..<200 { await Task.yield() }
        #expect(await released.value == false, "a pass reached a timer that was not yet waiting")
        timer.cancel()
        await timer.value
    }

    @Test func passingOnceArmedReleasesTheTimer() async {
        let deadline = ManualDeadline()
        let released = Released()
        let timer = Task { try? await deadline.sleeper(.seconds(12)); await released.mark() }
        await deadline.passOnceArmed()
        await timer.value
        #expect(await released.value)
        #expect(deadline.armed == 0)
    }

    actor Released {
        private(set) var value = false
        func mark() { value = true }
    }
}
