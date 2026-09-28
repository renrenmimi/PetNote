import Foundation
import Testing

@testable import PetNote

/// The pet page as a journey: does it load, does one broken part take the rest
/// down, and can the right person — and only the right person — delete the
/// pet.
@MainActor
struct PetProfileViewModelTests {
    private func model(
        repository: FakePetRepository,
        viewerID: String? = "alice",
        isAdmin: Bool = false,
        postPageSize: Int = 20
    ) -> PetProfileViewModel {
        PetProfileViewModel(
            petID: "pet-1", repository: repository, viewerID: viewerID,
            viewerIsAdmin: isAdmin, postPageSize: postPageSize
        )
    }

    private func loadedRepository() -> FakePetRepository {
        let repository = FakePetRepository()
        repository.pet = PetFixture.pet()
        repository.family = [PetFixture.member("alice", role: .primary)]
        repository.postPages = [[PetFixture.post("p1"), PetFixture.post("p2")]]
        repository.checkins = [PetFixture.checkin("c1")]
        return repository
    }

    // MARK: - Loading

    @Test func loadsThePetItsOwnersItsPostsAndItsCheckins() async {
        let repository = loadedRepository()
        let model = model(repository: repository)

        await model.load()

        #expect(model.state == .loaded(PetFixture.pet()))
        #expect(model.family.map(\.id) == ["alice"])
        #expect(model.posts.map(\.id) == ["p1", "p2"])
        #expect(model.checkins.map(\.id) == ["c1"])
        #expect(model.checkinsState == .loaded)
    }

    /// "Read successfully, and there is no such pet" and "we could not reach
    /// PetNote" are different sentences, and only one of them is worth a retry
    /// button.
    @Test func aMissingPetIsNotTheSameAsAFailedRead() async {
        let gone = FakePetRepository()
        gone.pet = nil
        let goneModel = model(repository: gone)
        await goneModel.load()
        #expect(goneModel.state == .missing)

        let broken = FakePetRepository()
        broken.petError = PetFixture.readFailure
        let brokenModel = model(repository: broken)
        await brokenModel.load()
        #expect(brokenModel.state == .failed("Could not load this pet."))
    }

    /// Check-ins go through a callable, so they fail for reasons the rest of
    /// the page does not share — a cold function, an unavailable one, or one
    /// that is simply not deployed locally. With all four reads sharing a
    /// failure path, a pet whose name, photos, owners and posts were every one
    /// of them readable rendered as "Could not load this pet".
    @Test func aFailedCheckinReadLeavesTheRestOfThePageIntact() async {
        let repository = loadedRepository()
        repository.checkinsError = PetFixture.readFailure
        let model = model(repository: repository)

        await model.load()

        #expect(model.state == .loaded(PetFixture.pet()))
        #expect(model.posts.map(\.id) == ["p1", "p2"])
        #expect(model.checkinsState == .failed("Could not load check-ins."))
    }

    @Test func aFailedPostReadLeavesTheRestOfThePageIntact() async {
        let repository = loadedRepository()
        repository.postsError = PetFixture.readFailure
        let model = model(repository: repository)

        await model.load()

        #expect(model.state == .loaded(PetFixture.pet()))
        #expect(model.postsState == .failed("Could not load this pet's posts."))
        #expect(model.checkinsState == .loaded)
    }

    @Test func retryingASectionAsksAgainAndCanSucceed() async {
        let repository = loadedRepository()
        repository.checkinsError = PetFixture.readFailure
        let model = model(repository: repository)
        await model.load()
        #expect(model.checkinsState == .failed("Could not load check-ins."))

        repository.checkinsError = nil
        await model.retryCheckins()

        #expect(model.checkinsState == .loaded)
        #expect(model.checkins.map(\.id) == ["c1"])
    }

    // MARK: - Ownership on screen

    @Test func aCoOwnerIsOfferedEditButNotDelete() async {
        let repository = loadedRepository()
        repository.family = [
            PetFixture.member("alice", role: .primary),
            PetFixture.member("bob"),
        ]
        let model = model(repository: repository, viewerID: "bob")

        await model.load()

        #expect(model.permissions.canEdit)
        #expect(!model.permissions.canDelete)
    }

    /// The trap this test exists for: a failed family read hands back an empty
    /// array, and an empty array is exactly what `PetOwnership`'s legacy
    /// fallback treats as "there is no family, so trust `ownerId`". Run
    /// through unguarded, a viewer whose uid happens to sit in `ownerId` would
    /// be offered a Delete button on the strength of a read that did not
    /// happen — the same shape as `!exists()` also meaning "deleted" in the
    /// Firestore rules this project has already been bitten by.
    @Test func aFailedFamilyReadOffersNoDestructiveControlEvenToTheNamedOwner() async {
        let repository = loadedRepository()
        repository.pet = PetFixture.pet(ownerID: "alice", primaryOwnerID: "alice")
        repository.familyError = PetFixture.readFailure
        let model = model(repository: repository, viewerID: "alice")

        await model.load()

        #expect(model.ownership == nil, "ownership must stay undetermined, not default to nobody")
        #expect(!model.permissions.canDelete, """
            A destructive control was offered because a read failed. The \
            empty array a failure hands back is not an empty family.
            """)
        #expect(!model.permissions.canEdit)
        #expect(model.familyState == .failed("Could not load this pet's owners."))
        // The pet itself still rendered: a permission that cannot be
        // established is not a page that cannot be shown.
        #expect(model.state == .loaded(PetFixture.pet(ownerID: "alice", primaryOwnerID: "alice")))
    }

    @Test func anAdminIsOfferedDeleteOnAPetWithOtherOwners() async {
        let repository = loadedRepository()
        repository.family = [
            PetFixture.member("alice", role: .primary),
            PetFixture.member("bob"),
        ]
        let model = model(repository: repository, viewerID: "moderator", isAdmin: true)

        await model.load()

        #expect(model.permissions.canDelete)
    }

    // MARK: - Deleting

    @Test func deletingAPetYouAreTheLastOwnerOfSucceeds() async {
        let repository = loadedRepository()
        let model = model(repository: repository)
        await model.load()

        model.askToDelete()
        #expect(model.deleteState == .confirming)
        await model.confirmDelete()

        #expect(repository.deleted == ["pet-1"])
        #expect(model.deleteState == .deleted)
    }

    /// The server refuses with `failed-precondition` and the client has to say
    /// what can be done instead — which today is "ask the other owners to
    /// leave", because leaving is batch 3 and there is no control for it yet.
    ///
    /// The situation is real rather than contrived: the viewer read the family
    /// and was the only owner in it, and somebody redeemed an invitation
    /// before the delete landed. The server's transaction sees the new member
    /// and refuses — which is exactly the window its own source comment says
    /// the transaction exists to close. The client cannot prevent it; it has
    /// to report it.
    @Test func deletingAPetSomebodyJoinedInTheMeantimeIsRefusedWithSomethingToDoInstead() async {
        let repository = loadedRepository()
        repository.deleteResult = .failure(PetError.petHasOtherOwners)
        let model = model(repository: repository, viewerID: "alice")
        await model.load()
        #expect(model.permissions.canDelete, "the viewer read the family and was its only owner")

        await model.confirmDelete()

        guard case .failed(let message) = model.deleteState else {
            Issue.record("expected the delete to fail, got \(model.deleteState)")
            return
        }
        #expect(message.contains("other owners"))
        #expect(message.contains("leave"), "the refusal has to name the way out, not just refuse")
    }

    @Test func aRefusedDeleteSaysTheCallerIsNotOneOfTheOwners() async {
        let repository = loadedRepository()
        repository.deleteResult = .failure(PetError.notAnOwner)
        let model = model(repository: repository)
        await model.load()

        await model.confirmDelete()

        #expect(model.deleteState == .failed("You are not one of this pet's owners."))
    }

    /// The UI hides the control; this is the other half. A view model that
    /// sends the call anyway would be relying on the server for something it
    /// already knows.
    @Test func confirmingADeleteWithoutThePermissionNeverReachesTheServer() async {
        let repository = loadedRepository()
        repository.family = [
            PetFixture.member("alice", role: .primary),
            PetFixture.member("bob"),
        ]
        let model = model(repository: repository, viewerID: "bob")
        await model.load()

        model.askToDelete()
        #expect(model.deleteState == .idle, "askToDelete must not open a dialog it cannot honour")
        await model.confirmDelete()

        #expect(repository.deleted.isEmpty)
        #expect(model.deleteState == .failed("You are not one of this pet's owners."))
    }

    /// The pet document is removed in a transaction and its subcollections are
    /// cleaned up afterwards, outside it. When that cleanup is interrupted the
    /// server keeps a record so a retry can finish it, and answers
    /// `resumed: true`. That is still a success here.
    @Test func aDeleteThatResumesAnUnfinishedCleanupStillCounts() async {
        let repository = loadedRepository()
        repository.deleteResult = .success(PetDeletion(resumed: true))
        let model = model(repository: repository)
        await model.load()

        await model.confirmDelete()

        #expect(model.deleteState == .deleted)
    }

    /// The surprising half of deleting a pet is what survives: `onPetDeleted`
    /// strips `petId` / `petName` / `petAvatarUrl` from the posts but does not
    /// delete them. Somebody told only "this cannot be undone" would
    /// reasonably expect their photos to go too.
    @Test func theDeleteConfirmationSaysWhatHappensToThePosts() {
        let words = PetProfileViewModel.deletionConsequences

        #expect(words.contains("Posts are not deleted"))
        #expect(words.contains("owners"))
        #expect(words.contains("followers"))
    }

    // MARK: - Paging

    @Test func doesNotFetchTheSamePostCursorTwice() async {
        let repository = FakePetRepository()
        repository.pet = PetFixture.pet()
        repository.family = [PetFixture.member("alice", role: .primary)]
        repository.postPages = [[PetFixture.post("p1")], [PetFixture.post("p2")]]
        let model = model(repository: repository, postPageSize: 1)
        await model.load()

        // The same row triggers repeatedly, which is what a flung list does.
        let trigger = model.posts.last
        await model.loadMorePostsIfNeeded(currentItem: trigger)
        await model.loadMorePostsIfNeeded(currentItem: trigger)
        await model.loadMorePostsIfNeeded(currentItem: trigger)

        #expect(repository.postCursors.count == 2, "asked \(repository.postCursors.count) times")
        #expect(model.posts.map(\.id) == ["p1", "p2"])
    }
}
