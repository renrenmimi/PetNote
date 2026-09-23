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
    /// Where the signed-out part of the app is. Local to this screen rather
    /// than in the app's `Route`: see `AuthRoute` for why nothing outside may
    /// link into sign-up or password reset.
    @State private var path: [AuthRoute] = []
    @FocusState private var focused: Field?

    /// Injected so the two screens behind this one can be driven by fakes.
    /// The defaults are what the app uses; `AccountSetupService.live` is a
    /// single instance for the process, and its own note says why that
    /// matters.
    private let auth: any AccountAuthenticating
    private let setup: AccountSetupService?

    init(auth: any AccountAuthenticating = LiveAccountAuth(), setup: AccountSetupService? = nil) {
        self.auth = auth
        self.setup = setup
    }

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
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    header
                    sessionEndedNotice
                    fields
                    submitButton
                    errorMessage
                    GoogleSignInButton()
                    alternatives
                    LegalLinks()
                    footer
                }
                .padding(.horizontal, Layout.pageInset)
                .padding(.vertical, Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.background)
            .onSubmit(submit)
            // No bar on the sign-in screen itself: this is the root of the
            // stack and an empty navigation bar above the logo is a strip of
            // nothing. The two screens pushed from here show their own, which
            // is where the back button comes from.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AuthRoute.self) { route in
                destination(for: route)
            }
        }
    }

    @ViewBuilder
    private func destination(for route: AuthRoute) -> some View {
        switch route {
        case .signUp:
            SignUpView(setup: setup ?? .live) { existingAddress in
                // The address comes back with them rather than being typed
                // twice, and the cursor lands on the field they still have to
                // fill. `path = []` and not a `removeLast`: this is "go to
                // sign-in", not "go back one".
                email = existingAddress
                path = []
                error = nil
                focused = .password
            }
        case .forgotPassword:
            ForgotPasswordView(auth: auth)
        }
    }

    /// The two ways out of "I cannot sign in".
    ///
    /// Both live on the page rather than inside the error, on purpose. The web
    /// client used to promote "create an account" into the wrong-password
    /// notice, which told somebody who mistyped their password that they had
    /// no account.
    private var alternatives: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            // The height goes on the label, inside the button. On the button
            // it made the row taller and left the control — what a finger and
            // VoiceOver get — at the text's own 17pt at the smallest type size.
            Button { path.append(.forgotPassword) } label: {
                Text("Forgot your password?")
                    .frame(minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
            }
            .font(Typography.body)
            .foregroundStyle(Palette.brandPrimary)
            .accessibilityIdentifier("login.forgotPassword")

            Button { path.append(.signUp) } label: {
                Text("New here? Create an account")
                    .frame(minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
            }
            .font(Typography.body)
            .foregroundStyle(Palette.brandPrimary)
            .accessibilityIdentifier("login.signUp")
        }
        .disabled(isSubmitting)
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

    /// Says why they are here, when they did not ask to be.
    ///
    /// A session revoked on the server drops the app back to this screen with
    /// no explanation at all otherwise, which reads as the app having forgotten
    /// them. Only shown for an expiry: someone who tapped "sign out" knows.
    @ViewBuilder
    private var sessionEndedNotice: some View {
        if session.endedReason == .expired {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(systemName: "clock.arrow.circlepath").accessibilityHidden(true)
                // The identifier goes on the Text, not the HStack: an
                // identifier on a container overwrites every descendant's, the
                // way root.signedIn once did to a whole screen.
                Text("Your session ended. Sign in again to pick up where you left off.")
                    .accessibilityIdentifier("login.sessionExpired")
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.warning)
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
                announce(failure.message)
            } catch {
                // signIn is `throws(AuthError)`, so this is unreachable; it
                // exists because the compiler cannot see that through the Task.
                // `self.` is required: catch binds its own `error`, which would
                // otherwise shadow the @State of the same name.
                self.error = .unknown
                announce(AuthError.unknown.message)
            }
        }
    }

    /// Says the failure out loud, for someone who cannot see it appear.
    ///
    /// The message is drawn *below* the button that was just pressed, so with
    /// VoiceOver on nothing moves and nothing is spoken: focus stays on "Sign
    /// in", which still says "Sign in", and the only report that anything
    /// happened is an element the person has to go looking for. The previous
    /// code claimed to announce this and did not — it added
    /// `.accessibilityAddTraits(.isStaticText)`, which describes an element
    /// and announces nothing.
    ///
    /// Not verifiable from XCUITest: announcements are not elements and the
    /// tree has nothing to read back. It needs VoiceOver and a person, and is
    /// recorded as unverified rather than as tested.
    private func announce(_ message: String) {
        var announcement = AttributedString(message)
        // Interrupts whatever is being read: this is the answer to the action
        // the person just took, and queueing it behind the button's own label
        // is how it gets missed.
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
    }
}

#if DEBUG
#Preview {
    LoginView(auth: PreviewAccountAuth(), setup: .preview).environment(SessionStore())
}
#endif
