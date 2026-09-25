import SwiftUI

/// First-run setup.
///
/// One step here — the name — and then completion. See `OnboardingModel` for
/// why the pet and follow steps are not in this file.
struct OnboardingView: View {
    @State private var model: OnboardingModel
    /// Called once onboarding is marked complete on the server.
    private let onComplete: () -> Void
    /// Called when the person closes it without finishing. The flow comes back
    /// on the next launch, because `onboardingComplete` is still false.
    private let onDismiss: () -> Void

    @FocusState private var nameFocused: Bool

    init(
        uid: String,
        users: any UserRepository,
        onComplete: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        _model = State(initialValue: OnboardingModel(uid: uid, users: users))
        self.onComplete = onComplete
        self.onDismiss = onDismiss
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    switch model.loadState {
                    case .loading:
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.xxl)
                            .accessibilityIdentifier("onboarding.loading")
                    case .failed(let message):
                        failure(message)
                    case .ready:
                        switch model.step {
                        case .name: nameStep
                        case .finished: finishStep
                        }
                    }
                }
                .padding(.horizontal, Layout.pageInset)
                .padding(.vertical, Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.background)
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onDismiss)
                        .accessibilityIdentifier("onboarding.close")
                }
            }
        }
        .task { await model.start() }
        .onChange(of: model.isComplete) { _, complete in
            if complete { onComplete() }
        }
    }

    // MARK: The name

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Pick a name")
                    .font(Typography.pageTitle)
                    .foregroundStyle(Palette.primaryText)
                    .accessibilityIdentifier("onboarding.title")
                // Says the name already works, which is what makes Skip a real
                // option rather than a way to end up with nothing.
                Text("We picked one for you. Change it if you would rather have your own.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.secondaryText)
            }

            TextField("Display name", text: $model.displayName)
                .font(Typography.body)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($nameFocused)
                .submitLabel(.done)
                .frame(minHeight: Layout.minTouchTarget)
                .accessibilityIdentifier("onboarding.name")

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("2–30 characters. Letters, numbers and spaces are fine, and it has to be unique.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.tertiaryText)
                if let message = model.name.status.message {
                    Text(message)
                        .font(Typography.caption)
                        .foregroundStyle(
                            model.name.status.blocksSaving ? Palette.danger : Palette.warning
                        )
                        .accessibilityIdentifier("onboarding.nameStatus")
                } else if model.name.status == .available {
                    Text("That name is available.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.success)
                        .accessibilityIdentifier("onboarding.nameAvailable")
                }
            }

            errorLine

            HStack {
                Button("Skip") {
                    nameFocused = false
                    model.skipName()
                }
                .font(Typography.body)
                .foregroundStyle(Palette.secondaryText)
                .frame(minHeight: Layout.minTouchTarget)
                .accessibilityIdentifier("onboarding.skip")

                Spacer()

                Button {
                    nameFocused = false
                    Task { await model.continueFromName() }
                } label: {
                    ZStack {
                        Text("Continue").opacity(model.isSavingName ? 0 : 1)
                        if model.isSavingName { ProgressView().tint(Palette.textOnBrand) }
                    }
                    .font(Typography.body)
                    .foregroundStyle(Palette.textOnBrand)
                    .padding(.horizontal, Spacing.xl)
                    .frame(minHeight: Layout.minTouchTarget)
                    .background(
                        model.canContinue
                            ? AnyShapeStyle(Palette.brandGradient)
                            : AnyShapeStyle(Palette.disabled),
                        in: .rect(cornerRadius: Radius.control)
                    )
                }
                .disabled(!model.canContinue)
                .accessibilityIdentifier("onboarding.continue")
            }
        }
    }

    // MARK: Finishing

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("You are set")
                .font(Typography.pageTitle)
                .foregroundStyle(Palette.primaryText)
                .accessibilityIdentifier("onboarding.finishTitle")
            Text("You can browse and follow straight away. Adding a pet is only needed to post, and can wait.")
                .font(Typography.body)
                .foregroundStyle(Palette.secondaryText)

            errorLine

            Button {
                Task { await model.finish() }
            } label: {
                ZStack {
                    Text("Start exploring").opacity(model.isFinishing ? 0 : 1)
                    if model.isFinishing { ProgressView().tint(Palette.textOnBrand) }
                }
                .font(Typography.body)
                .foregroundStyle(Palette.textOnBrand)
                .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
                .background(Palette.brandGradient, in: .rect(cornerRadius: Radius.control))
            }
            .disabled(model.isFinishing)
            .accessibilityIdentifier("onboarding.finish")
        }
    }

    @ViewBuilder
    private var errorLine: some View {
        if let message = model.errorMessage {
            Text(message)
                .font(Typography.caption)
                .foregroundStyle(Palette.danger)
                .accessibilityIdentifier("onboarding.error")
        }
    }

    @ViewBuilder
    private func failure(_ message: String) -> some View {
        VStack(spacing: Spacing.m) {
            Text(message)
                .font(Typography.body)
                .foregroundStyle(Palette.danger)
                .accessibilityIdentifier("onboarding.loadError")
            Button("Try again") { Task { await model.start() } }
                .font(Typography.body)
                .foregroundStyle(Palette.brandPrimary)
                .frame(minHeight: Layout.minTouchTarget)
                .accessibilityIdentifier("onboarding.loadRetry")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl)
    }
}

#if DEBUG
#Preview {
    OnboardingView(
        uid: "preview-uid",
        users: PreviewUserRepository(),
        onComplete: {},
        onDismiss: {}
    )
}
#endif
