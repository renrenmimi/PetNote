import SwiftUI

/// The pets a person belongs to, under their profile — the web client's
/// profile "pets" tab.
///
/// "Belongs to", not "owns": the list comes from `family` memberships through
/// `PetChoiceProviding.pets(ownedBy:)`, which is the same read the composer's
/// pet picker uses and mirrors the web client's `getUserPets`. A co-owner sees
/// a shared pet here exactly as its primary owner does, because addition is
/// equal (HANDOFF §5.1) and nothing on this screen is a subtraction.
@MainActor
@Observable
final class MyPetsModel {
    enum State: Equatable {
        case loading
        case loaded([Pet])
        /// Only when there is nothing to show. A refresh that fails with pets
        /// already on screen keeps them and says so separately.
        case failed(String)
    }

    private(set) var state: State = .loading
    /// A failed refresh over a list that is still readable.
    private(set) var refreshFailure: String?

    private let uid: String
    private let source: any PetChoiceProviding

    init(uid: String, source: any PetChoiceProviding) {
        self.uid = uid
        self.source = source
    }

    var pets: [Pet] {
        if case .loaded(let pets) = state { return pets }
        return []
    }

    func load() async {
        refreshFailure = nil
        let hadPets = !pets.isEmpty
        if !hadPets { state = .loading }
        do {
            let pets = try await source.pets(ownedBy: uid)
            state = .loaded(pets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        } catch {
            // Keep what was readable. Replacing a list someone is looking at
            // with an error about it is the defect the feed and the comment
            // list both had and both lost.
            if hadPets {
                refreshFailure = "Couldn't refresh your pets."
            } else {
                state = .failed("Couldn't load your pets.")
            }
        }
    }
}

struct MyPetsSection: View {
    @State private var model: MyPetsModel
    private let onOpenPet: (String) -> Void
    private let onAddPet: () -> Void
    /// Bumped by the shell after a pet is created, edited or deleted, so the
    /// list is re-read rather than trusted.
    private let reloadToken: Int

    init(
        uid: String,
        source: any PetChoiceProviding,
        reloadToken: Int,
        onOpenPet: @escaping (String) -> Void,
        onAddPet: @escaping () -> Void
    ) {
        _model = State(initialValue: MyPetsModel(uid: uid, source: source))
        self.reloadToken = reloadToken
        self.onOpenPet = onOpenPet
        self.onAddPet = onAddPet
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            header
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: reloadToken) { await model.load() }
        .accessibilityIdentifier("profile.pets")
    }

    private var header: some View {
        HStack {
            Text("Pets")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.primaryText)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: onAddPet) {
                Label("Add a pet", systemImage: "plus")
                    .font(Typography.body)
                    .frame(minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
            }
            .foregroundStyle(Palette.brandPrimary)
            .accessibilityIdentifier("profile.addPet")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
                .accessibilityLabel("Loading your pets")
        case .failed(let message):
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                Button("Try again") { Task { await model.load() } }
                    .frame(minHeight: Layout.minTouchTarget)
                    .accessibilityIdentifier("profile.pets.retry")
            }
        case .loaded(let pets) where pets.isEmpty:
            // An empty state that says what to do, rather than a blank area
            // that could be a list that has not loaded yet.
            Text("You haven't added a pet yet.")
                .font(Typography.body)
                .foregroundStyle(Palette.secondaryText)
                .accessibilityIdentifier("profile.pets.empty")
        case .loaded(let pets):
            VStack(spacing: 0) {
                ForEach(pets) { pet in
                    row(pet)
                    if pet.id != pets.last?.id {
                        Divider().overlay(Palette.separator)
                    }
                }
            }
            .background(Palette.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            if let failure = model.refreshFailure {
                Text(failure)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
    }

    private static let rowAvatar: CGFloat = 44

    private func row(_ pet: Pet) -> some View {
        Button {
            onOpenPet(pet.id)
        } label: {
            HStack(spacing: Spacing.m) {
                avatar(pet)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pet.name)
                        .font(Typography.body)
                        .foregroundStyle(Palette.primaryText)
                        // Long names wrap rather than truncate: a pet's name is
                        // the one thing on this row that identifies it.
                        .multilineTextAlignment(.leading)
                    Text(PetDisplay.label(for: pet.species))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.tertiaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            .frame(minHeight: Layout.minTouchTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // One element per pet: the name and species read together and the
        // row activates as a single control, which is what it is.
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(pet.name)'s page")
        .accessibilityIdentifier("profile.pet.\(pet.id)")
    }

    private func avatar(_ pet: Pet) -> some View {
        Group {
            if pet.avatarURL != nil {
                RemoteImage(
                    url: pet.avatarURL, aspectRatio: 1,
                    cornerRadius: Self.rowAvatar / 2, size: .avatar
                )
                .frame(width: Self.rowAvatar, height: Self.rowAvatar)
            } else {
                Text(PetDisplay.emoji(for: pet.species))
                    .font(Typography.sectionTitle)
                    .frame(width: Self.rowAvatar, height: Self.rowAvatar)
                    .background(Palette.secondaryBackground)
                    .clipShape(Circle())
            }
        }
        .accessibilityHidden(true)
    }
}
