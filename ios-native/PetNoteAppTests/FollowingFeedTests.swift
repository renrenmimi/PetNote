import Foundation
import Testing

@testable import PetNote

/// The feed's Following tab under the screen: which pets it asks about
/// (`FollowingFeed`), how the thirty-at-a-time answers are merged and paged
/// (`FollowingPage`), and what coming back to a tab does to its hearts
/// (`FeedViewModel.refreshLikes`).
@MainActor
struct FollowingFeedTests {
    // MARK: - Fakes

    /// Records what it is asked, and answers with the posts of the pets it was
    /// asked about, in the order they were asked.
    final class FakeFollowingPosts: FollowingPostsReading, @unchecked Sendable {
        private let lock = NSLock()
        private var storedAsks: [[String]] = []
        var byPet: [String: [Post]] = [:]

        var asks: [[String]] { lock.withLock { storedAsks } }

        func posts(ofPets petIDs: [String], after cursor: PageCursor?, limit: Int) async throws -> Page<Post> {
            lock.withLock { storedAsks.append(petIDs) }
            let posts = petIDs.flatMap { byPet[$0] ?? [] }
            return Page(items: Array(posts.prefix(limit)), next: posts.count > limit ? PageCursor() : nil)
        }
    }

    private static func followed(_ id: String) -> FollowedPet {
        FollowedPet(id: id, petName: id.capitalized, petAvatarURL: nil, followedAt: nil)
    }

    private static func post(_ id: String, pet: String? = "mochi", likeCount: Int = 0) -> Post {
        Post(
            id: id, authorID: "uid", authorName: "A", authorAvatarURL: nil,
            text: "TEST CONTENT \(id)", media: [], petID: pet, petName: pet?.capitalized,
            petAvatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            likeCount: likeCount, commentCount: 0, tags: []
        )
    }

    private func makeFeed(_ social: FakeSocialRepository, _ reader: FakeFollowingPosts) -> FollowingFeed {
        FollowingFeed(viewerID: "me", social: social, reader: reader, lookup: FeedViewModelTests.FakeFeed())
    }

    // MARK: - Which pets

    /// Following nobody is an empty list, and no post is read for it.
    @Test func followingNobodyReadsNoPosts() async throws {
        let reader = FakeFollowingPosts()
        let page = try await makeFeed(FakeSocialRepository(), reader).posts(after: nil, limit: 20)

        #expect(page.items.isEmpty)
        #expect(!page.hasMore)
        #expect(reader.asks.isEmpty, "posts were read for no pets")
    }

    /// The pets are read with the first page and kept for the next: a follow
    /// that lands in between does not change what page two is merged from.
    /// A new first page reads them again.
    @Test func theFollowedPetsAreReadOncePerFirstPage() async throws {
        let social = FakeSocialRepository()
        social.followedPetsList = [Self.followed("mochi"), Self.followed("biscuit")]
        let reader = FakeFollowingPosts()
        reader.byPet = ["mochi": (1...25).map { Self.post("m\($0)") }]
        let feed = makeFeed(social, reader)

        let first = try await feed.posts(after: nil, limit: 20)
        #expect(first.items.count == 20)
        social.followedPetsList.append(Self.followed("newcomer"))
        _ = try await feed.posts(after: first.next, limit: 20)
        #expect(reader.asks == [["mochi", "biscuit"], ["mochi", "biscuit"]])

        _ = try await feed.posts(after: nil, limit: 20)
        #expect(reader.asks.last == ["mochi", "biscuit", "newcomer"])
    }

    /// Not knowing whom this person follows is a failed read, not an empty
    /// list: the model shows the failure and its retry.
    @Test func followsThatCannotBeReadFailTheRead() async {
        let social = FakeSocialRepository()
        social.followedPetsError = SocialFixture.readFailure
        let feed = makeFeed(social, FakeFollowingPosts())

        await #expect(throws: (any Error).self) {
            _ = try await feed.posts(after: nil, limit: 20)
        }
    }

    // MARK: - The merge

    /// Thirty to a query, each pet once, and ids no query could be asked
    /// about are left out.
    @Test func petsAreAskedAboutThirtyAtATimeEachOnce() {
        let ids = (0..<65).map { "p\($0)" } + ["p3", "", "a/b"]
        let distinct = FollowingPage.distinct(ids)

        #expect(distinct.count == 65)
        #expect(distinct.first == "p0")
        #expect(FollowingPage.chunks(of: distinct).map(\.count) == [30, 30, 5])
    }

    /// Newest first to the nanosecond, the id breaking a tie in Firestore's
    /// byte order, each post once, and no more than a page.
    @Test func theMergeIsNewestFirstEachPostOnceAndOnePage() {
        func at(_ seconds: Int64, _ nanoseconds: Int32, _ id: String) -> FollowingPage.Candidate {
            FollowingPage.Candidate(
                post: Self.post(id),
                position: FollowingPage.Position(seconds: seconds, nanoseconds: nanoseconds, id: id)
            )
        }
        let merged = FollowingPage.merge([
            at(100, 0, "oldest"),
            at(200, 5, "newest"),
            at(200, 1, "same-second"),
            at(150, 0, "twice"), at(150, 0, "twice"),
            at(120, 0, "B"), at(120, 0, "a"),
        ], limit: 5)

        // "a" is 0x61 and "B" is 0x42: descending, "a" comes first.
        #expect(merged.map(\.position.id) == ["newest", "same-second", "twice", "a", "B"])
    }

    // MARK: - Coming back to a tab

    /// A like given in the other tab shows when this one comes back, and is
    /// counted: the count this list read was taken before it. The next real
    /// read has the count caught up, and the offset comes off.
    @Test func aLikeFromTheOtherTabShowsWhenThisOneComesBack() async {
        let feed = FeedViewModelTests.FakeFeed()
        feed.pages = [[Self.post("a", likeCount: 3)]]
        let likes = FeedViewModelTests.FakeLikes()
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 20, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()
        #expect(!model.isLiked(model.posts[0]))

        likes.alreadyLiked = ["a"]
        await model.refreshLikes()
        #expect(model.isLiked(model.posts[0]))
        #expect(model.displayLikeCount(for: model.posts[0]) == 4)

        feed.pages = [[Self.post("a", likeCount: 4)]]
        await model.reload()
        #expect(model.isLiked(model.posts[0]))
        #expect(model.displayLikeCount(for: model.posts[0]) == 4, "the like was counted twice")
    }

    /// This list's own like, not yet in the count it read, undone in the
    /// other tab: nothing is left over.
    @Test func thisListsOwnLikeUndoneElsewhereComesOutAtNothing() async {
        let feed = FeedViewModelTests.FakeFeed()
        feed.pages = [[Self.post("a", likeCount: 3)]]
        let likes = FeedViewModelTests.FakeLikes()
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 20, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()
        model.toggleLike(model.posts[0])
        await model.waitForPendingLikes()
        #expect(model.displayLikeCount(for: model.posts[0]) == 4)

        likes.alreadyLiked = []
        await model.refreshLikes()
        #expect(!model.isLiked(model.posts[0]))
        #expect(model.displayLikeCount(for: model.posts[0]) == 3)
    }

    /// Coming back reads the hearts and nothing else: no page, and an answer
    /// that changes nothing leaves every number as it was.
    @Test func comingBackReadsHeartsNotPosts() async {
        let feed = FeedViewModelTests.FakeFeed()
        feed.pages = [[Self.post("a", likeCount: 3), Self.post("b", likeCount: 1)]]
        let likes = FeedViewModelTests.FakeLikes()
        likes.alreadyLiked = ["b"]
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 20, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()
        let pagesRead = feed.cursorsRequested.count

        await model.refreshLikes()

        #expect(feed.cursorsRequested.count == pagesRead, "coming back read the posts again")
        #expect(likes.batchCalls.last == ["a", "b"])
        #expect(model.displayLikeCount(for: model.posts[0]) == 3)
        #expect(model.displayLikeCount(for: model.posts[1]) == 1)
        #expect(model.isLiked(model.posts[1]))
    }
}
