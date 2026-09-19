import Foundation
import Testing

@testable import PetNote

/// Regressions for the like defects successive reviews have found, each one
/// written to fail against the code that had it.
///
/// The shape they share: the client tracks what it believes the server holds,
/// and each bug is a different way that belief stops matching reality.
///
/// Every scenario here is ordered by *what has happened* — a request has gone
/// out, an answer has come back — never by how long something took. The gates
/// on the fakes are what makes that possible; nothing below repeats an
/// operation hoping to catch a race.
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
    ///
    /// Three things beyond a plain stub, each because a scenario below cannot
    /// be expressed without it:
    ///
    ///   - **`holdBatchCall(n)`** freezes the *nth* like-status read after it
    ///     has sampled the server, so the answer that comes back is provably
    ///     older than whatever happened while it was held. Per-call, because
    ///     "an older answer arrives after a newer one" needs two reads in
    ///     flight with only one of them stalled.
    ///   - **`neverAnswer`** models a request that goes out and nothing comes
    ///     back — no result, no error. It ends only when the caller cancels it.
    ///   - **reassigning `liked`** lets the same repository answer as a
    ///     different signed-in person, which is what an account switch looks
    ///     like to the model: the repository object does not change, its
    ///     answers do.
    final class Likes: LikeRepository, @unchecked Sendable {
        typealias Gate = (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)

        var liked: Set<String> = []
        var likeResults: [LikeMutationResult] = []
        var unlikeResults: [LikeMutationResult] = []
        var calls: [String] = []
        var batchError: Error?
        private(set) var batchCalls = 0
        /// When set, `like`/`unlike` never return until cancelled.
        var neverAnswer = false

        private var gate: Gate?
        private var batchGates: [Int: Gate] = [:]
        private var never: Gate?

        /// Holds every mutation until `release()`.
        func hold() { gate = AsyncStream<Void>.makeStream() }
        func release() {
            gate?.continuation.finish()
            gate = nil
        }

        /// Holds the nth like-status read — counting from 1 — until released.
        func holdBatchCall(_ n: Int) { batchGates[n] = AsyncStream<Void>.makeStream() }
        func releaseBatchCall(_ n: Int) {
            batchGates[n]?.continuation.finish()
            batchGates[n] = nil
        }

        /// Lets a never-answering call finish, so a test leaves nothing running.
        func stopNeverAnswering() {
            neverAnswer = false
            never?.continuation.finish()
            never = nil
        }

        private func blockUntilCancelled() async {
            if never == nil { never = AsyncStream<Void>.makeStream() }
            guard let never else { return }
            // Iteration ends when the task is cancelled, which is the only way
            // out of a request that is never answered.
            for await _ in never.stream { break }
        }

        func like(postID: String) async throws -> LikeMutationResult {
            calls.append("like")
            if neverAnswer {
                await blockUntilCancelled()
                throw CancellationError()
            }
            if let gate { for await _ in gate.stream { break } }
            return likeResults.isEmpty ? .changed : likeResults.removeFirst()
        }

        func unlike(postID: String) async throws -> LikeMutationResult {
            calls.append("unlike")
            if neverAnswer {
                await blockUntilCancelled()
                throw CancellationError()
            }
            if let gate { for await _ in gate.stream { break } }
            return unlikeResults.isEmpty ? .changed : unlikeResults.removeFirst()
        }

        func likedPostIDs(among postIDs: [String]) async throws -> Set<String> {
            batchCalls += 1
            // Sampled here, before the gate: a read reports the state it saw
            // when it ran, however long it takes to come back. That is what
            // makes a held answer *stale* rather than merely slow.
            let sampled = liked
            let n = batchCalls
            if let held = batchGates[n] { for await _ in held.stream { break } }
            if let batchError { throw batchError }
            return sampled.intersection(postIDs)
        }
    }

    /// Runs the model's own tasks until `condition` holds. No sleeping and no
    /// wall clock.
    static func settle(
        until condition: @MainActor () -> Bool,
        _ what: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("never reached: \(what)", sourceLocation: sourceLocation)
    }

    /// Polls for something the model has to do *on its own initiative*, with an
    /// upper bound. Used only where the property under test is "it gives up
    /// eventually"; every other scenario here is gated, not timed.
    static func happens(
        within seconds: Double,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    static func post(_ id: String = "p", likeCount: Int) -> Post {
        Post(
            id: id, authorID: "u", authorName: "A", authorAvatarURL: nil,
            text: "t", media: [], petID: nil, petName: nil, petAvatarURL: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            likeCount: likeCount, commentCount: 0, tags: []
        )
    }

    // MARK: - Previously found (ed06b7b)

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

    // MARK: - The aggregate carries no provenance

    /// **The limitation, stated as a test.**
    ///
    /// `likeCount` is one integer. It does not say who moved it, so "the count
    /// went up by one" cannot distinguish *our* like being aggregated from *a
    /// stranger's* like being aggregated. When someone else's like lands in the
    /// window between our write and our trigger, this client credits their
    /// movement to us and shows one too few for exactly one read.
    ///
    /// That cannot be fixed here: it is the limit of what the backend contract
    /// lets a client know. What it may not do is persist — the next read after
    /// both triggers have settled has to be right.
    @Test func aStrangersLikeCanAbsorbOursForOneReadAndThenConverges() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 10)]
        let likes = Likes()
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()

        likes.liked = ["p"]
        model.toggleLike(model.posts[0])
        await model.waitForPendingLikes()
        #expect(model.displayLikeCount(for: model.posts[0]) == 11)

        // A stranger likes it too. Their trigger runs first: the aggregate says
        // 11 and ours is still queued. The truth is on its way to 12.
        feed.page = [Self.post(likeCount: 11)]
        await model.reload()
        #expect(
            model.displayLikeCount(for: model.posts[0]) == 11,
            "documented limitation: the movement was theirs, and nothing in the contract says so"
        )

        // Our trigger runs. The server's own number is now the whole truth.
        feed.page = [Self.post(likeCount: 12)]
        await model.reload()
        #expect(
            model.displayLikeCount(for: model.posts[0]) == 12,
            "showed \(model.displayLikeCount(for: model.posts[0])); it has to converge on the server"
        )
    }

    /// The same blindness in the other direction, and this is the dangerous
    /// half: a stranger's *unlike* cancels our like inside the aggregate, so the
    /// count never moves at all and "has it caught up?" can never answer yes.
    /// An unbounded optimistic offset is then kept for the rest of the session
    /// and every reading of that post is one too high.
    ///
    /// Fails against ed06b7b, which showed 11 after three reads and would have
    /// shown 11 after three hundred.
    @Test func aDeltaTheAggregateNeverConfirmsIsGivenUpOn() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 10)]
        let likes = Likes()
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()

        likes.liked = ["p"]
        model.toggleLike(model.posts[0])
        await model.waitForPendingLikes()
        #expect(model.displayLikeCount(for: model.posts[0]) == 11, "optimistic, and rightly so")

        // Our +1 and a stranger's -1 are aggregated together. The count is
        // exactly where it was, and stays there. Our like document is still
        // ours, so the heart is right; the number is not.
        feed.page = [Self.post(likeCount: 10)]
        for _ in 0..<3 { await model.reload() }

        #expect(model.isLiked(Self.post(likeCount: 10)), "the like document is still ours")
        #expect(
            model.displayLikeCount(for: model.posts[0]) == 10,
            """
            showed \(model.displayLikeCount(for: model.posts[0])): an optimistic offset the server \
            never confirmed was kept indefinitely
            """
        )
    }

    // MARK: - Reads that are older than our writes

    /// A like-status read that sampled the server *before* our write must not be
    /// allowed to undo it.
    ///
    /// Pull to refresh, then tap the heart while the refresh is still coming
    /// back: the read answers "not liked", because when it ran that was true.
    /// ed06b7b took that as an external change, voided the confirmed delta, and
    /// — because the tap had already settled, so nothing was in flight — put the
    /// heart back to unfilled under the person's finger.
    @Test func aLikeStatusReadTakenBeforeOurWriteDoesNotUndoIt() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 10)]
        let likes = Likes()
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()

        // The refresh's like-status read samples the server, then stalls.
        likes.holdBatchCall(2)
        async let refreshing: Void = model.reload()
        await Self.settle(until: { likes.batchCalls == 2 }, "the refresh read the like status")

        // The tap happens while it is stalled, and the write lands.
        likes.liked = ["p"]
        model.toggleLike(model.posts[0])
        await model.waitForPendingLikes()
        #expect(model.isLiked(Self.post(likeCount: 10)))

        // Now the stalled read comes back, describing the world as it was
        // before the write.
        likes.releaseBatchCall(2)
        await refreshing

        #expect(
            model.isLiked(Self.post(likeCount: 10)),
            "a read older than our write cleared the heart"
        )
        #expect(
            model.displayLikeCount(for: model.posts[0]) == 11,
            "showed \(model.displayLikeCount(for: model.posts[0])); the write is real and still ours"
        )
    }

    /// The mirror: a read taken before our *unlike* must not put the like back.
    @Test func aLikeStatusReadTakenBeforeOurUnlikeDoesNotRestoreIt() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 10)]
        let likes = Likes()
        likes.liked = ["p"]
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()
        #expect(model.isLiked(Self.post(likeCount: 10)))

        likes.holdBatchCall(2)
        async let refreshing: Void = model.reload()
        await Self.settle(until: { likes.batchCalls == 2 }, "the refresh read the like status")

        likes.liked = []
        model.toggleLike(model.posts[0])   // unlike
        await model.waitForPendingLikes()
        #expect(!model.isLiked(Self.post(likeCount: 10)))

        likes.releaseBatchCall(2)
        await refreshing

        #expect(
            !model.isLiked(Self.post(likeCount: 10)),
            "a read older than our unlike filled the heart back in"
        )
        #expect(
            model.displayLikeCount(for: model.posts[0]) == 9,
            "showed \(model.displayLikeCount(for: model.posts[0]))"
        )
    }

    /// Two refreshes in flight, the older one answering last. The newer answer
    /// is the one that must survive — the generation counter's whole job.
    @Test func anOlderRefreshAnsweringLastDoesNotOverwriteANewerOne() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 10)]
        let likes = Likes()
        likes.liked = ["p"]
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()
        #expect(model.isLiked(Self.post(likeCount: 10)))

        likes.holdBatchCall(2)
        async let stalled: Void = model.reload()
        await Self.settle(until: { likes.batchCalls == 2 }, "the first refresh read the like status")

        // Meanwhile the like is removed elsewhere and a second refresh sees it.
        likes.liked = []
        feed.page = [Self.post(likeCount: 9)]
        await model.reload()
        #expect(!model.isLiked(Self.post(likeCount: 9)), "the second refresh adopted the server")

        // The first refresh's answer — "liked", count 10 — finally arrives.
        likes.releaseBatchCall(2)
        await stalled

        #expect(!model.isLiked(Self.post(likeCount: 9)), "an older answer overwrote a newer one")
        #expect(model.displayLikeCount(for: model.posts[0]) == 9)
    }

    /// A like-status read that fails leaves the heart unknown — but the feed
    /// read that came with it still carried a fresh count, and the optimistic
    /// offset still has to be measured against that.
    ///
    /// ed06b7b threw the whole reconciliation away when the status read failed,
    /// so the baseline stayed behind while the displayed number moved forward:
    /// the confirmed +1 was added on top of a count that already contained it.
    @Test func aFailedStatusReadStillReconcilesTheCountAgainstTheServer() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 10)]
        let likes = Likes()
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()

        likes.liked = ["p"]
        model.toggleLike(model.posts[0])
        await model.waitForPendingLikes()
        #expect(model.displayLikeCount(for: model.posts[0]) == 11)

        // The trigger has run — the server's number now includes our like — and
        // the status read on this refresh fails.
        feed.page = [Self.post(likeCount: 11)]
        likes.batchError = NSError(domain: "test", code: 14)
        await model.reload()

        #expect(
            model.displayLikeCount(for: model.posts[0]) == 11,
            """
            showed \(model.displayLikeCount(for: model.posts[0])): the confirmed offset was added on \
            top of a count that already contains it
            """
        )
    }

    // MARK: - Requests that never come back

    /// A request that goes out and is never answered must not wedge the post.
    ///
    /// In ed06b7b the in-flight counter never came down, so: every later tap on
    /// that post queued behind it forever, every refresh declined to adopt the
    /// server's state because "a tap still owns the intent", and the screen kept
    /// an optimistic like that nothing would ever confirm.
    @Test func aLikeRequestThatIsNeverAnsweredIsGivenUpOn() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 10)]
        let likes = Likes()
        // A deadline short enough to observe. The scenario does not race it:
        // the request under test is never answered at all, so the deadline is
        // the only thing that can settle it.
        let model = FeedViewModel(
            feed: feed, likes: likes, pageSize: 1, likeDeadline: .milliseconds(20)
        )
        await model.loadFirstPageIfNeeded()

        likes.neverAnswer = true
        model.toggleLike(model.posts[0])
        await Self.settle(until: { likes.calls.count == 1 }, "the like request went out")
        #expect(model.isLiked(Self.post(likeCount: 10)), "optimistic while it is in flight")

        let gaveUp = await Self.happens(within: 3) { model.likeFailureMessage != nil }
        likes.stopNeverAnswering()
        await model.waitForPendingLikes()

        #expect(gaveUp, "the request never settled: this post is wedged for the rest of the session")
        #expect(
            !model.isLiked(Self.post(likeCount: 10)),
            "an unconfirmed like was left on screen with nothing left to confirm it"
        )
        #expect(
            model.displayLikeCount(for: model.posts[0]) == 10,
            "showed \(model.displayLikeCount(for: model.posts[0])); nothing is owed for a write we cannot confirm"
        )
    }

    /// And after giving up, the post still works: the next tap is a new request,
    /// not something queued behind a corpse.
    @Test func aPostStillWorksAfterARequestIsAbandoned() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 10)]
        let likes = Likes()
        // A deadline short enough to observe. The scenario does not race it:
        // the request under test is never answered at all, so the deadline is
        // the only thing that can settle it.
        let model = FeedViewModel(
            feed: feed, likes: likes, pageSize: 1, likeDeadline: .milliseconds(20)
        )
        await model.loadFirstPageIfNeeded()

        likes.neverAnswer = true
        model.toggleLike(model.posts[0])
        _ = await Self.happens(within: 3) { model.likeFailureMessage != nil }
        likes.stopNeverAnswering()
        await model.waitForPendingLikes()

        likes.liked = ["p"]
        model.toggleLike(model.posts[0])
        let answered = await Self.happens(within: 3) { likes.calls.count == 2 }
        await model.waitForPendingLikes()

        #expect(answered, "the second tap never reached the repository")
        #expect(model.isLiked(Self.post(likeCount: 10)))
        #expect(model.displayLikeCount(for: model.posts[0]) == 11)
    }

    // MARK: - Interleaving with other people, and with refreshes

    /// Strangers like the post while ours is still in flight. The aggregate ends
    /// up having moved further than our own change alone would explain, and that
    /// is provably far enough: our offset comes off and the server's number is
    /// shown as it stands.
    @Test func strangersLikingWhileOursIsInFlightDoesNotStrandOurOffset() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 10)]
        let likes = Likes()
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()

        likes.hold()
        model.toggleLike(model.posts[0])
        await Self.settle(until: { likes.calls.count == 1 }, "our like went out")
        likes.liked = ["p"]
        likes.release()
        await model.waitForPendingLikes()
        #expect(model.displayLikeCount(for: model.posts[0]) == 11, "10 plus our confirmed like")

        // Two strangers' likes and ours are all aggregated: 10 + 2 + 1.
        feed.page = [Self.post(likeCount: 13)]
        await model.reload()
        #expect(model.isLiked(Self.post(likeCount: 13)))
        #expect(
            model.displayLikeCount(for: model.posts[0]) == 13,
            "showed \(model.displayLikeCount(for: model.posts[0])); the count moved past ours, so ours is in it"
        )
    }

    /// A refresh that completes while a tap is still unanswered keeps the tap's
    /// intent — the person asked for it and nothing has said no yet — but has to
    /// take the server's count underneath it.
    @Test func aRefreshWhileATapIsUnansweredKeepsTheTapsIntent() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 10)]
        let likes = Likes()
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()

        likes.hold()
        model.toggleLike(model.posts[0])
        await Self.settle(until: { likes.calls.count == 1 }, "the like went out")
        #expect(model.displayLikeCount(for: model.posts[0]) == 11)

        // A stranger's like is aggregated in the meantime.
        feed.page = [Self.post(likeCount: 11)]
        await model.reload()
        #expect(model.isLiked(Self.post(likeCount: 11)), "the tap still owns the heart")
        #expect(
            model.displayLikeCount(for: model.posts[0]) == 12,
            "showed \(model.displayLikeCount(for: model.posts[0])); the server's 11 plus our unanswered tap"
        )

        likes.liked = ["p"]
        likes.release()
        await model.waitForPendingLikes()
        feed.page = [Self.post(likeCount: 12)]
        await model.reload()
        #expect(model.displayLikeCount(for: model.posts[0]) == 12)
    }

    /// Five taps with a refresh landing in the middle of them. The person's last
    /// intent wins, and the count agrees with the server once it settles.
    @Test func rapidTapsWithARefreshInTheMiddleSettleOnTheLastIntent() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 10)]
        let likes = Likes()
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()

        likes.hold()
        model.toggleLike(model.posts[0])   // like
        model.toggleLike(model.posts[0])   // unlike
        model.toggleLike(model.posts[0])   // like
        await model.reload()               // mid-flight refresh; server still 10, unliked
        model.toggleLike(model.posts[0])   // unlike
        model.toggleLike(model.posts[0])   // like
        likes.release()
        await model.waitForPendingLikes()

        #expect(likes.calls == ["like", "unlike", "like", "unlike", "like"], "got \(likes.calls)")
        #expect(model.isLiked(Self.post(likeCount: 10)), "an odd number of taps from unliked ends liked")
        #expect(
            model.displayLikeCount(for: model.posts[0]) == 11,
            "showed \(model.displayLikeCount(for: model.posts[0]))"
        )

        // The triggers settle on one net like.
        feed.page = [Self.post(likeCount: 11)]
        likes.liked = ["p"]
        await model.reload()
        #expect(
            model.displayLikeCount(for: model.posts[0]) == 11,
            "showed \(model.displayLikeCount(for: model.posts[0])); the net change must be counted once"
        )
    }

    // MARK: - Account switching

    /// Signing in as somebody else must leave nothing of the previous account
    /// behind — not the rows, not the hearts, and not an optimistic offset.
    ///
    /// The offset is the one that hides. Account A likes a post and its trigger
    /// has not run; account B had already liked the same post, so B's read also
    /// says "liked". Nothing contradicts A's stale offset — same post, same
    /// answer — and B is shown A's +1 on top of a count that already contains
    /// B's own like.
    @Test func switchingAccountsCarriesNothingOver() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 10)]
        let likes = Likes()
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        await model.loadFirstPageIfNeeded()

        // Account A likes it. The trigger has not run: the count is still 10.
        likes.liked = ["p"]
        model.toggleLike(model.posts[0])
        await model.waitForPendingLikes()
        #expect(model.displayLikeCount(for: model.posts[0]) == 11)

        // B signs in. B had already liked this post — that like *is* in the
        // count — and A's is still queued behind the trigger.
        model.prepare(for: "account-B")
        #expect(model.posts.isEmpty, "the previous account's rows are still on screen")
        #expect(model.likedPostIDs.isEmpty, "the previous account's hearts are still filled")

        await model.reload()
        #expect(model.isLiked(Self.post(likeCount: 10)), "B liked it, so B sees it liked")
        #expect(
            model.displayLikeCount(for: model.posts[0]) == 10,
            """
            showed \(model.displayLikeCount(for: model.posts[0])): the previous account's optimistic \
            offset was carried into this one
            """
        )
    }

    /// Preparing for the account that is already signed in is a no-op, so an
    /// incidental re-render cannot throw away the page the person is reading.
    @Test func preparingForTheSameAccountKeepsTheFeed() async {
        let feed = Feed()
        feed.page = [Self.post(likeCount: 10)]
        let likes = Likes()
        likes.liked = ["p"]
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 1)
        model.prepare(for: "account-A")
        await model.loadFirstPageIfNeeded()
        #expect(model.isLiked(Self.post(likeCount: 10)))

        model.prepare(for: "account-A")

        #expect(model.posts.map(\.id) == ["p"], "the feed was thrown away for no reason")
        #expect(model.likedPostIDs == ["p"])
    }
}
