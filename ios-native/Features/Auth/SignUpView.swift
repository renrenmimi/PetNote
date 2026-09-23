import SwiftUI

/// Creating an account.
///
/// The keyboard behaviour matches `LoginView`'s and for the same reason: the
/// scroll view reacts to the keyboard's real frame, and nothing here waits a
/// fixed number of milliseconds for it to settle. This form is taller than
/// sign-in — five controls and a requirement list — so the confirm field is
/// exactly the one that ends up behind the keyboard when that is got wrong.
struct SignUpView: View {
    @State private var model: SignUpModel
    /// Takes the address back to sign-in when the account already exists.
    private let onUseExistingAccount: (String) -> Void

    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case email
        case password
        case confirmPassword
    }

    init(setup: AccountSetupService, onUseExistingAccount: @escaping (String) -> Void) {
        _model = State(initialValue: SignUpModel(setup: setup))
        self.onUseExistingAccount = onUseExistingAccount
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header
                noticeBanner
                fields
                passwordGuidance
                mismatchWarning
                submitButton
                legalNote
                GoogleSignInButton()
            }
            .padding(.horizontal, Layout.pageInset)
            .padding(.vertical, Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.background)
        .navigationTitle("Create account")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Create your account")
                .font(Typography.pageTitle)
                .foregroundStyle(Palette.primaryText)
                .accessibilityIdentifier("signup.title")
            Text("You can browse PetNote without one. An account is for posting.")
                .font(Typography.body)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = model.notice {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
                    Text(notice.text)
                        .accessibilityIdentifier("signup.error")
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.danger)

                // The one failure with an obvious next step gets a control for
                // it, carrying the address across so it does not have to be
                // typed again.
                if case .emailAlreadyInUse(let email) = notice {
                    Button { onUseExistingAccount(email) } label: {
                        Text("Sign in instead")
                            .frame(minHeight: Layout.minTouchTarget)
                            .contentShape(.rect)
                    }
                        .font(Typography.body)
                        .foregroundStyle(Palette.brandPrimary)
                        .accessibilityIdentifier("signup.useExistingAccount")
                }
            }
        }
    }

    private var fields: some View {
        VStack(spacing: Spacing.m) {
            TextField("Email", text: $model.email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .email)
                .submitLabel(.next)
                .accessibilityIdentifier("signup.email")

            // `.newPassword`, not `.password`: it is what makes iOS offer to
            // generate and save one, and what tells the Keychain this is a new
            // entry rather than a login to an existing account.
            SecureField("Password", text: $model.password)
                .textContentType(.newPassword)
                .focused($focused, equals: .password)
                .submitLabel(.next)
                .accessibilityIdentifier("signup.password")

            SecureField("Confirm password", text: $model.confirmPassword)
                .textContentType(.newPassword)
                .focused($focused, equals: .confirmPassword)
                .submitLabel(.go)
                .accessibilityIdentifier("signup.confirmPassword")
        }
        .font(Typography.body)
        .textFieldStyle(.roundedBorder)
        .frame(minHeight: Layout.minTouchTarget)
        .disabled(model.isSubmitting)
        .onSubmit(advance)
    }

    /// The rules, each with its own state.
    ///
    /// Shown as a list rather than collapsed into "password is not strong
    /// enough": a rule somebody cannot see is a rule they cannot satisfy, and
    /// the collapsed version is how people end up typing eight variations of
    /// the same password.
    @ViewBuilder
    private var passwordGuidance: some View {
        if !model.password.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Password strength: \(PasswordPolicy.strength(of: model.password).label)")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityIdentifier("signup.strength")
                ForEach(PasswordPolicy.requirements(for: model.password)) { requirement in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        Image(systemName: requirement.isMet ? "checkmark.circle.fill" : "circle")
                            .accessibilityHidden(true)
                        Text(requirement.text)
                    }
                    .font(Typography.caption)
                    .foregroundStyle(
                        requirement.isMet ? Palette.success : Palette.secondaryText
                    )
                    // The symbol is hidden from VoiceOver and the state said in
                    // words instead: "checkmark circle fill, At least 8
                    // characters" is not an answer to whether the rule is met.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        requirement.isMet
                            ? "Met: \(requirement.text)"
                            : "Not met yet: \(requirement.text)"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var mismatchWarning: some View {
        if model.showsMismatch {
            Text("Those two passwords do not match.")
                .font(Typography.caption)
                .foregroundStyle(Palette.danger)
                .accessibilityIdentifier("signup.mismatch")
        }
    }

    private var submitButton: some View {
        Button(action: submit) {
            ZStack {
                // The label stays in the layout while the spinner shows, so
                // the button does not resize mid-press.
                Text("Create account").opacity(model.isSubmitting ? 0 : 1)
                if model.isSubmitting {
                    ProgressView().tint(Palette.textOnBrand)
                }
            }
            .font(Typography.body)
            .foregroundStyle(Palette.textOnBrand)
            .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
            .background(
                model.canSubmit
                    ? AnyShapeStyle(Palette.brandGradient)
                    : AnyShapeStyle(Palette.disabled),
                in: .rect(cornerRadius: Radius.control)
            )
        }
        .disabled(!model.canSubmit)
        .accessibilityIdentifier("signup.submit")
        .accessibilityLabel(model.isSubmitting ? "Creating account" : "Create account")
    }

    /// The agreement, and the two documents it refers to, one tap away —
    /// the line used to be plain text with nothing to open.
    private var legalNote: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("By creating an account you agree to the Terms and the Privacy Policy.")
                .font(Typography.caption)
                .foregroundStyle(Palette.tertiaryText)
                .accessibilityIdentifier("signup.legal")
            LegalLinks()
        }
    }

    /// Return moves to the next empty field rather than submitting a form that
    /// cannot be submitted.
    private func advance() {
        switch focused {
        case .email: focused = .password
        case .password: focused = .confirmPassword
        default: submit()
        }
    }

    private func submit() {
        guard model.canSubmit else { return }
        focused = nil
        Task { await model.submit() }
        // No navigation here: the account being created signs it in, and the
        // app follows the session. A second path into the signed-in state is
        // how the two disagree.
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        SignUpView(setup: AccountSetupService.preview, onUseExistingAccount: { _ in })
    }
}
#endif
