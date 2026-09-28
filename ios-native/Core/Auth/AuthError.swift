import FirebaseAuth
import Foundation

/// What went wrong signing in, in terms a person can act on.
///
/// The raw error is never shown. Firebase's messages name the SDK and leak
/// whether an account exists, and neither helps the person in front of the
/// screen.
enum AuthError: Error, Sendable, Equatable {
    /// One message for both "no such account" and "wrong password", on purpose:
    /// telling them apart is an account-enumeration oracle, and the web client
    /// already treats them as one case.
    case invalidCredentials
    case invalidEmailFormat
    case networkUnavailable
    case tooManyAttempts
    case accountDisabled
    case weakPassword
    case unknown

    init(_ error: Error) {
        let code = AuthErrorCode(rawValue: (error as NSError).code)
        switch code {
        case .wrongPassword, .userNotFound, .invalidCredential:
            self = .invalidCredentials
        case .invalidEmail, .missingEmail:
            self = .invalidEmailFormat
        case .networkError:
            self = .networkUnavailable
        case .tooManyRequests:
            self = .tooManyAttempts
        case .userDisabled:
            self = .accountDisabled
        case .weakPassword:
            self = .weakPassword
        default:
            self = .unknown
        }
    }

    var message: String {
        switch self {
        case .invalidCredentials:
            "That email and password do not match an account."
        case .invalidEmailFormat:
            "That does not look like an email address."
        case .networkUnavailable:
            "No connection. Check your network and try again."
        case .tooManyAttempts:
            "Too many attempts. Wait a moment before trying again."
        case .accountDisabled:
            "This account has been disabled."
        case .weakPassword:
            "Choose a longer password."
        case .unknown:
            "Something went wrong signing in. Try again."
        }
    }

    /// Whether the same request is worth repeating unchanged.
    var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .tooManyAttempts, .unknown: true
        case .invalidCredentials, .invalidEmailFormat, .accountDisabled, .weakPassword: false
        }
    }
}
