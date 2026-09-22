import SwiftUI

/// Somebody's profile: who they are, and the pets they are an owner of.
struct UserProfileView: View {
    @State private var model: UserProfileModel
    private let onOpenPet: (String) -> Void
    private let onOpenFollowing: () -> Void

    /// - Parameter onOpenFollowing: the viewer's own "Following" list. Only
    ///   offered on their own profile — `followingPets` is owner-only by rule,
    ///   so for anyone else it would always read empty.
    init(
        model: UserProfileModel,
        onOpenPet: @escaping (String) -> Void,
        onOpenFollowing: @escaping () -> Void
    ) {
        _model = State(initialValue: model)
        self.onOpenPet = onOpenPet
        self.onOpenFollowing = onOpenFollowing
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                switch model.state {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.xxl)
                        .accessibilityIdentifier("user.loading")
                case .blocked:
                    blocked
                case .missing:
                    SocialNotice(
                        title: "This account is not available.",
                        detail: "It may have been deleted.",
                        identifier: "user.missing"
                    )
                case .denied:
                    SocialNotice(
                        title: "This profile is not visible to you.",
                        detail: "It may be private, or the account may no longer be active.",
                        identifier: "user.denied"
                    )
                case .failed(let message):
                    SocialRetryNotice(message: message, identifier: "user.failed") {
                        await model.load()
                    }
                case .loaded(let profile):
                    header(profile)
                    stats
                    Text(model.joinedLine)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .frame(maxWidth: .infinity)
                    petsSection
                }
            }
            .padding(.horizontal, Layout.pageInset)
            .padding(.vertical, Spacing.l)
        }
        .background(Palette.background)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.state == .loading { await model.load() } }
        .refreshable { await model.load() }
    }

    // MARK: - Header

    private func header(_ profile: PublicProfile) -> some View {
        VStack(spacing: Spacing.s) {
            SocialAvatar(url: profile.avatarURL, name: model.displayName, size: SocialLayout.headerAvatar)
            Text(model.displayName)
                .font(Typography.pageTitle)
                .foregroundStyle(Palette.primaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("user.name")
            if !profile.displayName.isEmpty {
                Text("@\(profile.displayName)")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !profile.bio.isEmpty {
                Text(profile.bio)
                    .font(Typography.body)
                    .foregroundStyle(Palette.primaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("user.bio")
            }
            if let location = model.locationLine {
                Text(location)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var stats: some View {
        HStack(spacing: 0) {
            stat(value: model.petCountText, label: "Pets")
                .accessibilityIdentifier("user.petCount")
            Divider().frame(height: Layout.minTouchTarget)
            if model.isSelf {
                Button(action: onOpenFollowing) {
                    stat(value: "\(model.followingCount)", label: "Following")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the pets you follow.")
                .accessibilityIdentifier("user.following")
            } else {
                stat(value: "\(model.followingCount)", label: "Following")
                    .accessibilityIdentifier("user.following")
            }
        }
        .padding(.vertical, Spacing.s)
        .background(Palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: Spacing.xs) {
            Text(value)
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.primaryText)
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pets

    @ViewBuilder
    private var petsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Pets")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.primaryText)
                .accessibilityAddTraits(.isHeader)
            switch model.petsState {
            case .loading where model.pets.isEmpty:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("user.petsLoading")
            case .failed(let message):
                SocialRetryNotice(message: message, identifier: "user.petsFailed") {
                    await model.retryPets()
                }
            case .loaded where model.pets.isEmpty:
                SocialNotice(title: "No pets yet", identifier: "user.petsEmpty")
            default:
                ForEach(model.pets) { pet in
                    petRow(pet)
                }
            }
        }
    }

    private func petRow(_ entry: ProfilePet) -> some View {
        SocialAdaptiveStack {
            Button { onOpenPet(entry.pet.id) } label: {
                HStack(spacing: Spacing.m) {
                    SocialAvatar(url: entry.pet.avatarURL, name: entry.pet.name)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(entry.pet.name)
                            .font(Typography.body.weight(.semibold))
                            .foregroundStyle(Palette.primaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(detail(entry))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: Layout.minTouchTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens \(entry.pet.name)'s page.")

            if let follow = model.followModels[entry.pet.id] {
                PetFollowButton(model: follow, compact: true)
            }
        }
        .padding(Spacing.m)
        .background(Palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
    }

    /// Breed or species, then what this person is to the pet.
    private func detail(_ entry: ProfilePet) -> String {
        let kind = entry.pet.breed.isEmpty ? PetDisplay.label(for: entry.pet.species) : entry.pet.breed
        let relationship = PetDisplay.label(for: entry.relationship, custom: entry.customRelationship)
        return "\(kind) · \(relationship)"
    }

    // MARK: - Blocked

    private var blocked: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("You have blocked this user")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.primaryText)
            Text("Unblock to view their profile and pets again.")
                .font(Typography.body)
                .foregroundStyle(Palette.secondaryText)
            Button { Task { await model.unblock() } } label: {
                HStack(spacing: Spacing.s) {
                    if model.isUnblocking { ProgressView() }
                    Text(model.isUnblocking ? "Unblocking…" : "Unblock")
                }
            }
            .buttonStyle(SocialButtonStyle(kind: .secondary))
            .disabled(model.isUnblocking)
            .accessibilityIdentifier("user.unblock")
            if let message = model.unblockMessage {
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.l)
        .background(Palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityIdentifier("user.blocked")
    }
}

#if DEBUG
#Preview("Someone else") {
    NavigationStack {
        UserProfileView(
            model: UserProfileModel(userID: "alice", viewerID: "me", social: PreviewSocialRepository()),
            onOpenPet: { _ in },
            onOpenFollowing: {}
        )
    }
}
#endif
