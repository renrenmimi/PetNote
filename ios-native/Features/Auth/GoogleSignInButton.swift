import SwiftUI

/// "Continue with Google", on the sign-in and sign-up screens, where this
/// build can offer it (`GoogleSignInAvailability`). Everywhere else it is not
/// there at all rather than a button that cannot work.
///
/// It carries its own failure line: the two screens it sits on keep their
/// errors differently, and what went wrong with Google belongs next to the
/// Google button.
struct GoogleSignInButton: View {
    @Environment(SessionStore.self) private var session
    @State private var google: any GoogleTokenProviding = GoogleSignInProvider.make()
    @State private var isWorking = false
    @State private var failure: AuthError?

    var body: some View {
        if google.isAvailable {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Button(action: start) {
                    ZStack {
                        Text("Continue with Google").opacity(isWorking ? 0 : 1)
                        if isWorking { ProgressView() }
                    }
                    .font(Typography.body)
                    .foregroundStyle(Palette.primaryText)
                    .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
                    .background(Palette.cardBackground, in: .rect(cornerRadius: Radius.control))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control)
                            .strokeBorder(Palette.separator)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .accessibilityLabel(isWorking ? "Connecting to Google" : "Continue with Google")
                .accessibilityIdentifier("auth.google")

                if let failure {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
                        Text(failure.message)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("auth.googleError")
                }
            }
        }
    }

    private func start() {
        failure = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do throws(AuthError) {
                // False is the person backing out of Google's page: nothing
                // to say, as on the web. True hands over to the session,
                // which replaces this screen.
                _ = try await session.signInWithGoogle(using: google)
            } catch {
                failure = error
            }
        }
    }
}
