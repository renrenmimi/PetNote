import Foundation
import Testing

@testable import PetNote

/// Somebody's profile: who they are, their pets, a follow control on each —
/// and nothing of theirs while they are blocked.
@MainActor
struct UserProfileModelTests {
    private func repository() -> FakeSocialRepository {
        let repository = FakeSocialRepository()
        repository.profiles = ["alice": SocialFixture.profile("alice", following: 4)]
        repository.petsByUser = [
            "alice": [
                SocialFixture.profilePet(SocialFixture.pet("p1"), role: .primary),
                SocialFixture.profilePet(SocialFixture.pet("p2", ownerID: "bob")),
            ],
        ]
        return repository
    }

    @Test func showsTheProfileAndTheirPetsWithFollowControls() async {
        let social = repository()
        social.following = ["p2"]
        let model = UserProfileModel(userID: "alice", viewerID: "me", social: social)

        await model.load()

        #expect(model.profile?.id == "alice")
        #expect(model.pets.map(\.id) == ["p1", "p2"])
        #expect(model.petCountText == "2")
        #expect(model.followingCount == 4)
        #expect(model.followModels["p1"]?.status == .notFollowing)
        #expect(model.followModels["p2"]?.status == .following)
    }

    /// Co-owned with the viewer: the server would refuse the follow.
    @Test func aPetTheViewerAlsoOwnsHasNoFollowControl() async {
        let social = repository()
        social.familyMemberships = ["p2"]
        let model = UserProfileModel(userID: "alice", viewerID: "me", social: social)

        await model.load()

        #expect(model.followModels["p2"]?.offersControl == false)
        #expect(model.followModels["p1"]?.offersControl == true)
    }

    @Test func onTheirOwnProfileNoPetHasAFollowControl() async {
        let social = repository()
        let model = UserProfileModel(userID: "alice", viewerID: "alice", social: social)

        await model.load()

        #expect(model.isSelf)
        #expect(model.followModels.values.allSatisfy { !$0.offersControl })
        #expect(social.batchReads.isEmpty)
        #expect(social.blockedReads == 0, "nobody can have blocked themself")
    }

    @Test func aBlockedPersonsProfileIsNotShown() async {
        let social = repository()
        social.blocked = ["alice"]
        let model = UserProfileModel(userID: "alice", viewerID: "me", social: social)

        await model.load()

        #expect(model.state == .blocked)
        #expect(social.profileReads == 0)
        #expect(model.pets.isEmpty)
    }

    @Test func unblockingShowsTheProfileAgain() async {
        let social = repository()
        social.blocked = ["alice"]
        let model = UserProfileModel(userID: "alice", viewerID: "me", social: social)
        await model.load()

        await model.unblock()

        #expect(social.unblocked == ["alice"])
        #expect(model.profile?.id == "alice")
        #expect(model.pets.count == 2)
    }

    @Test func aFailedUnblockSaysSoAndStaysBlocked() async {
        let social = repository()
        social.blocked = ["alice"]
        social.unblockError = SocialError.denied
        let model = UserProfileModel(userID: "alice", viewerID: "me", social: social)
        await model.load()

        await model.unblock()

        #expect(model.state == .blocked)
        #expect(model.unblockMessage == "Could not unblock this person. Try again.")
    }

    /// Not knowing whether they are blocked is not the same as their being
    /// blocked; the profile is public.
    @Test func aFailedBlockReadStillShowsTheProfile() async {
        let social = repository()
        social.blockedError = SocialFixture.readFailure
        let model = UserProfileModel(userID: "alice", viewerID: "me", social: social)

        await model.load()

        #expect(model.profile?.id == "alice")
    }

    @Test func aMissingAccountIsNotAFailedRead() async {
        let social = repository()
        let model = UserProfileModel(userID: "ghost", viewerID: "me", social: social)

        await model.load()

        #expect(model.state == .missing)
    }

    @Test func aRefusedReadIsNotAFailedOne() async {
        let social = repository()
        social.profileError = SocialError.denied
        let denied = UserProfileModel(userID: "alice", viewerID: "me", social: social)
        await denied.load()
        #expect(denied.state == .denied)

        social.profileError = SocialError.offline
        let offline = UserProfileModel(userID: "alice", viewerID: "me", social: social)
        await offline.load()
        #expect(offline.state == .failed("No connection. Check your network and try again."))
    }

    /// The web page loads both together, so a failed pet read turned a
    /// readable profile into "Could not load this profile".
    @Test func failedPetsLeaveTheProfileStandingWithTheirOwnRetry() async {
        let social = repository()
        social.petsError = SocialFixture.readFailure
        let model = UserProfileModel(userID: "alice", viewerID: "me", social: social)

        await model.load()

        #expect(model.profile?.id == "alice")
        #expect(model.petsState == .failed("Could not load their pets."))
        #expect(model.petCountText == "—", "a failed read must not show as zero pets")

        social.petsError = nil
        await model.retryPets()
        #expect(model.petsState == .loaded)
        #expect(model.pets.count == 2)
    }

    @Test func theHeaderFallsBackWhereTheProfileIsSilent() async {
        let social = repository()
        social.profiles["quiet"] = PublicProfile(
            id: "quiet", displayName: "", avatarURL: nil, bio: "", city: "Boston", state: "",
            followingPetsCount: nil, createdAt: nil
        )
        let model = UserProfileModel(userID: "quiet", viewerID: "me", social: social)

        await model.load()

        #expect(model.displayName == "PetNote User")
        #expect(model.locationLine == "Boston")
        #expect(model.joinedLine == "Joined: unknown")
        #expect(model.followingCount == 0)
    }
}
