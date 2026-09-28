import Foundation
import Observation

/// The sign-up form: what may be submitted, and what the answer means.
///
/// Split from the view because the interesting behaviour is not visual. A
/// second submit arriving before the first returns, an account that exists
/// with a profile that does not, an address that is already taken — those are
/// assertable here and awkward to provoke through a screen.
@MainActor
@Observable
final class SignUpModel {
    /// What the person is told, and what they can do about it.
    ///
    /// A case rather than a string for the one notice that carries an action:
    /// "that address already has an account" is the only sign-up failure with
    /// an obvious next step, and burying it in prose loses it.
    enum Notice: Sendable, Equatable {
        case emailAlreadyInUse(email: String)
        case message(String)

        var text: String {
            switch self {
            case .emailAlreadyInUse:
                "That email already has an account. Sign in instead."
            case .message(let text):
                text
            }
        }
    }

    var email = ""
    var password = ""
    var confirmPassword = ""

    private(set) var isSubmitting = false
    private(set) var notice: Notice?
    /// Set once the account exists. The screen itself is on its way out by
    /// then — the app follows the session — so this is mostly for tests and
    /// for not submitting twice.
    private(set) var didCreateAccount = false

    private let setup: AccountSetupService

    init(setup: AccountSetupService) {
        self.setup = setup
    }

    var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var passwordsMatch: Bool { password == confirmPassword }

    /// Shown only once there is something to compare against, so the message
    /// does not accuse somebody of a mismatch while they are still typing the
    /// first character of the confirmation.
    var showsMismatch: Bool { !confirmPassword.isEmpty && !passwordsMatch }

    /// The same five conditions as the web client's `canSubmit`, in the same
    /// order. The length check is redundant with the policy check and is kept
    /// because dropping a rule from a copy is how two clients drift.
    var canSubmit: Bool {
        !trimmedEmail.isEmpty
            && password.count >= PasswordPolicy.minLength
            && !confirmPassword.isEmpty
            && passwordsMatch
            && PasswordPolicy.isValid(password)
            && !isSubmitting
            && !didCreateAccount
    }

    func dismissNotice() { notice = nil }

    /// Creates the account.
    ///
    /// **The fields are deliberately not cleared on failure.** Making somebody
    /// retype a password because a request failed is its own small punishment,
    /// and it defeats the password manager — the web client's handler carries
    /// the same note.
    func submit() async {
        // Checked and set in the same synchronous step, before any suspension.
        // `isSubmitting` also disables the button, but a disabled button is a
        // hint: a fast double tap, or a second Return, both fit in the gap
        // before the redraw.
        guard canSubmit else { return }
        isSubmitting = true
        notice = nil
        defer { isSubmitting = false }

        let address = trimmedEmail
        do {
            _ = try await setup.createAccount(email: address, password: password)
            // Only the line above can fail in a way that means "there is no
            // account". Everything after it is the service's problem, and it
            // reports through `pendingNotice` on a screen that still exists.
            didCreateAccount = true
        } catch let failure as AuthError {
            notice = Self.notice(for: failure, email: address)
        } catch {
            notice = .message(AuthError.unknown.message)
        }
    }

    /// Failure → what to say.
    ///
    /// Static and pure so the mapping can be checked directly. It is the part
    /// that decides whether somebody is told to sign in or told to try again,
    /// and a wrong branch here is invisible from the outside.
    static func notice(for error: AuthError, email: String) -> Notice {
        switch error {
        case .emailAlreadyInUse:
            .emailAlreadyInUse(email: email)
        default:
            .message(error.message)
        }
    }
}
