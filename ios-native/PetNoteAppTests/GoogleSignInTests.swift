import FirebaseAuth
import Foundation
import GoogleSignIn
import Testing

@testable import PetNote

/// When "Continue with Google" exists, and what its failures become.
///
/// GoogleSignIn raises an Objective-C exception — which Swift cannot catch and
/// the app does not survive — when it has no client ID or its reversed form is
/// not a registered URL scheme. So the rule for showing the button is the
/// rule for not crashing, and it is held here case by case.
struct GoogleSignInTests {
    private let clientID = "1074612990862-abc123.apps.googleusercontent.com"
    private var scheme: String { "com.googleusercontent.apps.1074612990862-abc123" }

    @Test func theSchemeIsTheClientIDReversed() {
        #expect(GoogleSignInAvailability.reversed(clientID) == scheme)
    }

    @Test func offeredOnlyOnTheTestProjectWithAClientAndItsScheme() {
        #expect(GoogleSignInAvailability.clientID(
            backend: .testCloud, firebaseClientID: clientID, registeredSchemes: [scheme]
        ) == clientID)
    }

    @Test func aSchemeRegisteredInAnotherCaseStillCounts() {
        // GoogleSignIn lowercases both sides; so does this.
        #expect(GoogleSignInAvailability.clientID(
            backend: .testCloud, firebaseClientID: clientID, registeredSchemes: [scheme.lowercased()]
        ) == clientID)
    }

    @Test func notOfferedWhereItWouldCrashOrIsNotApproved() {
        let cases: [(AppEnvironment.Backend, String?, Set<String>, String)] = [
            (.emulator, clientID, [scheme], "the emulator has no Google client"),
            (.production, clientID, [scheme], "production is not switched on by a plist alone"),
            (.testCloud, nil, [scheme], "no client ID"),
            (.testCloud, "", [scheme], "an empty client ID"),
            (.testCloud, clientID, [], "the scheme is not registered"),
            (.testCloud, clientID, ["com.googleusercontent.apps.not-configured"], "the placeholder scheme"),
        ]
        for (backend, id, schemes, why) in cases {
            #expect(GoogleSignInAvailability.clientID(
                backend: backend, firebaseClientID: id, registeredSchemes: schemes
            ) == nil, "\(why)")
        }
    }

    @Test func backingOutIsNotAFailure() {
        let cancelled = NSError(domain: kGIDSignInErrorDomain, code: GIDSignInError.canceled.rawValue)
        #expect(LiveGoogleTokens.isCancellation(cancelled))
    }

    /// AppAuth's network error is also -5, in its own domain. Matching on the
    /// number alone would swallow a lost connection as a cancel.
    @Test func aLostConnectionWithTheSameNumberIsNotACancel() {
        let network = NSError(domain: "org.openid.appauth.general", code: -5)
        #expect(!LiveGoogleTokens.isCancellation(network))
        #expect(LiveGoogleTokens.map(network) == .networkUnavailable)
        #expect(LiveGoogleTokens.map(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)) == .networkUnavailable)
        #expect(LiveGoogleTokens.map(NSError(domain: "somewhere", code: 1)) == .unknown)
    }

    /// Firebase refusing a Google sign-in for an address set up another way:
    /// the web client's words, and not something a retry fixes. The app does
    /// not link the two accounts itself.
    @Test func anAddressSetUpAnotherWaySaysSoInTheWebsWords() {
        let error = NSError(domain: AuthErrorDomain, code: AuthErrorCode.accountExistsWithDifferentCredential.rawValue)
        let mapped = AuthError(error)
        #expect(mapped == .differentSignInMethod)
        #expect(mapped.message == String(localized: "This email is set up with another sign-in method. Use that one, or reset your password."))
        #expect(!mapped.isRetryable)
    }
}
