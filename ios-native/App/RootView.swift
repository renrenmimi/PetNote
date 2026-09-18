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
            SignedInPlaceholderView(user: user)
        }
    }
}

private struct RestoringView: View {
    var body: some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: "pawprint.fill")
                .font(Typography.pageTitle)
                .foregroundStyle(Palette.brandPrimary)
                .accessibilityHidden(true)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .accessibilityIdentifier("root.restoring")
        .accessibilityLabel("Signing you in")
    }
}

/// Stands in for the feed until stage 5. It shows what the session actually
/// resolved to, which is what stage 4's acceptance items check.
private struct SignedInPlaceholderView: View {
    let user: UserSession

    @Environment(SessionStore.self) private var session
    @State private var signOutFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Signed in")
                .font(Typography.pageTitle)
                .foregroundStyle(Palette.primaryText)

            // Each value is its own labelled element rather than a
            // LabeledContent: that packs label and value into one element whose
            // value is not addressable, which VoiceOver reads as a run-on and
            // UI tests cannot assert on.
            row("Account", value: user.email, id: "session.email")
            row(
                "Email verified",
                value: user.isEmailVerified ? "yes" : "no",
                id: "session.verified",
                tint: user.isEmailVerified ? Palette.success : Palette.warning
            )
            row("Backend", value: AppEnvironment.current.backend.rawValue, id: "session.backend")
            row("Build", value: AppEnvironment.current.buildStamp, id: "session.build")

            Button {
                do {
                    try session.signOut()
                } catch {
                    signOutFailed = true
                }
            } label: {
                // The frame and contentShape go on the *label*: putting
                // .frame(minHeight:) on the Button changes its layout size
                // without growing what can be tapped, which left this control
                // 20pt tall and not hittable at all. §5.5 asks for the hit area
                // to reach 44pt without the visual having to.
                Text("Sign out")
                    .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
            }
            .accessibilityIdentifier("session.signOut")

            if signOutFailed {
                Text("Could not sign out. Try again.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("session.signOutError")
            }
        }
        .font(Typography.body)
        .padding(Layout.pageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.background)
    }

    private func row(
        _ label: String,
        value: String,
        id: String,
        tint: Color = Palette.primaryText
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text(label).foregroundStyle(Palette.secondaryText)
            Spacer(minLength: Spacing.s)
            Text(value)
                .foregroundStyle(tint)
                .accessibilityIdentifier(id)
                .accessibilityLabel("\(label): \(value)")
        }
    }
}
