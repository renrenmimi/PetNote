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

        /// Runs **inside** one open read: after the page has been chosen and
        /// before it is handed back.
        ///
        /// This is how a test puts something in the window a read is already
        /// in flight — a write being confirmed, a second refresh overtaking
        /// this one — without a sleep and without repeating until it happens.
        /// The page returned is the one sampled *before* the hook ran, which
        /// is exactly what a read that predates the write looks like.
        ///
        /// One-shot: it clears itself before running, so a hook that reads
        /// again does not recurse.
        var whileInFlight: (@Sendable () async -> Void)?

        /// The same window, for a read that is going to **fail**.
        ///
        /// `whileInFlight` runs after the page has been chosen, so a read with
        /// `error` set throws before ever reaching it — and "what is on screen
        /// while a refresh that will fail is still out" is exactly one of the
        /// things that has to be checked. This one runs first, before the
        /// error is consulted, so the failing half of every round trip has an
        /// open window too.
        ///
        /// One-shot, like the other.
        var beforeAnswering: (@Sendable () async -> Void)?

        func posts(after cursor: PageCursor?, limit: Int) async throws -> Page<Post> {
            cursorsRequested.append(cursor)
            if let hook = beforeAnswering {
                beforeAnswering = nil
                await hook()
            }
            if let error { throw error }
            // A first-page read retires every cursor, exactly as
            // `FirestoreFeedRepository` does with `resumePoints`. Without it
            // the tokens issued before a refresh stay in the list and shift
            // the position of every token issued after one, so paging after a
            // refresh reads off the end and answers `.empty` — a fake
            // answering differently from the thing it stands for, which is
            // the one kind of test failure that says nothing about the app.
            // `aRefreshClearsALostPageAndItsCursor` is the test that found it.
            if cursor == nil { issued.removeAll() }
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
            if let hook = whileInFlight {
                whileInFlight = nil
                await hook()
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
        var unlikeError: Error?
        var batchError: Error?
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
            if let unlikeError { throw unlikeError }
            if let likeError { throw likeError }
            return unlikeResult
        }

        func likedPostIDs(among postIDs: [String]) async throws -> Set<String> {
            batchCalls.append(postIDs)
            if let batchError { throw batchError }
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
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 2, sleeper: ManualDeadline.never)

        await model.loadFirstPageIfNeeded()

        #expect(model.posts.map(\.id) == ["a", "b"])
        #expect(model.state == .loaded)
    }

    /// A post deleted from its detail screen leaves the feed at once, and the
    /// scroll anchor does not go on pointing at it.
    @Test func aDeletedPostLeavesTheFeedAndTheAnchorWithIt() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a"), Self.post("b"), Self.post("c")]]
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 3, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()
        model.rememberScrollAnchor("b")

        model.removePost(id: "b")

        #expect(model.posts.map(\.id) == ["a", "c"])
        #expect(model.scrollAnchor == nil, "the anchor still names a post that is not in the list")
        #expect(model.state == .loaded)
    }

    /// Removing a post the feed never had is not an error and changes nothing —
    /// the detail screen can be reached for a post that is not on this page.
    @Test func removingAPostTheFeedDoesNotHoldChangesNothing() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a"), Self.post("b")]]
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 2, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()
        model.rememberScrollAnchor("a")

        model.removePost(id: "elsewhere")

        #expect(model.posts.map(\.id) == ["a", "b"])
        #expect(model.scrollAnchor == "a", "an unrelated removal cleared the anchor")
    }

    /// 5A.3: a fast scroll asks repeatedly; the same cursor must be fetched once.
    @Test func doesNotRequestTheSameCursorTwice() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a")], [Self.post("b")]]
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 1, sleeper: ManualDeadline.never)

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
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 1, sleeper: ManualDeadline.never)

        await model.loadFirstPageIfNeeded()
        await model.loadMoreIfNeeded(currentItem: model.posts.last)

        #expect(model.posts.map(\.id) == ["a", "b"])
    }

    /// Empty and failed have to be distinguishable (§6.5).
    @Test func failureIsNotAnEmptyList() async {
        let feed = FakeFeed()
        feed.error = NSError(domain: "test", code: 1)
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), sleeper: ManualDeadline.never)

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
        let offline = FeedViewModel(feed: offlineFeed, likes: FakeLikes(), sleeper: ManualDeadline.never)
        await offline.loadFirstPageIfNeeded()
        #expect(offline.state == .failed(.offline))

        let serverFeed = FakeFeed()
        serverFeed.error = NSError(domain: "FIRFirestoreErrorDomain", code: 13)
        let server = FeedViewModel(feed: serverFeed, likes: FakeLikes(), sleeper: ManualDeadline.never)
        await server.loadFirstPageIfNeeded()
        #expect(server.state == .failed(.server))
    }

    /// A refresh must invalidate a page already in flight, not splice it in
    /// after the fresh rows — that leaves gaps nothing can page over.
    @Test func aRefreshDiscardsAPageFromTheOldGeneration() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("old1")], [Self.post("old2")]]
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 1, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()

        // Page 2 is requested, then the list is replaced before it lands.
        // Read before starting the task, for the same reason: an `async let`
        // evaluates its right-hand side inside the new task.
        let last = model.posts.last
        async let pending: Void = model.loadMoreIfNeeded(currentItem: last)
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
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 3, sleeper: ManualDeadline.never)

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
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1, sleeper: ManualDeadline.never)
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
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1, sleeper: ManualDeadline.never)
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
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1, sleeper: ManualDeadline.never)
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
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1, sleeper: ManualDeadline.never)
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
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 2, sleeper: ManualDeadline.never)
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
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 2, sleeper: ManualDeadline.never)
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
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()

        model.toggleLike(model.posts[0])
        await model.waitForPendingLikes()

        #expect(!model.isLiked(Self.post("a")))
        #expect(model.displayLikeCount(for: model.posts[0]) == 4, "the count returns to the server's")
        #expect(model.likeFailureMessage != nil)
    }

    // MARK: - Convergence with the server

    /// A failed batch read must not be read as "nothing is liked".
    ///
    /// This is the path that made `.unchanged` dangerous: the query fails, every
    /// row renders unliked, and the first tap on an already-liked post answers
    /// `.unchanged`. What must not happen is the count drifting because of it.
    @Test func aFailedStatusReadDoesNotInventAnUnlikedState() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a", likeCount: 5)]]
        let likes = FakeLikes()
        likes.batchError = NSError(domain: "test", code: 14)
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()

        // Unknown, so the heart renders unset — but the count is untouched.
        #expect(!model.isLiked(Self.post("a")))
        #expect(model.displayLikeCount(for: model.posts[0]) == 5, "an unknown status must not move the count")

        // The person taps; the server says it was already liked.
        likes.likeResult = .unchanged
        model.toggleLike(model.posts[0])
        await model.waitForPendingLikes()

        #expect(model.isLiked(Self.post("a")), "the heart is now right")
        #expect(
            model.displayLikeCount(for: model.posts[0]) == 5,
            "and the count still matches the server, with no phantom like"
        )
    }

    /// A later server snapshot must not double-count a local increment that the
    /// server has already applied.
    @Test func aRefreshAfterAConfirmedLikeDoesNotDoubleCount() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a", likeCount: 5)]]
        let likes = FakeLikes()
        likes.likeResult = .changed
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()

        model.toggleLike(model.posts[0])
        await model.waitForPendingLikes()
        #expect(model.displayLikeCount(for: model.posts[0]) == 6, "server 5 + our confirmed like")

        // The server's own count now includes it, and a refresh brings that
        // number back. The confirmed local delta must not be added on top.
        feed.pages = [[Self.post("a", likeCount: 6)]]
        likes.alreadyLiked = ["a"]
        await model.reload()

        #expect(
            model.displayLikeCount(for: model.posts[0]) == 6,
            "got \(model.displayLikeCount(for: model.posts[0])) — the confirmed delta was applied twice"
        )
        #expect(model.isLiked(Self.post("a")))
    }

    /// Responses arriving out of order must not leave the display disagreeing
    /// with the last thing the person asked for.
    @Test func outOfOrderResponsesSettleOnTheLastIntent() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a", likeCount: 5)]]
        let likes = FakeLikes()
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()

        // like, unlike, like — three intents, settled in order by the model's
        // own serialisation, whatever order the fake answers in.
        likes.likeResult = .changed
        likes.unlikeResult = .changed
        model.toggleLike(model.posts[0])
        model.toggleLike(model.posts[0])
        model.toggleLike(model.posts[0])
        await model.waitForPendingLikes()

        #expect(model.isLiked(Self.post("a")), "three taps from unliked ends liked")
        #expect(
            model.displayLikeCount(for: model.posts[0]) == 6,
            "got \(model.displayLikeCount(for: model.posts[0]))"
        )
    }

    /// Offline: the display goes back to what the server last said, and says so.
    @Test func anOfflineFailureConvergesBackToTheServersState() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a", likeCount: 5)]]
        let likes = FakeLikes()
        likes.alreadyLiked = ["a"]
        likes.unlikeError = NSError(domain: NSURLErrorDomain, code: -1009)
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()
        #expect(model.isLiked(Self.post("a")))

        model.toggleLike(model.posts[0])   // try to unlike, offline
        await model.waitForPendingLikes()

        #expect(model.isLiked(Self.post("a")), "still liked, because the server still has it")
        #expect(model.displayLikeCount(for: model.posts[0]) == 5)
        #expect(model.likeFailureMessage != nil, "and the person is told")
    }

    /// Switching accounts must not leave the previous account's likes behind.
    ///
    /// The feed model is session-scoped and thrown away on sign-out, so this
    /// asserts the property a fresh model has: it starts from the server's
    /// answer for the new account, not from anything remembered.
    @Test func aNewSessionStartsFromTheServerNotFromMemory() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a", likeCount: 5)]]

        // Account one has liked it.
        let first = FakeLikes()
        first.alreadyLiked = ["a"]
        let firstModel = FeedViewModel(feed: feed, likes: first, pageSize: 1, sleeper: ManualDeadline.never)
        await firstModel.loadFirstPageIfNeeded()
        #expect(firstModel.isLiked(Self.post("a")))

        // Account two has not. A new model is what sign-out produces.
        let second = FakeLikes()
        second.alreadyLiked = []
        let secondModel = FeedViewModel(feed: feed, likes: second, pageSize: 1, sleeper: ManualDeadline.never)
        await secondModel.loadFirstPageIfNeeded()

        #expect(!secondModel.isLiked(Self.post("a")), "the new account sees its own state")
        #expect(secondModel.displayLikeCount(for: secondModel.posts[0]) == 5)
    }

    /// A page that arrives after the list has been replaced must not be spliced
    /// in — and neither must the like status that came with it.
    @Test func aStalePagesLikeStatusIsDiscardedToo() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("old")], [Self.post("stale")]]
        let likes = FakeLikes()
        likes.alreadyLiked = ["stale"]
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()

        let trigger = model.posts.last
        async let paging: Void = model.loadMoreIfNeeded(currentItem: trigger)
        feed.pages = [[Self.post("fresh")]]
        likes.alreadyLiked = []
        await model.reload()
        await paging

        #expect(model.posts.map(\.id) == ["fresh"])
        #expect(!model.likedPostIDs.contains("stale"), "a discarded page left its like state behind")
    }

    /// 5A.8: five taps in a row settle on the last intent and never go negative.
    @Test func repeatedTapsSettleOnTheLastIntent() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a", likeCount: 0)]]
        let likes = FakeLikes()
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()

        for _ in 0..<5 { model.toggleLike(model.posts[0]) }
        await model.waitForPendingLikes()

        // Odd number of taps starting from unliked ends liked.
        #expect(model.isLiked(Self.post("a")))
        #expect(model.displayLikeCount(for: model.posts[0]) >= 0, "a count is never negative")
        // Serialized: every tap produced exactly one call, in order.
        #expect(likes.likeCalls.count == 5)
    }

    // MARK: - Refresh and paging failure, with the round trip held open
    //
    // Every test in this section fixes the moment it is asking about rather
    // than sampling for it. The previous round could not reproduce any of
    // these against the emulator and said so — a local round trip is 90ms, and
    // "the rows were still there afterwards" is not an answer about what was
    // on screen *during*. `beforeAnswering` and `whileInFlight` run inside an
    // open read, so the window is constructed rather than waited for, and a
    // passing test here passes because that interleaving happened.
    //
    // These are assertions about the model. What the *screen* does with them
    // is `RefreshAndPagingUITests` and `CommentUITests`, which are separate on
    // purpose: this file cannot see a view, and a view test cannot see a
    // generation counter.

    /// 1. A refresh does not take the rows away while it is running.
    ///
    /// `reload()` moves to `.loadingFirstPage` whatever was on screen, so the
    /// property that keeps the list up is not the state — it is that `posts`
    /// is left alone until a replacement arrives. That is what is checked
    /// here, at the one instant it can be checked: inside the open read.
    @Test func aRefreshInFlightStillHoldsTheRowsItIsReplacing() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a"), Self.post("b")]]
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 2, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()

        let during = Reading()
        feed.pages = [[Self.post("c"), Self.post("d")]]
        feed.whileInFlight = { @MainActor @Sendable in during.take(from: model) }
        await model.reload()

        #expect(during.postIDs == ["a", "b"], "the rows were dropped mid-refresh: \(during.postIDs)")
        #expect(during.state == .loadingFirstPage, "the window sampled was not the refresh")
        #expect(model.posts.map(\.id) == ["c", "d"], "and the replacement did arrive")
    }

    /// 2. A refresh that fails keeps what was readable and says so separately.
    ///
    /// Both halves: the rows are there while the doomed read is still out, and
    /// they are still there after it fails. `.failed` with a non-empty `posts`
    /// is the state the banner is drawn from; `.failed` with an empty one is
    /// the whole-screen error, and the two must stay distinguishable.
    @Test func aFailedRefreshKeepsTheRowsAndStaysRetryable() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a"), Self.post("b")]]
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 2, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()

        let during = Reading()
        feed.error = NSError(domain: "FIRFirestoreErrorDomain", code: 13)
        feed.beforeAnswering = { @MainActor @Sendable in during.take(from: model) }
        await model.reload()

        #expect(during.postIDs == ["a", "b"], "the rows went before the failure did")
        #expect(model.posts.map(\.id) == ["a", "b"], "a failed refresh deleted the answer it was reporting on")
        #expect(model.state == .failed(.server))

        // The retry the banner offers is `reload()` again, and it recovers.
        feed.error = nil
        feed.pages = [[Self.post("c")]]
        await model.reload()
        #expect(model.state == .loaded)
        #expect(model.posts.map(\.id) == ["c"])
    }

    /// 2b. The other side of the same branch: with nothing to keep, a failure
    /// is a whole-screen failure. Losing this distinction would make the
    /// banner the only thing an empty, broken feed ever showed.
    @Test func aFailedFirstLoadWithNothingToKeepIsStillAWholeScreenFailure() async {
        let feed = FakeFeed()
        feed.error = NSError(domain: NSURLErrorDomain, code: -1009)
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 2, sleeper: ManualDeadline.never)

        await model.loadFirstPageIfNeeded()

        #expect(model.posts.isEmpty)
        #expect(model.state == .failed(.offline))
    }

    /// 3. Losing page three does not take pages one and two with it.
    @Test func aFailedNextPageKeepsThePagesAlreadyRead() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a")], [Self.post("b")], [Self.post("c")]]
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 1, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()
        await model.loadMoreIfNeeded(currentItem: model.posts.last)
        #expect(model.posts.map(\.id) == ["a", "b"])

        let during = Reading()
        feed.error = NSError(domain: "test", code: 13)
        feed.beforeAnswering = { @MainActor @Sendable in during.take(from: model) }
        await model.loadMoreIfNeeded(currentItem: model.posts.last)

        #expect(during.postIDs == ["a", "b"], "the read that was going to fail already had the rows off")
        #expect(during.isLoadingMore, "the window sampled was not the page request")
        #expect(model.posts.map(\.id) == ["a", "b"], "a lost page took the read ones with it")
        #expect(model.state == .loaded, "a lost page is not a broken screen")
        #expect(model.pagingFailure == .server, "and it is reported where it happened")
    }

    /// 4. An answer from a refresh that has been overtaken describes a list
    /// that no longer exists, and is dropped whole.
    ///
    /// Refresh A is held open; refresh B runs to completion inside it and
    /// brings back different rows; A then answers with what it sampled before
    /// B existed. Splicing A in would put the older list back under the
    /// person's finger.
    @Test func aLateRefreshAnswerDoesNotOverwriteANewerOne() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("first")]]
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 1, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()

        // A samples ["stale"], then B runs inside A's open read and brings
        // back ["newest"]. A's answer arrives afterwards.
        feed.pages = [[Self.post("stale")]]
        feed.whileInFlight = { @MainActor @Sendable in
            feed.pages = [[Self.post("newest")]]
            await model.reload()
        }
        await model.reload()

        #expect(model.posts.map(\.id) == ["newest"], "the overtaken refresh was applied: \(model.posts.map(\.id))")
        #expect(model.state == .loaded)
    }

    /// 4b. The same for a *failure* that arrives late. A refresh that has been
    /// superseded must not put the screen into `.failed` — the newer one
    /// succeeded, and the person would be told the feed is broken while
    /// looking at a feed that is not.
    @Test func aLateRefreshFailureDoesNotOverwriteANewerSuccess() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("first")]]
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 1, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()

        feed.error = NSError(domain: "test", code: 13)
        feed.beforeAnswering = { @MainActor @Sendable in
            feed.error = nil
            feed.pages = [[Self.post("newest")]]
            await model.reload()
            feed.error = NSError(domain: "test", code: 13)
        }
        await model.reload()

        #expect(model.state == .loaded, "a superseded failure broke a screen that had just loaded")
        #expect(model.posts.map(\.id) == ["newest"])
    }

    /// 5. Retrying a lost page fetches the page that was lost — not the one
    /// after it — and adds it exactly once.
    ///
    /// Both failures are silent from the outside. A skip leaves rows nothing
    /// can ever page back to; a repeat shows the same post twice. The cursor
    /// trail is asserted directly because `posts` alone cannot tell the two
    /// apart from a fake that happens to answer consistently.
    @Test func retryingALostPageAddsItOnceAndSkipsNothing() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a")], [Self.post("b")], [Self.post("c")]]
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 1, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()

        feed.error = NSError(domain: "test", code: 13)
        await model.loadMoreIfNeeded(currentItem: model.posts.last)
        #expect(model.pagingFailure != nil)
        let failedCursor = feed.cursorsRequested.last

        feed.error = nil
        await model.retryPaging()

        #expect(feed.cursorsRequested.last == failedCursor, "the retry skipped the page that was lost")
        #expect(model.posts.map(\.id) == ["a", "b"], "got \(model.posts.map(\.id))")
        #expect(model.pagingFailure == nil)

        // And paging carries on from there rather than from a hole.
        await model.loadMoreIfNeeded(currentItem: model.posts.last)
        #expect(model.posts.map(\.id) == ["a", "b", "c"], "got \(model.posts.map(\.id))")
        #expect(Set(model.posts.map(\.id)).count == model.posts.count, "a row was added twice")
    }

    /// 5b. The retry is idempotent under the thing that produced it: a list
    /// still being flung asks repeatedly, and the recovered cursor must not be
    /// spent twice either.
    @Test func retryingTwiceDoesNotFetchThePageTwice() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a")], [Self.post("b")], [Self.post("c")]]
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 1, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()

        feed.error = NSError(domain: "test", code: 13)
        await model.loadMoreIfNeeded(currentItem: model.posts.last)
        feed.error = nil

        await model.retryPaging()
        await model.loadMoreIfNeeded(currentItem: model.posts.last)
        await model.loadMoreIfNeeded(currentItem: model.posts.last)

        #expect(model.posts.map(\.id) == ["a", "b", "c"], "got \(model.posts.map(\.id))")
        let spent = feed.cursorsRequested.compactMap { $0 }
        // The lost page's cursor is requested twice on purpose — once losing,
        // once recovering. Nothing else may be.
        let counts = Dictionary(grouping: spent, by: { $0 }).mapValues(\.count)
        #expect(counts.values.filter { $0 > 1 }.count == 1, "a cursor was spent more than once: \(counts.values.sorted())")
    }

    /// 5c. A refresh landing on top of a lost page clears the failure rather
    /// than leaving a retry button pointing at a cursor from a list that has
    /// been replaced. Tapping that button after a refresh would page from the
    /// wrong place.
    @Test func aRefreshClearsALostPageAndItsCursor() async {
        let feed = FakeFeed()
        feed.pages = [[Self.post("a")], [Self.post("b")]]
        let model = FeedViewModel(feed: feed, likes: FakeLikes(), pageSize: 1, sleeper: ManualDeadline.never)
        await model.loadFirstPageIfNeeded()

        feed.error = NSError(domain: "test", code: 13)
        await model.loadMoreIfNeeded(currentItem: model.posts.last)
        #expect(model.pagingFailure != nil)

        feed.error = nil
        feed.pages = [[Self.post("x")], [Self.post("y")]]
        await model.reload()

        #expect(model.pagingFailure == nil, "the old page's failure outlived the list it belonged to")
        #expect(model.posts.map(\.id) == ["x"])
        await model.loadMoreIfNeeded(currentItem: model.posts.last)
        #expect(model.posts.map(\.id) == ["x", "y"], "got \(model.posts.map(\.id))")
    }
}

/// One instant of what the feed was holding, taken from inside an open read.
///
/// A class rather than captured locals because the hook that fills it is an
/// escaping `@Sendable` closure. `@MainActor` on the type is what makes it
/// `Sendable` without an `@unchecked`, and it is the same actor the model
/// lives on, so the reading is taken without a hop that could let the model
/// move underneath it.
@MainActor
final class Reading {
    var postIDs: [String] = []
    var state: FeedViewModel.LoadState = .idle
    var pagingFailure: FeedViewModel.FailureKind?
    var isLoadingMore = false

    func take(from model: FeedViewModel) {
        postIDs = model.posts.map(\.id)
        state = model.state
        pagingFailure = model.pagingFailure
        isLoadingMore = model.isLoadingMore
    }
}
