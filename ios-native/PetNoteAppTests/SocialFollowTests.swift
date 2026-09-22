import Foundation
import Testing

@testable import PetNote

/// Following a pet, as a person does it: see whether you follow it, tap once,
/// and have the screen agree with the server — including when the answer is
/// lost, and including when you are one of its owners.
@MainActor
struct SocialFollowTests {
    private func model(
        _ repository: FakeSocialRepository,
        viewerID: String? = "me",
        owners: [String] = ["alice"],
        initial: FollowModel.Status = .unknown
    ) -> FollowModel {
        FollowModel(
            petID: "pet-1", petName: "Mochi", viewerID: viewerID, repository: repository,
            knownOwnerIDs: owners, initial: initial
        )
    }

    // MARK: - Status

    @Test func readsWhetherTheViewerFollowsThePet() async {
        let repository = FakeSocialRepository()
        repository.following = ["pet-1"]
        let follow = model(repository)

        await follow.load()

        #expect(follow.status == .following)
        #expect(follow.offersControl)
    }

    /// The callable refuses a follow from anyone in the family, so the control
    /// is not offered — the web page shows owners their management actions
    /// in its place.
    @Test func aFamilyMemberIsOfferedNoFollowControl() async {
        let repository = FakeSocialRepository()
        repository.familyMemberships = ["pet-1"]
        let follow = model(repository)

        await follow.load()

        #expect(follow.status == .ownPet)
        #expect(!follow.offersControl)
    }

    /// `followPetCallable` also refuses whoever `ownerId`/`primaryOwnerId`
    /// names, family document or not. Known from the pet document, so no read
    /// is needed to withhold the button.
    @Test func theNamedOwnerIsRecognisedWithoutAnyRead() async {
        let repository = FakeSocialRepository()
        let follow = model(repository, viewerID: "alice", owners: ["alice"])

        await follow.load()

        #expect(follow.status == .ownPet)
        #expect(repository.isFollowingReads == 0)
    }

    @Test func aFailedStatusReadStillOffersASafeFollow() async {
        let repository = FakeSocialRepository()
        repository.isFollowingError = SocialFixture.readFailure
        let follow = model(repository)

        await follow.load()

        #expect(follow.status == .checkFailed)
        #expect(follow.offersControl)
    }

    // MARK: - Toggling

    @Test func followingGoesThroughTheCallableAndMovesTheCount() async {
        let repository = FakeSocialRepository()
        let follow = model(repository, initial: .notFollowing)

        await follow.toggle()

        #expect(repository.followCalls == ["pet-1"])
        #expect(follow.status == .following)
        #expect(follow.displayedFollowerCount(base: 3) == 4)
    }

    @Test func unfollowingGoesThroughTheCallableAndMovesTheCountBack() async {
        let repository = FakeSocialRepository()
        repository.following = ["pet-1"]
        let follow = model(repository, initial: .following)

        await follow.toggle()

        #expect(repository.unfollowCalls == ["pet-1"])
        #expect(repository.followCalls.isEmpty)
        #expect(follow.status == .notFollowing)
        #expect(follow.displayedFollowerCount(base: 3) == 2)
    }

    /// Not optimistic: until the server has answered, the button does not
    /// claim a follow that has not happened. And a second tap in that window
    /// sends nothing.
    ///
    /// The watchdog is what lets this test *fail*. With the in-flight guard
    /// removed, the second tap goes to the repository and waits on the same
    /// closed gate, and the `gate.open()` below it is never reached: the
    /// test hung instead of failing, and took a whole test run with it. The
    /// watchdog opens the gate after two seconds, so a second call gets
    /// through, is counted, and the count below catches it.
    @Test(.timeLimit(.minutes(1)))
    func aSecondTapWhileTheFirstIsInFlightSendsNothing() async {
        let repository = FakeSocialRepository()
        let gate = SocialGate()
        repository.followGate = gate
        let follow = model(repository, initial: .notFollowing)

        let first = Task { await follow.toggle() }
        await socialEventually { repository.followCalls.count == 1 }
        #expect(follow.isBusy)
        #expect(follow.status == .notFollowing, "the button claimed a follow the server had not confirmed")

        let watchdog = Task { try? await Task.sleep(for: .seconds(2)); gate.open() }
        await follow.toggle()
        gate.open()
        watchdog.cancel()
        await first.value

        #expect(repository.followCalls.count == 1)
        #expect(follow.status == .following)
        #expect(!follow.isBusy)
    }

    @Test func theServersOwnPetRefusalRemovesTheControl() async {
        let repository = FakeSocialRepository()
        repository.followError = SocialError.ownPet
        let follow = model(repository, initial: .notFollowing)

        await follow.toggle()

        #expect(follow.status == .ownPet)
        #expect(!follow.offersControl)
        #expect(follow.message == FollowModel.wording(for: .ownPet))
        #expect(follow.displayedFollowerCount(base: 3) == 3)
    }

    @Test func aRefusalLeavesTheStateAsItWasAndSaysWhy() async {
        let repository = FakeSocialRepository()
        repository.followError = SocialError.rateLimited
        let follow = model(repository, initial: .notFollowing)

        await follow.toggle()

        #expect(follow.status == .notFollowing)
        #expect(follow.message == "Too many requests just now. Wait a moment and try again.")
        #expect(follow.displayedFollowerCount(base: 3) == 3)
    }

    /// The call went out and the answer was lost — but the follow did land.
    /// The follow document says so, and the screen believes it.
    @Test func aLostAnswerIsSettledByReadingTheFollowDocument() async {
        let repository = FakeSocialRepository()
        repository.followError = SocialError.outcomeUnknown
        repository.following = ["pet-1"]
        let follow = model(repository, initial: .notFollowing)

        await follow.toggle()

        #expect(repository.followCalls.count == 1, "an unknown outcome must not be resent")
        #expect(repository.isFollowingReads == 1)
        #expect(follow.status == .following)
        #expect(follow.message == nil)
        #expect(follow.displayedFollowerCount(base: 3) == 4)
    }

    @Test func aLostAnswerThatDidNotLandSaysSo() async {
        let repository = FakeSocialRepository()
        repository.followError = SocialError.outcomeUnknown
        let follow = model(repository, initial: .notFollowing)

        await follow.toggle()

        #expect(follow.status == .notFollowing)
        #expect(follow.message == "Could not follow Mochi. Try again.")
        #expect(follow.displayedFollowerCount(base: 3) == 3)
    }

    @Test func aLostAnswerThatCannotBeCheckedClaimsNothing() async {
        let repository = FakeSocialRepository()
        repository.followError = SocialError.outcomeUnknown
        repository.isFollowingError = SocialFixture.readFailure
        let follow = model(repository, initial: .notFollowing)

        await follow.toggle()

        #expect(follow.status == .notFollowing)
        #expect(follow.message == "We could not tell whether that went through. Reload to check.")
    }

    /// From an unknown status the server may have had nothing to do, so the
    /// count is not moved on the strength of a guess.
    @Test func followingFromAnUnknownStatusDoesNotMoveTheCount() async {
        let repository = FakeSocialRepository()
        let follow = model(repository, initial: .checkFailed)

        await follow.toggle()

        #expect(follow.status == .following)
        #expect(follow.displayedFollowerCount(base: 3) == 3)
    }

    @Test func theCountNeverShowsBelowZero() async {
        let repository = FakeSocialRepository()
        let follow = model(repository, initial: .following)

        await follow.toggle()

        #expect(follow.displayedFollowerCount(base: 0) == 0)
    }

    @Test func aSignedOutViewerIsOfferedNothingAndSendsNothing() async {
        let repository = FakeSocialRepository()
        let follow = model(repository, viewerID: nil, initial: .notFollowing)

        await follow.toggle()

        #expect(!follow.offersControl)
        #expect(repository.followCalls.isEmpty)
    }

    // MARK: - Batches

    @Test func aBatchedStatusReadResolvesEachPet() {
        let mine = SocialFixture.pet("p-mine", ownerID: "me")
        let family = SocialFixture.pet("p-family")
        let followed = SocialFixture.pet("p-followed")
        let other = SocialFixture.pet("p-other")

        func status(_ pet: Pet, followed ids: Set<String>?) -> FollowModel.Status {
            FollowModel.status(
                for: pet, viewerID: "me", memberPetIDs: ["p-family"], followedPetIDs: ids
            )
        }

        #expect(status(mine, followed: []) == .ownPet)
        #expect(status(family, followed: []) == .ownPet)
        #expect(status(followed, followed: ["p-followed"]) == .following)
        #expect(status(other, followed: ["p-followed"]) == .notFollowing)
        #expect(status(other, followed: nil) == .checkFailed)
    }

    @Test func oneBatchedReadServesAWholeList() async {
        let repository = FakeSocialRepository()
        repository.following = ["p2"]
        repository.familyMemberships = ["p3"]
        let pets = ["p1", "p2", "p3"].map { SocialFixture.pet($0) }

        let models = await FollowModel.models(for: pets, viewerID: "me", repository: repository)

        #expect(repository.batchReads == [["p1", "p2", "p3"]])
        #expect(repository.memberIDReads == 1)
        #expect(models["p1"]?.status == .notFollowing)
        #expect(models["p2"]?.status == .following)
        #expect(models["p3"]?.status == .ownPet)
    }

    @Test func onTheirOwnProfileEveryPetIsTheViewersAndNothingIsRead() async {
        let repository = FakeSocialRepository()
        let pets = ["p1", "p2"].map { SocialFixture.pet($0) }

        let models = await FollowModel.models(
            for: pets, viewerID: "me", repository: repository, viewerOwnsAll: true
        )

        #expect(repository.batchReads.isEmpty)
        #expect(repository.memberIDReads == 0)
        #expect(models.values.allSatisfy { $0.status == .ownPet })
    }
}
