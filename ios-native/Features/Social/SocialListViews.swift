import SwiftUI

/// Who follows a pet. Each row opens that person's profile.
struct PetFollowersView: View {
    @State private var model: PetFollowersModel
    var onOpenUser: (String) -> Void

    init(model: PetFollowersModel, onOpenUser: @escaping (String) -> Void) {
        _model = State(initialValue: model)
        self.onOpenUser = onOpenUser
    }

    var body: some View {
        List {
            switch model.state {
            case .loading where model.followers.isEmpty:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("followers.loading")
            case .failed(let message) where model.followers.isEmpty:
                SocialRetryNotice(message: message, identifier: "followers.failed") {
                    await model.load()
                }
                .listRowSeparator(.hidden)
            case .loaded where model.followers.isEmpty:
                SocialNotice(
                    title: "No followers yet.",
                    detail: "People who follow \(model.petName) show up here.",
                    identifier: "followers.empty"
                )
                .listRowSeparator(.hidden)
            default:
                if case .failed(let message) = model.state {
                    // A refresh failed over rows already on screen.
                    Text(message)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.danger)
                        .accessibilityIdentifier("followers.refreshFailed")
                }
                ForEach(model.followers) { follower in
                    PersonRow(
                        name: follower.userName,
                        avatarURL: follower.userAvatarURL,
                        detail: nil
                    ) { onOpenUser(follower.id) }
                    .task { await model.loadMoreIfNeeded(after: follower) }
                }
                if let failure = model.pageFailure {
                    SocialRetryNotice(message: failure, identifier: "followers.pageFailed") {
                        await model.retryMore()
                    }
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Followers")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.followers.isEmpty { await model.load() } }
        .refreshable { await model.load() }
    }
}

/// The pets the signed-in person follows. Each row opens the pet's page.
struct FollowingPetsView: View {
    @State private var model: FollowingPetsModel
    var onOpenPet: (String) -> Void

    init(model: FollowingPetsModel, onOpenPet: @escaping (String) -> Void) {
        _model = State(initialValue: model)
        self.onOpenPet = onOpenPet
    }

    var body: some View {
        List {
            switch model.state {
            case .loading where model.pets.isEmpty:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("following.loading")
            case .failed(let message) where model.pets.isEmpty:
                SocialRetryNotice(message: message, identifier: "following.failed") {
                    await model.load()
                }
                .listRowSeparator(.hidden)
            case .loaded where model.pets.isEmpty:
                SocialNotice(
                    title: "No followed pets yet.",
                    detail: "Pets you follow show up here.",
                    identifier: "following.empty"
                )
                .listRowSeparator(.hidden)
            default:
                ForEach(model.pets) { pet in
                    PersonRow(name: pet.petName, avatarURL: pet.petAvatarURL, detail: nil) {
                        onOpenPet(pet.id)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Following")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.pets.isEmpty { await model.load() } }
        .refreshable { await model.load() }
    }
}

/// One tappable row: picture, name, an optional line under it.
///
/// A single button, so VoiceOver reads the whole row as one thing that opens
/// somewhere, and the hit region is the full row rather than the text.
struct PersonRow: View {
    let name: String
    let avatarURL: URL?
    let detail: String?
    var trailing: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                SocialAvatar(url: avatarURL, name: name)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(name)
                        .font(Typography.body.weight(.semibold))
                        .foregroundStyle(Palette.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let trailing {
                    Text(trailing)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize()
                }
            }
            .frame(minHeight: Layout.minTouchTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

#if DEBUG
#Preview("Followers") {
    NavigationStack {
        PetFollowersView(
            model: PetFollowersModel(
                petID: "pet-1", petName: "Mochi", repository: PreviewSocialRepository()
            ),
            onOpenUser: { _ in }
        )
    }
}

#Preview("Following") {
    NavigationStack {
        FollowingPetsView(
            model: FollowingPetsModel(viewerID: "me", repository: PreviewSocialRepository()),
            onOpenPet: { _ in }
        )
    }
}
#endif
