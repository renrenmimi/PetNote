import Foundation
import Testing

@testable import PetNote

/// Who follows a pet, and which pets I follow.
@MainActor
struct SocialListsTests {
    @Test func followersLoadNewestFirstAndPageOnReachingTheEnd() async {
        let repository = FakeSocialRepository()
        repository.followerPages = [
            [SocialFixture.follower("a"), SocialFixture.follower("b")],
            [SocialFixture.follower("c")],
        ]
        let model = PetFollowersModel(petID: "pet-1", petName: "Mochi", repository: repository, pageSize: 2)

        await model.load()
        #expect(model.followers.map(\.id) == ["a", "b"])
        #expect(model.hasMore)

        // Reaching a row that is not the last asks for nothing.
        await model.loadMoreIfNeeded(after: model.followers[0])
        #expect(repository.followerCursors.count == 1)

        await model.loadMoreIfNeeded(after: model.followers[1])
        #expect(model.followers.map(\.id) == ["a", "b", "c"])
        #expect(!model.hasMore)
    }

    @Test func somebodyOnTwoPagesIsShownOnce() async {
        let repository = FakeSocialRepository()
        repository.followerPages = [
            [SocialFixture.follower("a"), SocialFixture.follower("b")],
            [SocialFixture.follower("b"), SocialFixture.follower("c")],
        ]
        let model = PetFollowersModel(petID: "pet-1", petName: "Mochi", repository: repository, pageSize: 2)

        await model.load()
        await model.loadMoreIfNeeded(after: model.followers[1])

        #expect(model.followers.map(\.id) == ["a", "b", "c"])
    }

    /// "Nobody follows this pet" and "we could not find out" are different
    /// sentences.
    @Test func aFailedReadIsNotAnEmptyList() async {
        let repository = FakeSocialRepository()
        repository.followersError = SocialFixture.readFailure
        let model = PetFollowersModel(petID: "pet-1", petName: "Mochi", repository: repository)

        await model.load()

        #expect(model.state == .failed("Could not load this pet's followers."))
        #expect(model.followers.isEmpty)

        repository.followersError = nil
        repository.followerPages = [[SocialFixture.follower("a")]]
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.followers.map(\.id) == ["a"])
    }

    @Test func aFailedLaterPageKeepsTheRowsAlreadyShown() async {
        let repository = FakeSocialRepository()
        repository.followerPages = [
            [SocialFixture.follower("a"), SocialFixture.follower("b")],
            [SocialFixture.follower("c")],
        ]
        let model = PetFollowersModel(petID: "pet-1", petName: "Mochi", repository: repository, pageSize: 2)
        await model.load()

        repository.followersError = SocialFixture.readFailure
        repository.followersErrorOnPage = 1
        await model.loadMoreIfNeeded(after: model.followers[1])

        #expect(model.followers.map(\.id) == ["a", "b"])
        #expect(model.pageFailure == "Could not load more followers.")
        #expect(model.state == .loaded)

        repository.followersError = nil
        await model.retryMore()
        #expect(model.followers.map(\.id) == ["a", "b", "c"])
        #expect(model.pageFailure == nil)
    }

    @Test func thePetsIFollowAreListed() async {
        let repository = FakeSocialRepository()
        repository.followedPetsList = [
            FollowedPet(id: "p1", petName: "Mochi", petAvatarURL: nil, followedAt: SocialFixture.date),
        ]
        let model = FollowingPetsModel(viewerID: "me", repository: repository)

        await model.load()

        #expect(model.state == .loaded)
        #expect(model.pets.map(\.id) == ["p1"])
    }

    @Test func aFailedFollowingReadSaysSo() async {
        let repository = FakeSocialRepository()
        repository.followedPetsError = SocialError.offline
        let model = FollowingPetsModel(viewerID: "me", repository: repository)

        await model.load()

        #expect(model.state == .failed("No connection. Check your network and try again."))
    }
}
