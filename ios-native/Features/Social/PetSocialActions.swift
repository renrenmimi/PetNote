import SwiftUI

/// The social row for a pet's page: its follower count, and either the follow
/// control or — for one of its owners — the way into managing the family.
///
/// Built to be dropped into `PetProfileView` in one line; that file belongs to
/// the pets batch, so mounting it is the coordinator's call. It mirrors the web
/// header, where an owner sees management actions and everybody else sees
/// Follow, and the follower count opens the list of followers for anyone.
struct PetSocialActions: View {
    @State private var follow: FollowModel
    private let baseFollowerCount: Int
    private let ownership: PetOwnership?
    private let onOpenFollowers: () -> Void
    private let onOpenFamily: () -> Void

    /// - Parameter ownership: `PetProfileViewModel.ownership`. Nil while the
    ///   family read is outstanding or after it failed; the follow control then
    ///   decides for itself by reading the viewer's family document.
    init(
        pet: Pet,
        viewerID: String?,
        ownership: PetOwnership?,
        repository: any SocialRepository,
        onOpenFollowers: @escaping () -> Void,
        onOpenFamily: @escaping () -> Void
    ) {
        _follow = State(initialValue: FollowModel(
            petID: pet.id,
            petName: pet.name,
            viewerID: viewerID,
            repository: repository,
            knownOwnerIDs: [pet.ownerID, pet.primaryOwnerID],
            initial: ownership?.isMember == true ? .ownPet : .unknown
        ))
        baseFollowerCount = pet.followerCount
        self.ownership = ownership
        self.onOpenFollowers = onOpenFollowers
        self.onOpenFamily = onOpenFamily
    }

    var body: some View {
        SocialAdaptiveStack {
            Button(action: onOpenFollowers) {
                Text(PetDisplay.followerCount(follow.displayedFollowerCount(base: baseFollowerCount)))
                    .lineLimit(1)
            }
            .buttonStyle(SocialButtonStyle(kind: .secondary))
            .accessibilityHint("Shows who follows \(follow.petName).")
            .accessibilityIdentifier("pet.followers")

            if ownership?.isMember == true || follow.status == .ownPet {
                Button(action: onOpenFamily) {
                    Text("Owners & invites").lineLimit(1)
                }
                .buttonStyle(SocialButtonStyle(kind: .primary))
                .accessibilityIdentifier("pet.family")
            } else {
                PetFollowButton(model: follow, compact: true)
            }
        }
    }
}
