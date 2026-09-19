import FirebaseAuth
import Foundation
import OSLog
import Observation

/// Who is signed in, and everything scoped to them.
///
/// `restoring` is a real state, not a detail. A cold start does not know yet
/// whether there is a session — the SDK reads the refresh token from the
/// Keychain asynchronously — and rendering the sign-in screen during that gap
/// makes an already-signed-in person watch the app forget them for a frame.
@MainActor
@Observable
final class SessionStore {
    enum State: Equatable {
        case restoring
        case signedOut
        case signedIn(UserSession)
    }

    private(set) var state: State = .restoring

    /// Everything owned by the current session. Replaced wholesale on sign-out,
    /// which is the only reliable way to be sure nothing from the previous
    /// account survives into the next one.
    private(set) var scope = SessionScope()

    private let log = Logger(subsystem: "dev.local.petnote.native", category: "auth")
    private var listener: AuthStateDidChangeListenerHandle?

    func start() {
        guard listener == nil else { return }
        #if DEBUG
        // UI tests need a known starting state. Debug-only and argument-gated:
        // a release build has no way to reach this, and nothing in the app's
        // own UI passes the flag.
        if ProcessInfo.processInfo.arguments.contains("-petnote-start-signed-out") {
            try? Auth.auth().signOut()
        }
        #endif
        listener = Auth.auth().addStateDidChangeListener { _, user in
            // Firebase documents this callback as main-thread. Asserting that
            // rather than hopping keeps the restore in the first frame; if the
            // assumption ever stops holding we want the loud failure, not a
            // quiet data race.
            MainActor.assumeIsolated {
                self.apply(user)
            }
        }
    }

    private func apply(_ user: User?) {
        guard let user else {
            if case .signedIn = state { resetScope() }
            state = .signedOut
            log.info("session: signed out")
            return
        }
        let session = UserSession(
            uid: user.uid,
            email: user.email ?? "",
            isEmailVerified: user.isEmailVerified
        )
        if case .signedIn(let existing) = state, existing.uid != session.uid {
            // Account switch without an explicit sign-out still has to drop
            // everything the previous account loaded.
            resetScope()
        }
        state = .signedIn(session)
        log.info("session: signed in as \(session.shortID, privacy: .public), verified=\(session.isEmailVerified)")
    }

    func signIn(email: String, password: String) async throws(AuthError) {
        do {
            _ = try await Auth.auth().signIn(withEmail: email, password: password)
        } catch {
            let mapped = AuthError(error)
            log.error("sign-in failed: \(String(describing: mapped), privacy: .public)")
            throw mapped
        }
    }

    func signOut() throws {
        try Auth.auth().signOut()
        resetScope()
    }

    /// Drops caches and paging state. Called on sign-out and on account switch.
    ///
    /// The image cache is dropped explicitly here. It is a process-wide actor,
    /// not something the scope owns, so "throw the scope away" does not reach
    /// it — and a cached photo from the previous account surviving a sign-out
    /// is exactly what §7.3 is about.
    private func resetScope() {
        scope.tearDown()
        scope = SessionScope()
        Task { await ImageLoader.shared.clearMemoryCache() }
        log.info("session scope reset; image cache cleared")
    }

    /// Removes the auth listener.
    ///
    /// Deliberately not a `deinit`: a nonisolated `deinit` cannot touch
    /// main-actor state, and working around that would mean either
    /// `@unchecked Sendable` or a lock around a handle that is only ever
    /// touched on the main actor — both worse than being explicit. In the app
    /// this object lives as long as the process, so there is nothing to clean
    /// up at exit; tests create and drop instances and call this.
    func stop() {
        guard let listener else { return }
        Auth.auth().removeStateDidChangeListener(listener)
        self.listener = nil
    }
}

struct UserSession: Sendable, Equatable {
    let uid: String
    let email: String
    /// `signed in && emailVerified` — in that order. The web client checked
    /// verification before checking for a user and told signed-out visitors to
    /// verify their email.
    let isEmailVerified: Bool

    /// For logs. A uid is an identifier for a person and does not belong in
    /// them in full.
    var shortID: String { String(uid.prefix(6)) }
}

/// Session-scoped storage. Held by `SessionStore` and thrown away whole on
/// sign-out, so "did we remember to clear X?" is not a question anyone has to
/// answer per cache.
@MainActor
final class SessionScope {
    private var teardownHandlers: [() -> Void] = []

    func onTeardown(_ handler: @escaping () -> Void) {
        teardownHandlers.append(handler)
    }

    func tearDown() {
        for handler in teardownHandlers.reversed() { handler() }
        teardownHandlers.removeAll()
    }
}
