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
    /// Sign-up only. Unlike the sign-in failures above this one is safe to be
    /// specific about: the person is holding the address and asking to create
    /// an account with it, so "there is already one" is an answer to their own
    /// question rather than an oracle somebody else can query. The web client
    /// makes the same call, and pairs it with a way through to sign-in.
    case emailAlreadyInUse
    /// Email/password sign-up is switched off in the Firebase console.
    /// Nothing the person can do, and nothing a retry fixes.
    case signUpNotAllowed
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
        case .emailAlreadyInUse:
            self = .emailAlreadyInUse
        case .operationNotAllowed:
            self = .signUpNotAllowed
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
        case .emailAlreadyInUse:
            "That email already has an account. Sign in instead."
        case .signUpNotAllowed:
            "Creating an account with an email address is unavailable right now."
        case .unknown:
            "Something went wrong signing in. Try again."
        }
    }

    /// Whether the same request is worth repeating unchanged.
    var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .tooManyAttempts, .unknown: true
        case .invalidCredentials, .invalidEmailFormat, .accountDisabled, .weakPassword,
             .emailAlreadyInUse, .signUpNotAllowed: false
        }
    }
}
