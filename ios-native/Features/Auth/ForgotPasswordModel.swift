import Foundation
import Observation

/// Password recovery: Firebase's own emailed reset link.
///
/// **There is no code flow here, on purpose.** The web client can do either —
/// `passwordResetOtpEnabled` picks — and in production it is off: the feature
/// flag is false and the three secrets the callables need do not exist in that
/// project, so `requestPasswordResetCodeCallable` and
/// `confirmPasswordResetCodeCallable` would fail as "not configured" for every
/// real person. Porting the branch that production does not run would be
/// porting a path nobody has ever used.
@MainActor
@Observable
final class ForgotPasswordModel {
    enum Status: Sendable, Equatable {
        case idle
        case sent
        case failed
    }

    /// Matches the server's own cooldown, so the button does not re-enable
    /// into a request the server will refuse.
    static let resendCooldown: TimeInterval = 60

    var email = ""

    private(set) var isSending = false
    private(set) var status: Status = .idle
    private(set) var message = ""
    /// When another send becomes available. Stored as an instant rather than a
    /// ticking integer so the remaining time is correct after the app has been
    /// in the background — a counter driven by a timer that stopped comes back
    /// saying 47 seconds forever.
    private(set) var resendAvailableAt: Date?

    private let auth: any AccountAuthenticating

    init(auth: any AccountAuthenticating) {
        self.auth = auth
    }

    var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a send may be started right now.
    ///
    /// The cooldown is part of this, not only of the button's `disabled`
    /// state. A disabled control is a hint: a second Return in the same run
    /// loop turn, or a double tap, both arrive before the redraw — and the
    /// server refuses a request inside its own cooldown anyway, so sending it
    /// buys a rate-limit error in place of a countdown.
    func canSend(now: Date = Date()) -> Bool {
        !trimmedEmail.isEmpty && !isSending && cooldownRemaining(now: now) == 0
    }

    /// Whether the person is past the first send and has a resend to offer.
    var hasSentOnce: Bool { resendAvailableAt != nil }

    func cooldownRemaining(now: Date = Date()) -> Int {
        guard let resendAvailableAt else { return 0 }
        return max(0, Int(resendAvailableAt.timeIntervalSince(now).rounded(.up)))
    }

    /// Only after a success, and it is about the email that was sent.
    var showsSpamHint: Bool { status == .sent }

    /// Sends the reset link.
    ///
    /// Two things this gets right that the code it is ported from got wrong
    /// first:
    ///
    ///   - **it does not probe for the account.** `fetchSignInMethodsForEmail`
    ///     returns an empty array regardless under Email Enumeration
    ///     Protection, and `sendPasswordReset` succeeds silently for an
    ///     address nobody owns. Both are the privacy-correct behaviour and the
    ///     copy says "if" for that reason;
    ///   - **a failure about *this request* is reported as one.** The previous
    ///     version showed the neutral "if an account exists" line for every
    ///     error, so sending with no connection looked exactly like success.
    ///     Anything that might say something about the *account* keeps the
    ///     neutral line, because which errors those are is Firebase's business
    ///     and guessing reopens enumeration.
    func send(now: Date = Date()) async {
        // Synchronous guard before any suspension: a disabled button does not
        // stop a second Return arriving in the same run loop turn.
        guard canSend(now: now) else { return }
        isSending = true
        status = .idle
        message = ""
        defer { isSending = false }

        let address = trimmedEmail
        do {
            try await auth.sendPasswordResetEmail(to: address)
            status = .sent
            message = String(localized: "Reset link sent. Check your email.")
            resendAvailableAt = now.addingTimeInterval(Self.resendCooldown)
        } catch {
            // `sendPasswordResetEmail` is `throws(AuthError)`, so `error` is
            // already an `AuthError` and there is no second kind to sort out.
            status = .failed
            message = Self.message(for: error)
        }
    }

    /// Back to the address field, with everything about the previous attempt
    /// dropped — including the cooldown, which belonged to the old address.
    func useADifferentEmail() {
        status = .idle
        message = ""
        resendAvailableAt = nil
    }

    static var neutralFallback: String {
        String(localized: "If an account exists with this email, we have sent a reset link. If you signed up with Google, use Google Sign-In instead.")
    }

    /// Failure → what to say, keeping the enumeration rule.
    ///
    /// Only the three failures that are about the *request* get specific words.
    /// Everything else — including "no such account", whatever shape it
    /// arrives in — falls back to the neutral line.
    static func message(for error: AuthError) -> String {
        switch error {
        case .networkUnavailable:
            String(localized: "We could not reach PetNote. Check your connection and try again.")
        case .tooManyAttempts:
            String(localized: "Too many attempts from this device. Wait a minute and try again.")
        case .invalidEmailFormat:
            String(localized: "Please enter a valid email address.")
        default:
            neutralFallback
        }
    }
}
