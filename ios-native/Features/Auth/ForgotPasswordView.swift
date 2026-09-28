import SwiftUI

/// "I cannot get in."
///
/// One screen, one field, one button, and a resend that says how long is left.
/// There is no code-entry step: see `ForgotPasswordModel` for why the OTP path
/// is not ported.
struct ForgotPasswordView: View {
    @State private var model: ForgotPasswordModel
    @FocusState private var emailFocused: Bool

    init(auth: any AccountAuthenticating) {
        _model = State(initialValue: ForgotPasswordModel(auth: auth))
    }

    var body: some View {
        // The cooldown is a countdown, and a countdown that does not tick is a
        // dead button with a stale number on it. TimelineView redraws once a
        // second and reads the remaining time from the *clock*, so a spell in
        // the background does not leave it stuck at 47.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .navigationTitle("Reset password")
        .navigationBarTitleDisplayMode(.inline)
        // The card has the title; see SignUpView.
        .toolbar(removing: .title)
    }

    private func content(now: Date) -> some View {
        AuthShell {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header
                emailField
                sendButton(now: now)
                statusMessage
                spamHint
                resendControls(now: now)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Reset password")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("forgot.title")
            Text("Enter your email and we will send you a reset link.")
                .font(Typography.body)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    private var emailField: some View {
        TextField("Email", text: $model.email)
            .textContentType(.username)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($emailFocused)
            .submitLabel(.go)
            .font(Typography.body)
            .textFieldStyle(.roundedBorder)
            .frame(minHeight: Layout.minTouchTarget)
            .disabled(model.isSending)
            .accessibilityIdentifier("forgot.email")
            .onSubmit(send)
    }

    private func sendButton(now: Date) -> some View {
        Button(action: send) {
            ZStack {
                Text(model.hasSentOnce ? "Send again" : "Send reset link")
                    .opacity(model.isSending ? 0 : 1)
                if model.isSending {
                    ProgressView().tint(Palette.textOnBrand)
                }
            }
            .font(Typography.body)
            .foregroundStyle(Palette.textOnBrand)
            .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
            .background(
                model.canSend(now: now)
                    ? AnyShapeStyle(Palette.brandGradient)
                    : AnyShapeStyle(Palette.disabled),
                in: .rect(cornerRadius: Radius.control)
            )
        }
        .disabled(!model.canSend(now: now))
        .accessibilityIdentifier("forgot.submit")
        .accessibilityLabel(model.isSending ? "Sending" : "Send reset link")
    }

    @ViewBuilder
    private var statusMessage: some View {
        if model.status != .idle {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(
                    systemName: model.status == .sent
                        ? "checkmark.circle.fill"
                        : "exclamationmark.circle.fill"
                )
                .accessibilityHidden(true)
                Text(model.message)
            }
            .font(Typography.caption)
            .foregroundStyle(model.status == .sent ? Palette.success : Palette.danger)
            .accessibilityIdentifier("forgot.status")
        }
    }

    @ViewBuilder
    private var spamHint: some View {
        if model.showsSpamHint {
            Text("Not there after a minute? Check your spam or junk folder.")
                .font(Typography.caption)
                .foregroundStyle(Palette.tertiaryText)
                .accessibilityIdentifier("forgot.spamHint")
        }
    }

    @ViewBuilder
    private func resendControls(now: Date) -> some View {
        if model.hasSentOnce {
            VStack(alignment: .leading, spacing: Spacing.m) {
                let remaining = model.cooldownRemaining(now: now)
                Button(action: send) {
                    Text(remaining > 0 ? "Send the link again in \(remaining)s" : "Send the link again")
                        .font(Typography.body)
                        .frame(minHeight: Layout.minTouchTarget)
                }
                .disabled(!model.canSend(now: now))
                .foregroundStyle(
                    model.canSend(now: now) ? Palette.brandPrimary : Palette.tertiaryText
                )
                .accessibilityIdentifier("forgot.resend")

                Button("Use a different email") {
                    model.useADifferentEmail()
                    emailFocused = true
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
                .frame(minHeight: Layout.minTouchTarget)
                .accessibilityIdentifier("forgot.changeEmail")
            }
        }
    }

    private func send() {
        guard model.canSend() else { return }
        emailFocused = false
        Task { await model.send() }
    }
}

#if DEBUG
#Preview {
    NavigationStack { ForgotPasswordView(auth: PreviewAccountAuth()) }
}
#endif
