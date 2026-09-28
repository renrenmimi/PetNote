import FirebaseFunctions
import Foundation

/// One way to call a Cloud Function, so the concurrency question is answered
/// once rather than in every repository.
///
/// **Why this exists.** Three lines of work each reached for
/// `functions.httpsCallable(name).call(payload)` from inside an actor, and
/// under `SWIFT_STRICT_CONCURRENCY = complete` that does not compile:
///
///     sending value of non-Sendable type '[String : Any]' risks causing data
///     races — sending 'self'-isolated value to @concurrent instance method
///
/// `[String: Any]` is not `Sendable`, and a dictionary built inside an actor
/// belongs to that actor. Handing it to a `@concurrent` method would let both
/// sides touch it. The compiler is right; the payload really is shared.
///
/// `sending` is the answer rather than `@unchecked Sendable` or a detached
/// task: it says the caller gives the value up, and the compiler checks that
/// the caller keeps no reference to it afterwards. Nothing is asserted that is
/// not also verified.
enum CallableClient {
    /// Calls `name` and returns its `data` as a dictionary.
    ///
    /// The payload is `sending`: build it at the call site and let it go. If
    /// this ever fails to compile at a call site, the fix is to construct the
    /// dictionary inline rather than to reach for a stored one — a stored one
    /// is exactly what would still be shared.
    static func call(
        _ name: String,
        _ payload: sending [String: Any] = [:],
        functions: Functions = Functions.functions()
    ) async throws -> [String: Any] {
        let result = try await functions.httpsCallable(name).call(payload)
        return result.data as? [String: Any] ?? [:]
    }

    /// For callables whose answer is not read.
    ///
    /// Separate rather than `_ = try await call(…)` so the intent is legible:
    /// "this one has no useful reply" and "I forgot to check the reply" look
    /// identical otherwise.
    static func callIgnoringResult(
        _ name: String,
        _ payload: sending [String: Any] = [:],
        functions: Functions = Functions.functions()
    ) async throws {
        _ = try await functions.httpsCallable(name).call(payload)
    }
}
