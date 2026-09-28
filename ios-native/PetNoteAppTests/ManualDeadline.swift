import Foundation
import Testing

/// A like deadline that passes when the test says so, and not before.
///
/// Both like models race each request against `sleeper(likeDeadline)` and
/// give up on whichever loses. The tests used the real clock for it — 12s for
/// the ones about ordering, 20ms for the ones about giving up — and on CI both
/// were raced by the runner rather than by the model. Run 35823259740 (stack 2,
/// 059db25) had tests that take under a second here report 67–115 seconds: the
/// 12s deadline passed while the first of two held taps was still being held,
/// so the second went out beside it (`likes.calls.count → 2`); and a request
/// that *was* answered took longer than 20ms to be, so it was given up on and
/// the like it confirmed was taken off the screen (`isLiked → false`, count 10
/// where 11 was right). Passing a deadline at exactly those two moments
/// reproduced both sets of numbers locally, which is what ties them to it.
///
/// Neither failure is the model misbehaving — each is what the model is meant
/// to do when a deadline passes. The tests had no say in when it did. With
/// this, a deadline passes on `pass()` and at no other time, so the ones about
/// ordering have none, and the ones about giving up choose the moment.
final class ManualDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [Duration] = []
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    /// Cancelled before its continuation was stored; resumed as it arrives.
    private var cancelledEarly: Set<Int> = []
    private var nextID = 0

    /// A deadline nobody will pass: for tests that are about something else.
    static var never: @Sendable (Duration) async throws -> Void { ManualDeadline().sleeper }

    /// What to hand the model as its `sleeper`.
    var sleeper: @Sendable (Duration) async throws -> Void {
        { [self] duration in try await self.wait(duration) }
    }

    /// Every deadline the model has started, in order, with the length it
    /// asked for — including ones since cancelled because the answer came.
    var durations: [Duration] { lock.withLock { started } }

    /// How many deadlines are parked right now, so that `pass()` would reach
    /// them. A deadline is in `durations` a moment before it is parked, and a
    /// test that passes in that moment passes nothing: the model then waits
    /// for ever. That is how `aPostStillWorksAfterARequestIsAbandoned` failed
    /// on CI (run 35924362700) — it passed as soon as the request went out,
    /// and on a slow runner the timer beside it had not parked yet.
    var armed: Int { lock.withLock { waiting.count } }

    /// Whether `count` deadlines park within a bounded wait. "The request
    /// went out" is not "its deadline started": the model starts the two
    /// together, and a test that counts deadlines the moment the request
    /// arrives can count 0 on a slow runner (run 35929225283, `durations.count
    /// → 0`). Wait for them, then count.
    func waitUntilArmed(_ count: Int = 1) async -> Bool {
        await eventuallyTrueAnywhere { self.armed >= count }
    }

    /// Waits until `count` deadlines are parked, then passes them. What the
    /// tests about giving up should call, rather than `pass()` on a guess.
    func passOnceArmed(_ count: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) async {
        guard await waitUntilArmed(count) else {
            Issue.record("no deadline parked to pass (armed \(armed), started \(durations.count))",
                         sourceLocation: sourceLocation)
            return
        }
        pass()
    }

    /// Passes every deadline running now. Ones started later wait for the
    /// next call.
    func pass() {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiting.removeAll() }
            return Array(waiting.values)
        }
        for continuation in due { continuation.resume() }
    }

    /// Returns when passed, and throws when cancelled — which is what the
    /// model does to its timer once the request has answered.
    private func wait(_ duration: Duration) async throws {
        let id = lock.withLock { () -> Int in
            started.append(duration)
            nextID += 1
            return nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if cancelledEarly.remove(id) != nil { return true }
                    waiting[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                if let stored = waiting.removeValue(forKey: id) { return stored }
                cancelledEarly.insert(id)
                return nil
            }
            continuation?.resume()
        }
        try Task.checkCancellation()
    }
}
