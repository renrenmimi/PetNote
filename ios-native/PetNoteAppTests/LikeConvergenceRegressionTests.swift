import Foundation
import Testing

@testable import PetNote

/// Regressions for the three like defects an independent review found in
/// ed06b7b. Written to fail against that code, so that passing means something.
///
/// The shape they share: the client tracks what it believes the server holds,
/// and each bug is a different way that belief stops matching reality.
@MainActor
struct LikeConvergenceRegressionTests {
    final class Feed: FeedRepository, @unchecked Sendable {
        var page: [Post] = []
        func posts(after cursor: PageCursor?, limit: Int) async throws -> Page<Post> {
            Page(items: page, next: nil)
        }
        func post(id: String) async throws -> Post? { page.first { $0.id == id } }
    }

    /// Answers can be made to arrive in a chosen order, which is what the
    /// out-of-order cases need.
    final class Likes: LikeRepository, @unchecked Sendable {
        var liked: Set<String> = []
        var likeResults: [LikeMutationResult] = []
        var unlikeResults: [LikeMutationResult] = []
        var calls: [String] = []
        var batchError: Error?
        /// Set to hold every mutation until released.
        private var gate: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)?

        func hold() {
            let (s, c) = AsyncStream<Void>.makeStream()
            gate = (s, c)
        }
        func release() {
            gate?.continuation.finish()
            gate = nil
        }

        func like(postID: String) async throws -> LikeMutationResult {
            calls.append("like")
            if let gate { for await _ in gate.stream { break } }
            return likeResults.isEmpty ? .changed : likeResults.removeFirst()
        }
        func unlike(postID: String) async throws -> LikeMutationResult {
            calls.append("unlike")
            if let gate { for await _ in gate.stream { break } }
            return unlikeResults.isEmpty ? .changed : unlikeResults.removeFirst()
        }
        func likedPostIDs(among postIDs: [String]) async throws -> Set<String> {
            if let batchError { throw batchError }
            return liked.intersection(postIDs)
        }
    }

    static func post(_ id: String = "p", likeCount: Int) -> Post {
        Post(
            id: id, authorID: "u", authorName: "A", authorAvatarURL: nil,
            text: "t", media: [], petID: nil, petName: nil, petAvatarURL: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            likeCount: likeCount, commentCount: 0, tags: []
        )
    }

    /// **Finding 3.** Like then unlike, both succeeding. The server ends where
    /// it started, so the screen must too.
    ///
    /// The old code discarded the first answer because a later tap had
    /// superseded it — but that answer reported a change the server had
    /// already made. The +1 was never recorded and the -1 was, so the count
    /// drifted one below the truth and stayed there.
    @Test func likeThenUnlikeBothSucceedingLeavesTheCountWhereItStarted() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 5)]
        let likes = Likes()
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()
        #expect(model.displayLikeCount(for: model.posts[0]) == 5)

        // Both taps happen before either answer arrives.
        likes.hold()
        model.toggleLike(model.posts[0])   // like   → optimistic 6
        model.toggleLike(model.posts[0])   // unlike → optimistic 5
        likes.release()
        await model.waitForPendingLikes()

        #expect(likes.calls == ["like", "unlike"], "both requests really went out")
        #expect(!model.isLiked(Self.post(likeCount: 5)), "ends unliked")
        #expect(
            model.displayLikeCount(for: model.posts[0]) == 5,
            "showed \(model.displayLikeCount(for: model.posts[0])); the server is back at 5"
        )
    }

    /// The mirror: unlike then like, starting from liked.
    @Test func unlikeThenLikeBothSucceedingLeavesTheCountWhereItStarted() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 5)]
        let likes = Likes()
        likes.liked = ["p"]
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()
        #expect(model.isLiked(Self.post(likeCount: 5)))

        likes.hold()
        model.toggleLike(model.posts[0])   // unlike
        model.toggleLike(model.posts[0])   // like
        likes.release()
        await model.waitForPendingLikes()

        #expect(model.isLiked(Self.post(likeCount: 5)))
        #expect(model.displayLikeCount(for: model.posts[0]) == 5)
    }

    /// **Finding 4.** Another device removes the like; a refresh here must
    /// adopt that.
    ///
    /// The old code only accepted the server's answer when its intent counter
    /// was zero, and that counter only ever went up — so after a single tap,
    /// every later refresh was ignored and the heart stayed filled forever.
    @Test func aRefreshAdoptsTheServersStateAfterAnEarlierTap() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 5)]
        let likes = Likes()
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()

        // Tap, and let it settle: the server now holds the like.
        likes.liked = ["p"]
        model.toggleLike(model.posts[0])
        await model.waitForPendingLikes()
        #expect(model.isLiked(Self.post(likeCount: 5)))

        // Somewhere else, the like is removed and the count goes back.
        likes.liked = []
        feed.page = [Self.post(likeCount: 5)]
        await model.reload()

        #expect(
            !model.isLiked(Self.post(likeCount: 5)),
            "the refresh was ignored — the heart is still filled"
        )
        #expect(model.displayLikeCount(for: model.posts[0]) == 5)
    }

    /// **Finding 5.** `.changed` means the like document was written. It does
    /// not mean `likeCount` has moved: that is done by a trigger, afterwards.
    ///
    /// So a refresh that lands before the trigger brings back the OLD count,
    /// and a client that assumes otherwise shows one too few.
    @Test func aRefreshBeforeTheTriggerRunsStillShowsOurLike() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 5)]
        let likes = Likes()
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()

        likes.liked = ["p"]
        model.toggleLike(model.posts[0])
        await model.waitForPendingLikes()
        #expect(model.displayLikeCount(for: model.posts[0]) == 6)

        // The like document exists, so the batch query reports it — but
        // onLikeCreated has not run, so the count is still the old one.
        await model.reload()

        #expect(model.isLiked(Self.post(likeCount: 5)))
        #expect(
            model.displayLikeCount(for: model.posts[0]) == 6,
            "showed \(model.displayLikeCount(for: model.posts[0])); our like is real and must stay counted"
        )

        // The trigger runs; the server's own number now includes it.
        feed.page = [Self.post(likeCount: 6)]
        await model.reload()
        #expect(
            model.displayLikeCount(for: model.posts[0]) == 6,
            "showed \(model.displayLikeCount(for: model.posts[0])); it must not be counted twice"
        )
    }

    /// And the same for an unlike, where the trigger decrements later.
    @Test func aRefreshBeforeTheDecrementTriggerRunsStillShowsTheUnlike() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 5)]
        let likes = Likes()
        likes.liked = ["p"]
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()

        likes.liked = []
        model.toggleLike(model.posts[0])   // unlike
        await model.waitForPendingLikes()
        #expect(model.displayLikeCount(for: model.posts[0]) == 4)

        await model.reload()   // count still 5: onLikeDeleted has not run
        #expect(model.displayLikeCount(for: model.posts[0]) == 4)

        feed.page = [Self.post(likeCount: 4)]
        await model.reload()
        #expect(model.displayLikeCount(for: model.posts[0]) == 4)
    }
}
