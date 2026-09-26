import FirebaseCore
import Foundation
import GoogleSignIn
import OSLog
import UIKit

/// The Google half of "Continue with Google": the two tokens Firebase needs.
///
/// Only Strings leave the Google SDK. Firebase does the sign-in itself
/// (`SessionStore.signInWithGoogle`), and it — not this — decides what happens
/// when the address already has an account: see `AuthError.differentSignInMethod`.
struct GoogleTokens: Sendable, Equatable {
    let idToken: String
    let accessToken: String
}

@MainActor
protocol GoogleTokenProviding {
    /// Whether the button exists at all.
    var isAvailable: Bool { get }
    /// The tokens, or nil when the person backed out. Backing out is not an
    /// error and says nothing, as on the web.
    func tokens() async throws(AuthError) -> GoogleTokens?
}

/// When Google sign-in may be offered.
///
/// Stricter than "is there a client ID", because GoogleSignIn does not fail
/// politely: with no configuration, an empty client ID, no presenting screen,
/// or a client ID whose reversed form is not registered as a URL scheme, it
/// raises an Objective-C exception that Swift cannot catch, and the app dies.
/// So all of it is checked first, and a build where any of it is missing —
/// the emulator, production until it has its own iOS client — simply has no
/// button.
enum GoogleSignInAvailability {
    /// This build's answer.
    static func current() -> String? {
        clientID(
            backend: AppEnvironment.current.backend,
            firebaseClientID: FirebaseApp.app()?.options.clientID,
            registeredSchemes: registeredSchemes(in: .main)
        )
    }

    static func clientID(
        backend: AppEnvironment.Backend,
        firebaseClientID: String?,
        registeredSchemes: Set<String>
    ) -> String? {
        // The test project only, named. A production plist that one day
        // carries a client ID does not switch this on by itself.
        guard backend == .testCloud else { return nil }
        guard let clientID = firebaseClientID, !clientID.isEmpty else { return nil }
        guard registeredSchemes.contains(reversed(clientID).lowercased()) else { return nil }
        return clientID
    }

    /// `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`,
    /// the URL scheme Google redirects back to.
    static func reversed(_ clientID: String) -> String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    static func registeredSchemes(in bundle: Bundle) -> Set<String> {
        let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        return Set(schemes.map { $0.lowercased() })
    }
}

/// The real Google sign-in page, through Google's SDK.
@MainActor
final class LiveGoogleTokens: GoogleTokenProviding {
    private let clientID: String?
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "auth")

    init(clientID: String? = GoogleSignInAvailability.current()) {
        self.clientID = clientID
    }

    var isAvailable: Bool { clientID != nil }

    func tokens() async throws(AuthError) -> GoogleTokens? {
        guard let clientID else { throw .unknown }
        guard let presenter = Self.topViewController() else {
            log.error("google: no screen to present the sign-in page from")
            throw .unknown
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let outcome: Result<GoogleTokens?, AuthError> = await withCheckedContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { result, error in
                if let error {
                    continuation.resume(returning: Self.isCancellation(error) ? .success(nil) : .failure(Self.map(error)))
                    return
                }
                guard let user = result?.user, let idToken = user.idToken?.tokenString else {
                    continuation.resume(returning: .failure(.unknown))
                    return
                }
                continuation.resume(returning: .success(
                    GoogleTokens(idToken: idToken, accessToken: user.accessToken.tokenString)
                ))
            }
        }
        switch outcome {
        case .success(let tokens): return tokens
        case .failure(let error):
            log.error("google: sign-in failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Cancelling, from the "wants to use google.com" prompt or from Google's
    /// own page, is `GIDSignInError.canceled`. AppAuth's network error has the
    /// same number (-5) in a different domain, so the domain is checked too.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == kGIDSignInErrorDomain && nsError.code == GIDSignInError.canceled.rawValue
    }

    nonisolated static func map(_ error: Error) -> AuthError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return .networkUnavailable }
        if nsError.domain == "org.openid.appauth.general", nsError.code == -5 { return .networkUnavailable }
        return .unknown
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

#if PETNOTE_FAULT_INJECTION
/// The Google half, stood in for on the emulator only.
///
/// The Auth emulator accepts an unsigned JSON identity as a Google ID token
/// (`{"sub":…,"email":…,"email_verified":true}`), so everything from Firebase
/// onwards — the credential sign-in, the profile, an address that already has
/// a password account — runs for real. Only Google's own page is skipped,
/// which no automated test may drive with a real account anyway.
///
///     -petnote-google-standin '{"sub":"g-1","email":"a@petnote.test","email_verified":true}'
///     -petnote-google-standin cancel     (the person backs out)
///     -petnote-google-standin fail       (Google's half fails)
@MainActor
final class StandInGoogleTokens: GoogleTokenProviding {
    static let argument = "-petnote-google-standin"
    private let identity: String

    init?(arguments: [String] = ProcessInfo.processInfo.arguments, environment: AppEnvironment = .current) {
        guard environment.backend == .emulator,
              let index = arguments.firstIndex(of: Self.argument),
              arguments.indices.contains(index + 1) else { return nil }
        identity = arguments[index + 1]
    }

    var isAvailable: Bool { true }

    func tokens() async throws(AuthError) -> GoogleTokens? {
        if identity == "cancel" { return nil }
        // Google's half failing, e.g. no connection on its page.
        if identity == "fail" { throw .networkUnavailable }
        return GoogleTokens(idToken: identity, accessToken: "stand-in")
    }
}
#endif

enum GoogleSignInProvider {
    /// The stand-in where a test asked for it on the emulator, the real SDK
    /// otherwise.
    @MainActor
    static func make() -> any GoogleTokenProviding {
        #if PETNOTE_FAULT_INJECTION
        if let standIn = StandInGoogleTokens() { return standIn }
        #endif
        return LiveGoogleTokens()
    }
}
