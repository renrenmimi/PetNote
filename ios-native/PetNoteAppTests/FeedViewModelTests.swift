import Foundation
import Testing

@testable import PetNote

/// Acceptance 5A.3, 5A.8, 5A.9, 5A.10 at the unit level, against fakes.
///
/// These are the behaviours that are expensive to provoke through the UI —
/// a duplicated page request, a like on a post that has just been deleted, a
/// timeout mid-write — and cheap to assert here.
@MainActor
struct FeedViewModelTests {
    // MARK: - Fakes

    final class FakeFeed: FeedRepository, @unchecked Sendable {
        var pages: [[Post]] = []
        var cursorsRequested: [PageCursor?] = []
        var error: Error?
        private var issued: [PageCursor] = []

        func posts(after cursor: PageCursor?, limit: Int) async throws -> Page<Post> {
            cursorsRequested.append(cursor)
            if let error { throw error }
            let index: Int
            if let cursor, let position = issued.firstIndex(of: cursor) {
                index = position + 1
            } else {
                index = 0
            }
            guard index < pages.count else { return .empty }
            let items = pages[index]
            let hasNext = index + 1 < pages.count
            var next: PageCursor?
            if hasNext {
                let token = PageCursor()
                issued.append(token)
                next = token
            }
            return Page(items: items, next: next)
        }

        func post(id: String) async throws -> Post? {
            pages.flatMap { $0 }.first { $0.id == id }
        }
    }

    final class FakeLikes: LikeRepository, @unchecked Sendable {
        var likeResult: LikeMutationResult = .changed
        var unlikeResult: LikeMutationResult = .changed
        var likeError: Error?
        var likeCalls: [String] = []
        var batchCalls: [[String]] = []
        var alreadyLiked: Set<String> = []
        /// Lets a test hold a call open to check that a second one waits.
        var gate: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)?

        func like(postID: String) async throws -> LikeMutationResult {
            likeCalls.append("like:\(postID)")
            if let gate { for await _ in gate.stream { break } }
            if let likeError { throw likeError }
            return likeResult
        }

        func unlike(postID: String) async throws -> LikeMutationResult {
            likeCalls.append("unlike:\(postID)")
            if let likeError { throw likeError }
            return unlikeResult
        }

        func likedPostIDs(among postIDs: [String]) async throws -> Set<String> {
            batchCalls.append(postIDs)
            return alreadyLiked.intersection(postIDs)
        }
    }

    static func post(_ id: String, likeCount: Int = 0) -> Post {
        Post(
            id: id, authorID: "uid", authorName: "A", authorAvatarURL: nil,
            text: "TEST CONTENT \(id)", media: [], petID: nil, petName: nil,
            petAvatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            likeCount: likeCount, commentCount: 0, tags: []
        )
    }

    // MARK: - Paging

    @Test func loadsTheFirstPage() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a"), Self.post("b")]]
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 2)

        await model.loadFirstPageIfNeeded()

        #expect(model.posts.map(\.id) == ["a", "b"])
        #expect(model.state == .loaded)
    }

    /// 5A.3: a fast scroll asks repeatedly; the same cursor must be fetched once.
    @Test func doesNotRequestTheSameCursorTwice() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a")], [Self.post("b")]]
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 1)

        await model.loadFirstPageIfNeeded()
        // The same row triggers three times, which is what a flung list does:
        // the row's .task fires, is cancelled by the scroll, and fires again.
        let trigger = model.posts.last
        await model.loadMoreIfNeeded(currentItem: trigger)
        await model.loadMoreIfNeeded(currentItem: trigger)
        await model.loadMoreIfNeeded(currentItem: trigger)

        #expect(feed.cursorsRequested.count == 2, "requested \(feed.cursorsRequested.count) times")
        #expect(model.posts.map(\.id) == ["a", "b"])

        // The property that actually matters, stated directly: no cursor is
        // ever spent twice, however many times the list asks.
        let spent = feed.cursorsRequested.compactMap { $0 }
        #expect(Set(spent).count == spent.count, "a cursor was requested more than once")
    }

    @Test func appendingAPageNeverDuplicatesRows() async {
        let feed = FakeFeed()
        // The same post arrives on both pages, as it would if something were
        // written while paging.
        feed.pages = [[Self.post("a")], [Self.post("a"), Self.post("b")]]
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 1)

        await model.loadFirstPageIfNeeded()
        await model.loadMoreIfNeeded(currentItem: model.posts.last)

        #expect(model.posts.map(\.id) == ["a", "b"])
    }

    /// Empty and failed have to be distinguishable (§6.5).
    @Test func failureIsNotAnEmptyList() async {
        let feed = FakeFeed()
        feed.error = NSError(domain: "test", code: 1)
        let model = FeedViewModel(feed: feed, likes: FakeLikes())

        await model.loadFirstPageIfNeeded()

        #expect(model.posts.isEmpty)
        if case .failed = model.state {} else {
            Issue.record("Expected .failed, got \(model.state)")
        }
    }

    /// Offline and server error need different words (§6.5).
    @Test func offlineIsDistinguishedFromAServerError() async {
        let offlineFeed = FakeFeed()
        offlineFeed.error = NSError(domain: NSURLErrorDomain, code: -1009)
        let offline = FeedViewModel(feed: offlineFeed, likes: FakeLikes())
        await offline.loadFirstPageIfNeeded()
        #expect(offline.state == .failed(.offline))

        let serverFeed = FakeFeed()
        serverFeed.error = NSError(domain: "FIRFirestoreErrorDomain", code: 13)
        let server = FeedViewModel(feed: serverFeed, likes: FakeLikes())
        await server.loadFirstPageIfNeeded()
        #expect(server.state == .failed(.server))
    }

    /// A refresh must invalidate a page already in flight, not splice it in
    /// after the fresh rows — that leaves gaps nothing can page over.
    @Test func aRefreshDiscardsAPageFromTheOldGeneration() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("old1")], [Self.post("old2")]]
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 1)
        await model.loadFirstPageIfNeeded()

        // Page 2 is requested, then the list is replaced before it lands.
        async let pending: Void = model.loadMoreIfNeeded(currentItem: model.posts.last)
        feed.pages = [[Self.post("new1")]]
        await model.reload()
        await pending

        #expect(model.posts.map(\.id) == ["new1"], "the stale page is dropped")
    }

    // MARK: - Like status is batched, not N+1

    @Test func likeStatusIsFetchedInOneBatchPerPage() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a"), Self.post("b"), Self.post("c")]]
        let likes = FakeLikes()
        likes.alreadyLiked = ["b"]
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 3)

        await model.loadFirstPageIfNeeded()

        #expect(likes.batchCalls.count == 1, "one query per page, not per post")
        #expect(likes.batchCalls.first?.count == 3)
        #expect(model.isLiked(Self.post("b")))
        #expect(!model.isLiked(Self.post("a")))
    }

    // MARK: - Like: three states

    @Test func likeAppliesOptimisticallyAndKeepsItOnChanged() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a", likeCount: 4)]]
        let likes = FakeLikes()
        likes.likeResult = .changed
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()

        model.toggleLike(model.posts[0])
        #expect(model.isLiked(model.posts[0]), "optimistic update is immediate")
        #expect(model.displayLikeCount(for: model.posts[0]) == 5)

        await model.waitForPendingLikes()
        #expect(model.isLiked(model.posts[0]))
        #expect(model.displayLikeCount(for: model.posts[0]) == 5, "confirmed, still 5")
    }

    /// `unchanged` means the server was ALREADY in this state, so the count it
    /// gave us already contains this like. The heart is right; the optimistic
    /// +1 is one too many and has to come back off.
    ///
    /// This is reachable without any race: if the batched like-status query
    /// fails, every already-liked post renders unliked, and the first tap on
    /// each answers `.unchanged`. Keeping the offset inflated those rows
    /// permanently — the web client guards the same case in useLike.ts:216.
    @Test func unchangedKeepsTheHeartButRollsBackTheCount() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a", likeCount: 5)]]
        let likes = FakeLikes()
        likes.likeResult = .unchanged
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()

        model.toggleLike(model.posts[0])
        #expect(model.displayLikeCount(for: model.posts[0]) == 6, "optimistic while in flight")

        await model.waitForPendingLikes()
        #expect(model.isLiked(Self.post("a")), "the heart stays filled")
        #expect(model.displayLikeCount(for: model.posts[0]) == 5, "the count returns to the server's")
    }

    /// The mirror case: unliking something the server does not have.
    @Test func unchangedOnUnlikeRollsTheCountForward() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a", likeCount: 5)]]
        let likes = FakeLikes()
        likes.alreadyLiked = ["a"]
        likes.unlikeResult = .unchanged
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()
        #expect(model.isLiked(Self.post("a")))

        model.toggleLike(model.posts[0])
        await model.waitForPendingLikes()

        #expect(!model.isLiked(Self.post("a")))
        #expect(model.displayLikeCount(for: model.posts[0]) == 5, "never below the server's count")
    }

    /// A rollback must not undo a state a later tap already set.
    ///
    /// Sequence: tap (like, 6) → tap again before it settles (unlike, 5) → the
    /// first request fails. Reverting blindly took it to 4 and left the screen
    /// permanently disagreeing with the server.
    @Test func aFailedLikeDoesNotRollBackOverALaterTap() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a", likeCount: 5)]]
        let likes = FakeLikes()
        likes.likeError = NSError(domain: "test", code: 14)
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()

        model.toggleLike(model.posts[0])   // like   → 6
        model.toggleLike(model.posts[0])   // unlike → 5, and supersedes the first
        await model.waitForPendingLikes()

        #expect(model.displayLikeCount(for: model.posts[0]) == 5, "the superseded failure must not drift the count")
        #expect(!model.isLiked(Self.post("a")))
    }

    /// The batch query is authoritative for the ids it was asked about: a post
    /// it does not return is not liked. Discarding that answer left a filled
    /// heart that pull-to-refresh could not clear.
    @Test func likeStatusClearsHeartsTheServerNoLongerHas() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a"), Self.post("b")]]
        let likes = FakeLikes()
        likes.alreadyLiked = ["a", "b"]
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 2)
        await model.loadFirstPageIfNeeded()
        #expect(model.likedPostIDs == ["a", "b"])

        // The like on "a" goes away server-side; the reader pulls to refresh.
        likes.alreadyLiked = ["b"]
        await model.reload()

        #expect(model.likedPostIDs == ["b"], "the stale heart is cleared")
    }

    /// 5A.9: the state the old web client used to swallow.
    @Test func postNotFoundRollsBackAndRemovesTheRow() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a", likeCount: 4), Self.post("b")]]
        let likes = FakeLikes()
        likes.likeResult = .postNotFound
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 2)
        await model.loadFirstPageIfNeeded()

        model.toggleLike(model.posts[0])
        await model.waitForPendingLikes()

        #expect(model.posts.map(\.id) == ["b"], "the deleted post is dropped")
        #expect(!model.likedPostIDs.contains("a"), "the optimistic like is rolled back")
        #expect(model.likeFailureMessage != nil)
    }

    /// 5A.10: a failed write rolls the display back and says so.
    @Test func aFailedLikeRollsBack() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a", likeCount: 4)]]
        let likes = FakeLikes()
        likes.likeError = NSError(domain: "test", code: 14)
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()

        model.toggleLike(model.posts[0])
        await model.waitForPendingLikes()

        #expect(!model.isLiked(Self.post("a")))
        #expect(model.displayLikeCount(for: model.posts[0]) == 4, "the count returns to the server's")
        #expect(model.likeFailureMessage != nil)
    }

    /// 5A.8: five taps in a row settle on the last intent and never go negative.
    @Test func repeatedTapsSettleOnTheLastIntent() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a", likeCount: 0)]]
        let likes = FakeLikes()
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()

        for _ in 0..<5 { model.toggleLike(model.posts[0]) }
        await model.waitForPendingLikes()

        // Odd number of taps starting from unliked ends liked.
        #expect(model.isLiked(Self.post("a")))
        #expect(model.displayLikeCount(for: model.posts[0]) >= 0, "a count is never negative")
        // Serialized: every tap produced exactly one call, in order.
        #expect(likes.likeCalls.count == 5)
    }
}
