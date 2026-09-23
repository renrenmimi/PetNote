import SwiftUI

// One initialiser per screen, taking only what the shell already holds — ids,
// repositories and where to go next — so wiring a route is one line and cannot
// build the models subtly differently from one call site to the next.
//
// Every view keeps its model in `@State`, so a shell that re-evaluates and
// calls one of these again gets the model from the first appearance, not a
// fresh one that would reload. The models' own initialisers do no work, which
// is what makes the discarded copies free.

extension SearchView {
    /// Search and discovery. One `BlockList` is shared by both halves, so the
    /// viewer's blocks are read once for the screen.
    init(
        viewerID: String?,
        search: any SearchRepository,
        social: any SocialRepository,
        initialTag: String? = nil,
        onOpenPet: @escaping (String) -> Void,
        onOpenUser: @escaping (String) -> Void,
        onOpenPost: @escaping (String) -> Void
    ) {
        let blocks = BlockList(viewerID: viewerID, social: social)
        self.init(
            search: SearchModel(
                viewerID: viewerID, search: search, blockList: blocks, initialTag: initialTag
            ),
            explore: ExploreModel(
                viewerID: viewerID, search: search, social: social, blockList: blocks
            ),
            onOpenPet: onOpenPet,
            onOpenUser: onOpenUser,
            onOpenPost: onOpenPost
        )
    }
}

extension UserProfileView {
    init(
        userID: String,
        viewerID: String?,
        social: any SocialRepository,
        onOpenPet: @escaping (String) -> Void,
        onOpenFollowing: @escaping () -> Void,
        onUnblocked: @escaping () -> Void = {}
    ) {
        self.init(
            model: UserProfileModel(userID: userID, viewerID: viewerID, social: social),
            onOpenPet: onOpenPet,
            onOpenFollowing: onOpenFollowing,
            onUnblocked: onUnblocked
        )
    }
}

extension FamilyView {
    /// - Parameter onLeft: the viewer has left the family. The pet page behind
    ///   this screen was drawn for an owner and should be reloaded or left.
    init(
        petID: String,
        viewerID: String,
        viewerIsAdmin: Bool = false,
        pets: any PetRepository,
        family: any FamilyRepository,
        onOpenUser: @escaping (String) -> Void,
        onLeft: @escaping () -> Void
    ) {
        self.init(
            model: FamilyModel(
                petID: petID, viewerID: viewerID, viewerIsAdmin: viewerIsAdmin,
                pets: pets, family: family
            ),
            invite: InviteModel(petID: petID, repository: family),
            onOpenUser: onOpenUser,
            onLeft: onLeft
        )
    }
}

extension JoinFamilyView {
    init(viewerID: String, family: any FamilyRepository, onOpenPet: @escaping (String) -> Void) {
        self.init(model: JoinFamilyModel(viewerID: viewerID, repository: family), onOpenPet: onOpenPet)
    }
}

extension PetFollowersView {
    init(
        petID: String,
        petName: String,
        social: any SocialRepository,
        onOpenUser: @escaping (String) -> Void
    ) {
        self.init(
            model: PetFollowersModel(petID: petID, petName: petName, repository: social),
            onOpenUser: onOpenUser
        )
    }
}

extension FollowingPetsView {
    init(viewerID: String, social: any SocialRepository, onOpenPet: @escaping (String) -> Void) {
        self.init(
            model: FollowingPetsModel(viewerID: viewerID, repository: social),
            onOpenPet: onOpenPet
        )
    }
}
