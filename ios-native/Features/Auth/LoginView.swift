import SwiftUI

/// Sign-in.
///
/// The keyboard behaviour here is the part that has burned this product before:
/// on the web client the field being typed into ended up behind the keyboard,
/// and the fix that shipped waited a fixed 320ms for the keyboard to settle —
/// which the Chinese candidate bar, arriving after that, walked straight past.
/// Nothing here uses a delay: the scroll view reacts to the keyboard's actual
/// frame, and the focused field is kept visible by the system.
struct LoginView: View {
    @Environment(SessionStore.self) private var session

    @State private var email = ""
    @State private var password = ""
    @State private var error: AuthError?
    @State private var isSubmitting = false
    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case email
        case password
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !isSubmitting
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header
                fields
                submitButton
                errorMessage
                footer
            }
            .padding(.horizontal, Layout.pageInset)
            .padding(.vertical, Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.background)
        .onSubmit(submit)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Image(systemName: "pawprint.fill")
                .font(Typography.pageTitle)
                .foregroundStyle(Palette.brandPrimary)
                .accessibilityHidden(true)
            Text("PetNote")
                .font(Typography.pageTitle)
                .foregroundStyle(Palette.primaryText)
                .accessibilityIdentifier("login.title")
            Text("Sign in to continue")
                .font(Typography.body)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    private var fields: some View {
        VStack(spacing: Spacing.m) {
            TextField("Email", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .email)
                .submitLabel(.next)
                .accessibilityIdentifier("login.email")

            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($focused, equals: .password)
                .submitLabel(.go)
                .accessibilityIdentifier("login.password")
        }
        .font(Typography.body)
        .textFieldStyle(.roundedBorder)
        .frame(minHeight: Layout.minTouchTarget)
        .disabled(isSubmitting)
    }

    private var submitButton: some View {
        Button(action: submit) {
            ZStack {
                // The label stays in the layout while the spinner shows, so the
                // button does not change size mid-press.
                Text("Sign in").opacity(isSubmitting ? 0 : 1)
                if isSubmitting {
                    ProgressView().tint(Palette.textOnBrand)
                }
            }
            .font(Typography.body)
            .foregroundStyle(Palette.textOnBrand)
            .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
            .background(
                canSubmit ? AnyShapeStyle(Palette.brandGradient) : AnyShapeStyle(Palette.disabled),
                in: .rect(cornerRadius: Radius.control)
            )
        }
        .disabled(!canSubmit)
        .accessibilityIdentifier("login.submit")
        .accessibilityLabel(isSubmitting ? "Signing in" : "Sign in")
    }

    @ViewBuilder
    private var errorMessage: some View {
        if let error {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
                Text(error.message)
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.danger)
            .accessibilityIdentifier("login.error")
            // Announced rather than only shown: with VoiceOver on, a message
            // that appears below the button is easy to never reach.
            .accessibilityAddTraits(.isStaticText)
        }
    }

    private var footer: some View {
        Text("\(AppEnvironment.current.backend.rawValue) · \(AppEnvironment.current.buildStamp)")
            .font(Typography.caption)
            .foregroundStyle(Palette.tertiaryText)
            .accessibilityIdentifier("login.envNote")
    }

    private func submit() {
        guard canSubmit else {
            // Enter on the email field moves on rather than submitting nothing.
            if focused == .email { focused = .password }
            return
        }
        focused = nil
        error = nil
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                try await session.signIn(
                    email: email.trimmingCharacters(in: .whitespaces),
                    password: password
                )
                // No navigation here: RootView follows the session, so there is
                // one path into the signed-in state rather than two.
            } catch let failure as AuthError {
                self.error = failure
            } catch {
                // signIn is `throws(AuthError)`, so this is unreachable; it
                // exists because the compiler cannot see that through the Task.
                // `self.` is required: catch binds its own `error`, which would
                // otherwise shadow the @State of the same name.
                self.error = .unknown
            }
        }
    }
}

#Preview {
    LoginView().environment(SessionStore())
}
