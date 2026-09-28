import Foundation

/// Waits for `condition`, bounded by the clock rather than by a count of turns.
///
/// Counting `Task.yield()` calls is not a timeout. The work being waited for
/// often runs on another executor — a fake's nonisolated method, reached from
/// a model's task — and on a busy machine thousands of turns of this one can
/// pass before that thread is scheduled at all. twoTapsInTheSameTurnSaveOnce
/// failed that way in a parallel run on 2026-09-23: it gave up after 20,000
/// turns. A quick run of turns first keeps the usual case fast;
/// after that it sleeps a little between checks, so it does not also starve
/// the thread it is waiting for.
@MainActor
func eventuallyTrue(within timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        await Task.yield()
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

/// The same, for code that is not on the main actor and reads only
/// lock-protected state.
func eventuallyTrueAnywhere(within timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        await Task.yield()
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}
