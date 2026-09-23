import FirebaseAuth
import Foundation
import GoogleSignIn
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

    /// Why there is no session right now.
    ///
    /// The distinction is the whole of §6.9: a person who tapped "sign out"
    /// knows why they are looking at the sign-in screen, and a person whose
    /// session was revoked underneath them does not. Only the second one needs
    /// to be told, and only the second one gets their place back.
    enum EndReason: Equatable {
        case signedOut
        case expired
        /// The person deleted their account; the sign-in screen says so.
        case accountDeleted
    }

    /// Where the person was when a session ended, and whose session it was.
    ///
    /// The uid is carried so the place is only ever given back to the account
    /// that left it. Restoring account A's screen because account B happened to
    /// sign in next is how "state from the previous account" gets in (§4.4).
    struct Resume: Equatable {
        let route: Route
        let uid: String
    }

    private(set) var state: State = .restoring

    /// Everything owned by the current session. Replaced wholesale on sign-out,
    /// which is the only reliable way to be sure nothing from the previous
    /// account survives into the next one.
    private(set) var scope = SessionScope()

    private(set) var endedReason: EndReason?
    private(set) var pendingResume: Resume?

    /// Where the person is right now, reported by the screens themselves.
    ///
    /// The navigation path lives in `SignedInView`, which is out of reach from
    /// here; the two screens that can be on it tell the session as they arrive.
    /// It is only ever read at the moment a session ends, so a missed update
    /// costs a restored screen, never correctness.
    private(set) var currentRoute: Route = .feed

    private let log = Logger(subsystem: "dev.local.petnote.native", category: "auth")
    private var listener: AuthStateDidChangeListenerHandle?

    /// Set by `signOut()` and consumed by the state listener.
    ///
    /// Not reset in a `defer`: `Auth.signOut()` notifies its listeners
    /// asynchronously, so a flag cleared on the way out of this function would
    /// already be false by the time the listener asks, and every deliberate
    /// sign-out would be reported as an expiry.
    private var signOutWasDeliberate = false
    /// What a deliberate sign-out is reported as.
    private var deliberateReason: EndReason = .signedOut

    func start() {
        guard listener == nil else { return }
        #if DEBUG
        // UI tests need a known starting state. Debug-only and argument-gated:
        // a release build has no way to reach this, and nothing in the app's
        // own UI passes the flag.
        if ProcessInfo.processInfo.arguments.contains("-petnote-start-signed-out") {
            signOutWasDeliberate = true
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
            if case .signedIn(let existing) = state {
                // The SDK signs a user out by itself when a refresh comes back
                // with userNotFound / userDisabled / invalidUserToken /
                // userTokenExpired (FirebaseAuth User.signOutIfTokenIsInvalid).
                // That arrives here as a plain sign-out and is indistinguishable
                // from a deliberate one unless we say which we asked for.
                if signOutWasDeliberate {
                    endedReason = deliberateReason
                    deliberateReason = .signedOut
                    pendingResume = nil
                } else {
                    endedReason = .expired
                    pendingResume = Resume(route: currentRoute, uid: existing.uid)
                    log.info("session: expired underneath \(existing.shortID, privacy: .public)")
                }
                resetScope()
            }
            signOutWasDeliberate = false
            currentRoute = .feed
            state = .signedOut
            log.info("session: signed out, reason=\(String(describing: self.endedReason), privacy: .public)")
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
            pendingResume = nil
            currentRoute = .feed
        }
        signOutWasDeliberate = false
        endedReason = nil
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

    /// "Continue with Google": Google's page for the tokens, then Firebase.
    ///
    /// Here rather than in a model owned by the sign-in screen: the moment
    /// Firebase signs in, the session listener swaps the whole tree to the
    /// signed-in one, and a screen-owned model would be torn down mid-call.
    ///
    /// - Returns: false when the person backed out of Google's page.
    func signInWithGoogle(using google: any GoogleTokenProviding) async throws(AuthError) -> Bool {
        guard let tokens = try await google.tokens() else { return false }
        let credential = GoogleAuthProvider.credential(
            withIDToken: tokens.idToken, accessToken: tokens.accessToken
        )
        do {
            _ = try await Auth.auth().signIn(with: credential)
            return true
        } catch {
            let mapped = AuthError(error)
            log.error("google sign-in failed at Firebase: \(String(describing: mapped), privacy: .public)")
            throw mapped
        }
    }

    /// The server has deleted the account. Ends the session as deliberate —
    /// no "your session ended" and no place to go back to — and says why.
    ///
    /// If the SDK noticed first (the Auth user is gone, so a token refresh
    /// fails) the session has already ended as an expiry; that is corrected
    /// here rather than left telling the person to sign back in.
    func accountDeleted() {
        pendingResume = nil
        guard case .signedIn = state else {
            endedReason = .accountDeleted
            return
        }
        deliberateReason = .accountDeleted
        do {
            try signOut()
        } catch {
            // Firebase could not sign out locally; the server has already
            // deleted the account, so the screen must not stay signed in.
            deliberateReason = .signedOut
            resetScope()
            state = .signedOut
            endedReason = .accountDeleted
        }
    }

    func signOut() throws {
        signOutWasDeliberate = true
        do {
            try Auth.auth().signOut()
        } catch {
            signOutWasDeliberate = false
            throw error
        }
        // Google keeps its own signed-in user in the Keychain. Firebase has
        // its own session, so this is not needed to sign out of PetNote — but
        // left behind, the next "Continue with Google" would go straight
        // through as the previous person. Safe when Google was never used.
        GIDSignIn.sharedInstance.signOut()
        resetScope()
    }

    /// Records that the signed-in account's email is verified now.
    ///
    /// Additive, and deliberately not a reload: the account has already been
    /// re-read and its ID token already force-refreshed by whoever calls this
    /// (see `EmailVerificationModel.checkNow`). What is left is the session's
    /// own snapshot, which is a *value* captured when the auth listener last
    /// fired — and the listener does not fire for a verification link being
    /// followed. Without this the banner goes away and every other gate in the
    /// app keeps reading `isEmailVerified == false`.
    func noteEmailVerified() {
        guard case .signedIn(let session) = state, !session.isEmailVerified else { return }
        state = .signedIn(
            UserSession(uid: session.uid, email: session.email, isEmailVerified: true)
        )
        log.info("session: \(session.shortID, privacy: .public) is now verified")
    }

    // MARK: - Is this session still real?

    /// Asks the server whether the session is still good, and returns whether
    /// it is.
    ///
    /// A cached ID token stays valid for an hour, and neither Firestore nor the
    /// callables check whether the account behind it still exists — so an
    /// account revoked on the server keeps working until something forces a
    /// refresh. Nothing in the app forces one, which is why §6.9 had no
    /// behaviour at all before this: the person went on using an app they were
    /// no longer allowed in, and found out at an arbitrary later moment.
    ///
    /// The force-refresh is one small request per foreground. That is the price
    /// of the question being answered at a predictable moment rather than an
    /// arbitrary one.
    ///
    /// **A failure that is not about this account is not an expiry.** Signing
    /// someone out because their train went into a tunnel is the worse of the
    /// two mistakes, so only the four codes the SDK itself treats as a dead
    /// token end the session.
    @discardableResult
    func revalidate() async -> Bool {
        guard case .signedIn(let session) = state else { return false }
        guard let user = Auth.auth().currentUser else {
            // The SDK has no user but we still think we do. That is an expiry
            // we missed; report it rather than leaving the two disagreeing.
            expire(uid: session.uid)
            return false
        }
        do {
            _ = try await user.getIDToken(forcingRefresh: true)
            return true
        } catch {
            let nsError = error as NSError
            let code = AuthErrorCode(rawValue: nsError.code)
            switch code {
            case .userNotFound, .userDisabled, .invalidUserToken, .userTokenExpired:
                log.info("revalidate: token rejected (\(nsError.code)), ending session")
                // The SDK normally signs out by itself on these; doing it here
                // too makes the outcome the same whether or not it did.
                expire(uid: session.uid)
                return false
            default:
                log.info("revalidate: inconclusive (\(nsError.code)), session kept")
                return true
            }
        }
    }

    /// Ends the session as an expiry, keeping the place the person was at.
    private func expire(uid: String) {
        guard case .signedIn = state else { return }
        signOutWasDeliberate = false
        pendingResume = Resume(route: currentRoute, uid: uid)
        endedReason = .expired
        try? Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
        // Not relying on the listener alone: it is what normally drives this,
        // but if the SDK already had no user the listener will not fire again
        // and the app would stay on a screen it cannot use.
        if case .signedIn = state {
            resetScope()
            state = .signedOut
        }
    }

    // MARK: - Where the person was

    func noteCurrentRoute(_ route: Route) {
        guard case .signedIn = state else { return }
        currentRoute = route
    }

    /// Hands back the place this account left, once.
    func consumeResume(for uid: String) -> Route? {
        defer { pendingResume = nil }
        return Self.resumeRoute(from: pendingResume, forUID: uid)
    }

    /// The rule for giving a place back, separated from the storage so it can
    /// be checked without a Firebase app behind it.
    ///
    /// Two refusals, both deliberate:
    ///
    ///   - **a different account gets nothing.** Restoring the screen the
    ///     previous person was on is exactly the "content from the last
    ///     account" §4.4 forbids, and a post id is content;
    ///   - **the feed is not a place to restore to.** A sign-in lands there
    ///     anyway, and pushing it would put a second copy of the feed on top
    ///     of the first.
    static func resumeRoute(from pending: Resume?, forUID uid: String) -> Route? {
        guard let pending, pending.uid == uid, pending.route != .feed else { return nil }
        return pending.route
    }

    func clearEndedReason() { endedReason = nil }

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
