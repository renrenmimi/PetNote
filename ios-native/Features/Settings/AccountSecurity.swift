import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OSLog

/// The account operations the settings screen needs: proving it is really
/// the person (re-authentication), changing the password, and deleting the
/// account. Behind a protocol so the screens are tested over fakes; the live
/// version talks to Firebase Auth and `deleteUserAccount`.
protocol AccountSecurity: Sendable {
    /// The account's sign-in methods, as Firebase names them: `password`,
    /// `google.com`.
    func signInMethods() async -> [String]
    func reauthenticate(password: String) async throws(ReauthenticationError)
    func reauthenticate(google: GoogleTokens) async throws(ReauthenticationError)
    /// Re-authenticates with `current`, then sets `new`. The web client's
    /// order, in one step, so a stale session cannot change a password.
    func changePassword(current: String, to new: String) async throws(PasswordChangeError)
    /// `deleteUserAccount({userId})`. Returns when the server says it is done.
    func deleteAccount(uid: String) async throws(AccountDeletionError)
    /// After an answer that did not arrive: is the profile still there?
    /// Nil when that could not be read either.
    func profileExists(uid: String) async -> Bool?
    /// `users/{uid}.deletionPending` — a deletion that started and did not
    /// finish. Nil when it could not be read.
    func deletionPending(uid: String) async -> Bool?
}

enum ReauthenticationError: Error, Sendable, Equatable {
    case wrongPassword
    case tooManyAttempts
    case offline
    /// The Google account chosen is not the one signed in.
    case differentAccount
    case unknown

    var message: String {
        switch self {
        case .wrongPassword: String(localized: "That password is not correct.")
        case .tooManyAttempts: String(localized: "Too many attempts. Please try again later.")
        case .offline: String(localized: "No connection. Check your network and try again.")
        case .differentAccount: String(localized: "That Google account is not the one signed in.")
        case .unknown: String(localized: "Couldn't confirm it's you. Try again.")
        }
    }
}

/// The web client's words (settings.*), where it has them.
enum PasswordChangeError: Error, Sendable, Equatable {
    case currentPasswordIncorrect
    case tooManyAttempts
    case offline
    case failed

    var message: String {
        switch self {
        case .currentPasswordIncorrect: String(localized: "Current password is incorrect.")
        case .tooManyAttempts: String(localized: "Too many attempts. Please try again later.")
        case .offline: String(localized: "No connection. Check your network and try again.")
        case .failed: String(localized: "Failed to update password")
        }
    }
}

/// How a deletion ended when it did not end with the account gone.
enum AccountDeletionError: Error, Sendable, Equatable {
    /// Never left the device. Nothing was deleted.
    case offline
    /// `resource-exhausted`: three deletions an hour.
    case rateLimited
    case notSignedIn
    /// The server stopped part-way, or its answer never came and the profile
    /// is still there. Some data may already be gone, and the account cannot
    /// be used until a deletion finishes — the server has marked it as being
    /// deleted, which refuses every change.
    case notFinished
    case unknown

    var message: String {
        switch self {
        case .offline:
            String(localized: "You're offline, so nothing was deleted.")
        case .rateLimited:
            String(localized: "Too many attempts. Wait an hour and try again.")
        case .notSignedIn:
            String(localized: "Sign in again to delete your account.")
        case .notFinished:
            String(localized: "Deleting your account didn't finish. Some of it may already be gone. Try again to finish.")
        case .unknown:
            String(localized: "Failed to delete account.")
        }
    }
}

struct LiveAccountSecurity: AccountSecurity {
    private static let log = Logger(subsystem: "dev.local.petnote.native", category: "account")
    /// The server gives the cascade up to 540s. The SDK's default of 70s
    /// would report a deletion that is still running as a failure.
    static let deletionTimeout: TimeInterval = 600

    func signInMethods() async -> [String] {
        Auth.auth().currentUser?.providerData.map(\.providerID) ?? []
    }

    func reauthenticate(password: String) async throws(ReauthenticationError) {
        guard let user = Auth.auth().currentUser, let email = user.email else { throw .unknown }
        do {
            _ = try await user.reauthenticate(with: EmailAuthProvider.credential(withEmail: email, password: password))
        } catch {
            throw Self.mapReauthentication(error)
        }
    }

    func reauthenticate(google: GoogleTokens) async throws(ReauthenticationError) {
        guard let user = Auth.auth().currentUser else { throw .unknown }
        let credential = GoogleAuthProvider.credential(withIDToken: google.idToken, accessToken: google.accessToken)
        do {
            _ = try await user.reauthenticate(with: credential)
        } catch {
            throw Self.mapReauthentication(error)
        }
    }

    func changePassword(current: String, to new: String) async throws(PasswordChangeError) {
        guard let user = Auth.auth().currentUser, let email = user.email else { throw .failed }
        do {
            _ = try await user.reauthenticate(with: EmailAuthProvider.credential(withEmail: email, password: current))
            try await user.updatePassword(to: new)
        } catch {
            let code = AuthErrorCode(rawValue: (error as NSError).code)
            Self.log.error("password change failed: \((error as NSError).code)")
            switch code {
            case .wrongPassword, .invalidCredential: throw .currentPasswordIncorrect
            case .tooManyRequests: throw .tooManyAttempts
            case .networkError: throw .offline
            default: throw .failed
            }
        }
    }

    func deleteAccount(uid: String) async throws(AccountDeletionError) {
        let callable = Functions.functions().httpsCallable(Callables.deleteUserAccount)
        callable.timeoutInterval = Self.deletionTimeout
        do {
            _ = try await callable.call(["userId": uid])
        } catch {
            Self.log.error("deleteUserAccount failed: \(String(describing: error), privacy: .public)")
            throw Self.mapDeletion(error)
        }
    }

    func profileExists(uid: String) async -> Bool? {
        try? await Firestore.firestore().collection("users").document(uid).getDocument(source: .server).exists
    }

    func deletionPending(uid: String) async -> Bool? {
        guard let snapshot = try? await Firestore.firestore().collection("users").document(uid).getDocument() else {
            return nil
        }
        return snapshot.data()?["deletionPending"] as? Bool == true
    }

    static func mapReauthentication(_ error: Error) -> ReauthenticationError {
        switch AuthErrorCode(rawValue: (error as NSError).code) {
        case .wrongPassword, .invalidCredential: .wrongPassword
        case .tooManyRequests: .tooManyAttempts
        case .networkError: .offline
        case .userMismatch: .differentAccount
        default: .unknown
        }
    }

    /// `deleteUserAccount`'s refusals (functions/src/users.ts:485-685). Its
    /// three `internal` answers — a cascade step failed, the final
    /// transaction failed, the Auth user could not be removed — all leave a
    /// deletion that a retry finishes, and `CallableFailure` files `internal`
    /// with the answers that never came; both are "not finished", and the
    /// screen then asks the server whether the profile is still there.
    static func mapDeletion(_ error: Error) -> AccountDeletionError {
        switch CallableFailure.classify(error) {
        case .neverSent: return .offline
        case .unavailable: return .unknown
        case .unknownOutcome: return .notFinished
        case .server(let code, _):
            switch code {
            case .resourceExhausted: return .rateLimited
            case .unauthenticated: return .notSignedIn
            default: return .unknown
            }
        }
    }
}
