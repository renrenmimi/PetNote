import SwiftUI

/// Joining a pet's family with an invitation code — the web's "Join existing"
/// tab on the Add Pet page.
struct JoinFamilyView: View {
    @State private var model: JoinFamilyModel
    private let onOpenPet: (String) -> Void
    @FocusState private var codeFocused: Bool

    init(model: JoinFamilyModel, onOpenPet: @escaping (String) -> Void) {
        _model = State(initialValue: model)
        self.onOpenPet = onOpenPet
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                switch model.step {
                case .entering, .checking:
                    codeEntry
                case .choosing(_, let petName), .joining(_, let petName):
                    relationshipChoice(petName: petName)
                case .joined(let pet, let alreadyMember):
                    joined(pet, alreadyMember: alreadyMember)
                }
                if let message = model.message {
                    Text(message)
                        .font(Typography.body)
                        .foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("join.message")
                }
            }
            .padding(.horizontal, Layout.pageInset)
            .padding(.vertical, Spacing.l)
        }
        .background(Palette.background)
        .navigationTitle("Join a family")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Steps

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Join your pet's family with an invitation code")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Ask one of the pet's owners for the \(InvitationCode.length)-character code on their Owners screen.")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            TextField(
                "ABCD EFGH",
                text: Binding(get: { model.formattedCode }, set: { model.updateCode($0) })
            )
            .font(Typography.pageTitle.monospaced())
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .submitLabel(.go)
            .focused($codeFocused)
            .onSubmit { Task { await model.check() } }
            .padding(Spacing.m)
            .background(Palette.cardBackground, in: .rect(cornerRadius: Radius.control))
            .disabled(model.step == .checking)
            .accessibilityLabel("Invitation code")
            .accessibilityIdentifier("join.code")

            Button { Task { await model.check() } } label: {
                HStack(spacing: Spacing.s) {
                    if model.step == .checking { ProgressView().tint(Palette.textOnBrand) }
                    Text(model.step == .checking ? "Checking…" : "Check code")
                }
            }
            .buttonStyle(SocialButtonStyle(kind: .primary, fullWidth: true))
            .disabled(!model.canCheck)
            .accessibilityIdentifier("join.check")
        }
    }

    private func relationshipChoice(petName: String) -> some View {
        let isJoining: Bool = { if case .joining = model.step { return true } else { return false } }()
        return VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Code accepted for \(petName).")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.success)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("join.accepted")
            Text("What's your relationship to \(petName)?")
                .font(Typography.body)
                .foregroundStyle(Palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("It is only a label. Every owner can do the same things.")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104), spacing: Spacing.s)],
                spacing: Spacing.s
            ) {
                ForEach(PetFamilyRelationship.allCases, id: \.self) { option in
                    relationshipButton(option)
                }
            }
            .disabled(isJoining)

            if model.relationship == .other {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    TextField(
                        "Describe it (optional)",
                        text: Binding(
                            get: { model.customRelationship },
                            set: { model.updateCustomRelationship($0) }
                        )
                    )
                    .padding(Spacing.m)
                    .background(Palette.cardBackground, in: .rect(cornerRadius: Radius.control))
                    .accessibilityIdentifier("join.custom")
                    Text("\(model.customRelationship.count)/\(PetValidation.customRelationshipLimit)")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityLabel(
                            "\(model.customRelationship.count) of \(PetValidation.customRelationshipLimit) characters"
                        )
                }
                .disabled(isJoining)
            }

            Button { Task { await model.join() } } label: {
                HStack(spacing: Spacing.s) {
                    if isJoining { ProgressView().tint(Palette.textOnBrand) }
                    Text(isJoining ? "Joining…" : "Join \(petName)'s family")
                        .multilineTextAlignment(.center)
                }
            }
            .buttonStyle(SocialButtonStyle(kind: .primary, fullWidth: true))
            .disabled(!model.canJoin)
            .accessibilityIdentifier("join.submit")

            Button("Use a different code") { model.startOver() }
                .buttonStyle(SocialButtonStyle(kind: .secondary, fullWidth: true))
                .disabled(isJoining)
                .accessibilityIdentifier("join.startOver")
        }
    }

    private func relationshipButton(_ option: PetFamilyRelationship) -> some View {
        let selected = model.relationship == option
        return Button { model.relationship = option } label: {
            VStack(spacing: Spacing.xs) {
                Text(Self.emoji(for: option)).accessibilityHidden(true)
                Text(PetDisplay.label(for: option))
                    .font(Typography.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(selected ? Palette.brandPrimary : Palette.primaryText)
            .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
            .padding(.vertical, Spacing.s)
            .background(Palette.cardBackground, in: .rect(cornerRadius: Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control)
                    .stroke(selected ? Palette.brandPrimary : Palette.separator, lineWidth: selected ? 2 : 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("join.relationship.\(option.rawValue)")
    }

    private func joined(_ pet: JoinedPet, alreadyMember: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(alreadyMember
                 ? "You are already one of \(pet.petName)'s owners."
                 : "Welcome to \(pet.petName)'s family!")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("join.done")
            Text("You can edit \(pet.petName), post about them, and invite others.")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
            Button("Open \(pet.petName)'s page") { onOpenPet(pet.petID) }
                .buttonStyle(SocialButtonStyle(kind: .primary, fullWidth: true))
                .accessibilityIdentifier("join.openPet")
        }
    }

    /// The web selector's marks. Decoration only; the word beside each is
    /// what VoiceOver reads.
    static func emoji(for relationship: PetFamilyRelationship) -> String {
        switch relationship {
        case .mom: return "👩"
        case .dad: return "👨"
        case .sister: return "👧"
        case .brother: return "👦"
        case .grandma: return "👵"
        case .grandpa: return "👴"
        case .auntie: return "🧓"
        case .uncle: return "🧔"
        case .bestFriend: return "👫"
        case .caretaker: return "🤝"
        case .other: return "📝"
        }
    }
}

#if DEBUG
#Preview("Join") {
    NavigationStack {
        JoinFamilyView(
            model: JoinFamilyModel(viewerID: "me", repository: PreviewFamilyRepository()),
            onOpenPet: { _ in }
        )
    }
}
#endif
