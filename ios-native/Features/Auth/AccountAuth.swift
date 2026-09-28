import FirebaseAuth
import Foundation
import OSLog

/// The Firebase Auth operations this batch needs, behind a protocol.
///
/// Not for tidiness. Every one of these is a network call whose *failure* is
/// the interesting case — a verification email that does not send, a reset for
/// an address nobody has, a token that still says unverified after the link was
/// followed — and none of those can be provoked against a real Auth instance
/// from a unit test. The protocol is what makes them assertable.
///
/// Sign-in is deliberately **not** here: it already lives on `SessionStore`,
/// which owns the session, and a second way to sign in is a second thing to
/// keep in step.
protocol AccountAuthenticating: Sendable {
    /// Creates the account **and signs it in** — Firebase does the second part
    /// whether or not the caller wants it, which is why everything after this
    /// call in the sign-up flow is running as an already-signed-in person.
    ///
    /// - Returns: the new account's uid.
    func createAccount(email: String, password: String) async throws(AuthError) -> String

    /// Sends (or resends) the verification email to the signed-in account.
    func sendVerificationEmail() async throws(AuthError)

    /// Firebase's own password-reset email — the link flow, not a code.
    ///
    /// Succeeds silently for an address with no account when Email Enumeration
    /// Protection is on, which is the default for projects created since
    /// September 2023 and is the privacy-correct behaviour. The screen says
    /// "if that address has an account" for exactly this reason.
    func sendPasswordResetEmail(to email: String) async throws(AuthError)

    /// Re-reads the account and forces a new ID token, returning whether the
    /// email is verified **now**.
    ///
    /// Both halves are necessary. `reload()` updates the local record, and the
    /// forced refresh is what updates the `email_verified` claim on the token
    /// — the callables that gate posting read the claim, and a cached token
    /// keeps saying false for up to an hour after the link was followed.
    func refreshVerification() async throws(AuthError) -> Bool

    /// The signed-in account, sampled now. Nil when signed out.
    var currentAccount: AccountSnapshot? { get }
}

/// Who is signed in at the moment of asking.
///
/// A value rather than a reference on purpose: `User.reload()` mutates the SDK
/// object in place, so a held reference silently changes under whoever is
/// reading it and nothing re-renders. The web client hit this exact problem and
/// solved it by keeping `emailVerified` as its own state — see the note on
/// `AuthContext.emailVerified`.
struct AccountSnapshot: Sendable, Equatable {
    let uid: String
    let email: String
    let isEmailVerified: Bool
}

/// The real thing.
///
/// Holds no Firebase object. `Auth.auth()` is a process-wide singleton and the
/// current user changes underneath it, so sampling at each call is both the
/// correct reading and the one that keeps this type `Sendable`.
struct LiveAccountAuth: AccountAuthenticating {
    private var log: Logger { Logger(subsystem: "dev.local.petnote.native", category: "auth") }

    var currentAccount: AccountSnapshot? {
        guard let user = Auth.auth().currentUser else { return nil }
        return AccountSnapshot(
            uid: user.uid, email: user.email ?? "", isEmailVerified: user.isEmailVerified
        )
    }

    func createAccount(email: String, password: String) async throws(AuthError) -> String {
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            return result.user.uid
        } catch {
            let mapped = AuthError(error)
            log.error("sign-up failed: \(String(describing: mapped), privacy: .public)")
            throw mapped
        }
    }

    func sendVerificationEmail() async throws(AuthError) {
        guard let user = Auth.auth().currentUser else { throw AuthError.unknown }
        do {
            try await user.sendEmailVerification()
        } catch {
            let mapped = AuthError(error)
            log.error("verification email failed: \(String(describing: mapped), privacy: .public)")
            throw mapped
        }
    }

    func sendPasswordResetEmail(to email: String) async throws(AuthError) {
        do {
            try await Auth.auth().sendPasswordReset(withEmail: email)
        } catch {
            let mapped = AuthError(error)
            log.error("reset email failed: \(String(describing: mapped), privacy: .public)")
            throw mapped
        }
    }

    func refreshVerification() async throws(AuthError) -> Bool {
        guard let user = Auth.auth().currentUser else { throw AuthError.unknown }
        do {
            try await user.reload()
            _ = try await user.getIDTokenResult(forcingRefresh: true)
            return user.isEmailVerified
        } catch {
            let mapped = AuthError(error)
            log.error("verification check failed: \(String(describing: mapped), privacy: .public)")
            throw mapped
        }
    }
}
