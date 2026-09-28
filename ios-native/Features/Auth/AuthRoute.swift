import Foundation

/// Where the signed-out part of the app can go.
///
/// Local to this feature on purpose. `Core/Navigation/Route` is the app's route
/// enum and is also what deep links resolve to — and nothing outside the app
/// may link *into* sign-up or password reset, because both are reached from the
/// one screen a signed-out person sees. Putting these there would add two cases
/// that `DeepLink` must then be trusted never to produce.
enum AuthRoute: Hashable, Sendable {
    case signUp
    case forgotPassword
}
