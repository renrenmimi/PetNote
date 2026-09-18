import SwiftUI

/// The sign-in screen's layout and accessibility, with no authentication behind
/// it yet: the session work is stage 4. It exists now because acceptance item
/// 2.5 asserts that launching the app shows this screen, and because the
/// keyboard behaviour it has to get right (§6.3) is the thing the web client
/// got wrong on a real phone.
struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focused: Field?

    private enum Field {
        case email
        case password
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header

                VStack(spacing: Spacing.m) {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }
                        .accessibilityIdentifier("login.email")

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focused, equals: .password)
                        .submitLabel(.go)
                        .accessibilityIdentifier("login.password")
                }
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: Layout.minTouchTarget)

                Button {
                    // Stage 4 wires this to FirebaseAuth.
                } label: {
                    Text("Sign in")
                        .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("login.submit")

                Text("Stage 1 build — emulator only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("login.envNote")
            }
            .padding(.horizontal, Layout.pageInset)
            .padding(.vertical, Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Keeps the focused field above the keyboard without a fixed delay; the
        // web client's 320ms guess is exactly what this avoids (§6.3).
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemBackground))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Image(systemName: "pawprint.fill")
                .font(.largeTitle)
                .accessibilityHidden(true)
            Text("PetNote")
                .font(.largeTitle)
                .fontWeight(.semibold)
                .accessibilityIdentifier("login.title")
            Text("Sign in to continue")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    LoginView()
}
