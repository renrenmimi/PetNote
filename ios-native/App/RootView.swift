import SwiftUI

/// Chooses what the app shows. Stage 4 replaces the hardcoded `.login` with the
/// restored session, and must not flash this screen while that restore is in
/// flight (§10.1).
struct RootView: View {
    var body: some View {
        LoginView()
            .accessibilityIdentifier("root.login")
    }
}
