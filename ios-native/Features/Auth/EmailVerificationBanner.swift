import SwiftUI

/// "We sent you a link. Come back when you have opened it."
///
/// Three things the first version of this in the web client did not do, and
/// all three left people stuck rather than mildly inconvenienced:
///
///   1. **it did not say which address the link went to**, so a typo in the
///      email was invisible — somebody kept checking an inbox that was never
///      going to receive it;
///   2. **there was no way to say "I followed the link"**. Nothing tells this
///      app that happened, and the ID token's `email_verified` claim keeps
///      saying false for up to an hour, so posting went on being refused;
///   3. **resend had no cooldown and no honest failure state**, so a send that
///      failed looked exactly like one that worked.
struct EmailVerificationBanner: View {
    @State private var model: EmailVerificationModel
    private let setup: AccountSetupService?

    init(auth: any AccountAuthenticating, setup: AccountSetupService? = nil, onVerified: @escaping @MainActor () -> Void = {}) {
        _model = State(initialValue: EmailVerificationModel(auth: auth, onVerified: onVerified))
        self.setup = setup
    }

    var body: some View {
        if model.isVisible {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                banner(now: context.date)
            }
            .task {
                // Anything sign-up could not finish saying, said here — this
                // is the first screen that exists after it.
                if let setup { model.adoptNotice(from: setup) }
            }
        }
    }

    private func banner(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .top, spacing: Spacing.s) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Verify your email to start posting and commenting")
                        .font(Typography.sectionTitle)
                        .foregroundStyle(Palette.primaryText)
                        .accessibilityIdentifier("verify.title")
                    address
                    statusLines
                }
                Spacer(minLength: Spacing.s)
                Button {
                    model.isDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                }
                .foregroundStyle(Palette.secondaryText)
                .accessibilityIdentifier("verify.dismiss")
                .accessibilityLabel("Dismiss")
            }
            controls(now: now)
        }
        .padding(Spacing.l)
        .background(Palette.secondaryBackground, in: .rect(cornerRadius: Radius.card))
    }

    @ViewBuilder
    private var address: some View {
        if model.address.isEmpty {
            Text("Open the verification link we emailed you, then come back here.")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
        } else {
            // The exact address. A mistyped email was invisible while this
            // said only "check your inbox".
            Text("We sent a link to \(model.address). Open it, then come back here.")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
                .accessibilityIdentifier("verify.address")
        }
    }

    @ViewBuilder
    private var statusLines: some View {
        if let setupNotice = model.setupNotice {
            Text(setupNotice)
                .font(Typography.caption)
                .foregroundStyle(Palette.warning)
                .accessibilityIdentifier("verify.setupNotice")
        }
        switch model.sendState {
        case .idle:
            EmptyView()
        case .sent:
            Text("Sent. It can take a minute to arrive.")
                .font(Typography.caption)
                .foregroundStyle(Palette.success)
                .accessibilityIdentifier("verify.sent")
        case .failed(let message):
            Text(message)
                .font(Typography.caption)
                .foregroundStyle(Palette.danger)
                .accessibilityIdentifier("verify.sendFailed")
        }
        if model.checkedAndStillUnverified {
            Text("Still not verified. Open the link in the email first — if it has expired, resend it below.")
                .font(Typography.caption)
                .foregroundStyle(Palette.warning)
                .accessibilityIdentifier("verify.stillUnverified")
        }
    }

    private func controls(now: Date) -> some View {
        HStack(spacing: Spacing.l) {
            Button {
                Task { await model.checkNow() }
            } label: {
                ZStack {
                    Text("I verified my email").opacity(model.isChecking ? 0 : 1)
                    if model.isChecking { ProgressView().tint(Palette.textOnBrand) }
                }
                .font(Typography.body)
                .foregroundStyle(Palette.textOnBrand)
                .padding(.horizontal, Spacing.l)
                .frame(minHeight: Layout.minTouchTarget)
                .background(Palette.brandGradient, in: .rect(cornerRadius: Radius.control))
            }
            .disabled(model.isChecking)
            .accessibilityIdentifier("verify.check")

            Button {
                Task { await model.resend() }
            } label: {
                Text(model.resendLabel(now: now))
                    .font(Typography.caption)
                    .frame(minHeight: Layout.minTouchTarget)
            }
            .disabled(!model.canResend(now: now))
            .foregroundStyle(
                model.canResend(now: now) ? Palette.brandPrimary : Palette.tertiaryText
            )
            .accessibilityIdentifier("verify.resend")
        }
    }
}

#if DEBUG
#Preview {
    EmailVerificationBanner(auth: PreviewAccountAuth())
        .padding()
        .background(Palette.background)
}
#endif
