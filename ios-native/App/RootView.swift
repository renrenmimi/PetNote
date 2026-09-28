import SwiftUI

/// Chooses what the app shows, from the session and nothing else.
struct RootView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        switch session.state {
        case .restoring:
            // Not the sign-in screen: an already-signed-in person must not see
            // the app forget them while the Keychain read completes.
            RestoringView()
        case .signedOut:
            // No identifier on the container: SwiftUI propagates
            // accessibilityIdentifier to every descendant and overwrites the
            // ones they set for themselves, which left every element in the
            // signed-in screen answering to "root.signedIn". Screens are
            // identified by an element inside them instead.
            LoginView()
        case .signedIn(let user):
            SignedInView(user: user)
        }
    }
}

private struct RestoringView: View {
    var body: some View {
        // The web client's splash (`SplashScreen.tsx`): the paw at 64 over the
        // name in the brand gradient, on the plain background. Its pulse is
        // not carried over — an animation that repeats forever keeps the app
        // from ever reporting itself idle — and the native spinner below says
        // "working" instead.
        VStack(spacing: Spacing.l) {
            VStack(spacing: Spacing.m) {
                BrandMark(size: 64)
                Text("PetNote")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Palette.brandAccentGradient)
                    .accessibilityHidden(true)
            }
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .accessibilityIdentifier("root.restoring")
        .accessibilityLabel("Signing you in")
    }
}

