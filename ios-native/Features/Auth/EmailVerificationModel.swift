import Foundation
import Observation

/// The state of "we sent you a link; come back when you have opened it".
///
/// The awkward part of email verification is that **nothing tells this app the
/// link was followed.** It is opened in Safari, or in Mail's web view, or on a
/// different device entirely, and Firebase's auth-state listener does not fire
/// for it. Worse, the callables that gate posting read `email_verified` off the
/// ID token's claims, and a cached token keeps saying false for up to an hour
/// — so even relaunching the app can still refuse to post.
///
/// So there is an explicit "I verified my email", exactly as in the web
/// client's banner, and it does both halves: reload the account *and* force a
/// new token. Automatic polling is deliberately not added — the web client does
/// not do it, and a native app that quietly refreshes a token on every
/// foreground is a behaviour nobody asked for and nobody can see working.
@MainActor
@Observable
final class EmailVerificationModel {
    enum SendState: Sendable, Equatable {
        case idle
        case sent
        case failed(String)
    }

    static let resendCooldown: TimeInterval = 60

    /// Verification as this screen understands it.
    ///
    /// Held here rather than read from the SDK's `User` at each access: the
    /// SDK's `reload()` mutates that object in place, so the value changes
    /// under a reader and nothing re-renders. The web client keeps its own
    /// `emailVerified` state for precisely this reason.
    private(set) var isVerified: Bool
    private(set) var address: String
    private(set) var isSignedIn: Bool

    var isDismissed = false
    private(set) var isChecking = false
    private(set) var isSending = false
    private(set) var sendState: SendState = .idle
    /// Set when a check came back still-unverified. The difference between
    /// "you have not pressed this" and "you pressed it and you are still not
    /// verified" is the whole value of the button.
    private(set) var checkedAndStillUnverified = false
    private(set) var resendAvailableAt: Date?
    /// Carried over from sign-up: the account exists and no email went out.
    private(set) var setupNotice: String?

    private let auth: any AccountAuthenticating
    /// Told when verification turns true, so the session's own snapshot stops
    /// saying false. Without it the banner disappears and every other gate in
    /// the app goes on refusing.
    private let onVerified: @MainActor () -> Void

    init(auth: any AccountAuthenticating, onVerified: @escaping @MainActor () -> Void = {}) {
        self.auth = auth
        self.onVerified = onVerified
        let account = auth.currentAccount
        self.isSignedIn = account != nil
        self.isVerified = account?.isEmailVerified ?? false
        self.address = account?.email ?? ""
    }

    /// Nothing to show for a signed-out visitor, a verified account, or one
    /// that has been dismissed. The order matters: the web client's banner
    /// checked verification before checking for a user, and told signed-out
    /// visitors to verify their email.
    var isVisible: Bool { isSignedIn && !isVerified && !isDismissed }

    func cooldownRemaining(now: Date = Date()) -> Int {
        guard let resendAvailableAt else { return 0 }
        return max(0, Int(resendAvailableAt.timeIntervalSince(now).rounded(.up)))
    }

    func canResend(now: Date = Date()) -> Bool {
        !isSending && cooldownRemaining(now: now) == 0
    }

    /// Picks up anything sign-up left behind, once.
    func adoptNotice(from setup: AccountSetupService) {
        guard let uid = auth.currentAccount?.uid,
              let notice = setup.consumeNotice(for: uid)
        else { return }
        setupNotice = notice.message
    }

    /// Re-reads the account. Returns whether it is verified now.
    @discardableResult
    func checkNow() async -> Bool {
        guard !isChecking else { return isVerified }
        isChecking = true
        checkedAndStillUnverified = false
        defer { isChecking = false }

        do {
            let verified = try await auth.refreshVerification()
            isVerified = verified
            if verified {
                // The banner goes away on the next read of `isVisible`, and
                // the fresh token means posting works immediately rather than
                // whenever the old one happened to expire.
                onVerified()
            } else {
                checkedAndStillUnverified = true
            }
            return verified
        } catch {
            sendState = .failed(String(localized: "Could not check just now. Try again in a moment."))
            return isVerified
        }
    }

    /// Sends the verification email again.
    func resend(now: Date = Date()) async {
        guard canResend(now: now) else { return }
        isSending = true
        sendState = .idle
        // A resend answers the previous failure too: whatever it says, it is
        // about the send that just happened.
        setupNotice = nil
        defer { isSending = false }

        do {
            try await auth.sendVerificationEmail()
            sendState = .sent
            // A cooldown, so somebody tapping repeatedly gets a straight
            // answer instead of Firebase's rate limiter surfacing as a raw
            // error.
            resendAvailableAt = now.addingTimeInterval(Self.resendCooldown)
        } catch {
            // `sendVerificationEmail` is `throws(AuthError)`, so this binds an
            // `AuthError` and the words are already the ones to show.
            sendState = .failed(error.message)
        }
    }

    /// What the resend control says right now.
    func resendLabel(now: Date = Date()) -> String {
        if isSending { return String(localized: "Sending…") }
        let remaining = cooldownRemaining(now: now)
        return remaining > 0 ? String(localized: "Resend in \(remaining)s") : String(localized: "Resend email")
    }
}
