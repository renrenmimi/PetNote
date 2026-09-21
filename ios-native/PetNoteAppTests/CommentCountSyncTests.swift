import Foundation
import Testing

@testable import PetNote

/// Found on a phone: a comment was written, the detail screen showed it, the
/// server's commentCount was 1 — and going back to the feed still read
/// "0 comments".
///
/// Three explanations had to be told apart, and the backend answered the first
/// one: the trigger had already run. What was left was that the feed's copy of
/// the post was a snapshot taken before the comment existed, and nothing told
/// it otherwise. The detail screen knew; the feed had no channel to hear it.
///
/// The fix is the offset the like path already uses, and these tests exist for
/// the two ways an offset goes wrong: showing nothing, and showing it twice.
@MainActor
struct CommentCountSyncTests {
    private func post(id: String, comments: Int) -> Post {
        Post(
            id: id, authorID: "a", authorName: "A", authorAvatarURL: nil,
            text: "TEST CONTENT \(id)", media: [], petID: nil, petName: nil,
            petAvatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            likeCount: 0, commentCount: comments, tags: []
        )
    }

    /// The same doubles the feed's own tests use, so this exercises the real
    /// paging path rather than a second imitation of it.
    private func loaded(_ posts: [Post]) async -> (FeedViewModel, FeedViewModelTests.FakeFeed) {
        let feed = FeedViewModelTests.FakeFeed()
        feed.pages = [posts]
        let m = FeedViewModel(feed: feed, likes: FeedViewModelTests.FakeLikes(), pageSize: 20)
        await m.loadFirstPageIfNeeded()
        return (m, feed)
    }

    /// The symptom, as a test.
    @Test func aConfirmedCommentShowsOnTheFeedImmediately() async {
        let (m, _) = await loaded([post(id: "p1", comments: 0)])
        let p = m.posts[0]
        #expect(m.displayCommentCount(for: p) == 0)

        m.recordCommentChange(postID: "p1", delta: +1)

        // No refresh, no delay: the number is right as soon as the write was
        // confirmed, which is what "come back and see it" means.
        #expect(m.displayCommentCount(for: p) == 1)
    }

    /// The other way to get this wrong, and the reason the offset cannot just
    /// be added and forgotten.
    @Test func theTriggerLandingDoesNotCountTheCommentTwice() async {
        let (m, feed) = await loaded([post(id: "p1", comments: 0)])
        m.recordCommentChange(postID: "p1", delta: +1)
        #expect(m.displayCommentCount(for: m.posts[0]) == 1)

        // The trigger runs; a refresh now sees the server's own 1.
        feed.pages = [[post(id: "p1", comments: 1)]]
        await m.reload()

        // 1, not 2. The offset has to come off when the aggregate arrives.
        #expect(m.displayCommentCount(for: m.posts[0]) == 1)
    }

    /// An offset the server never confirms is given up on rather than kept.
    @Test func anOffsetTheServerNeverConfirmsIsDropped() async {
        let (m, feed) = await loaded([post(id: "p1", comments: 0)])
        m.recordCommentChange(postID: "p1", delta: +1)

        // The server keeps saying 0. After the bounded number of reads the
        // client stops insisting: a number that is briefly wrong and then
        // right is recoverable, one that is quietly wrong forever is not.
        for _ in 0..<4 { await m.reload() }

        #expect(m.displayCommentCount(for: m.posts[0]) == 0)
    }

    /// Somebody else commenting moves the count too, and that must not be read
    /// as "ours landed" in a way that loses a real comment.
    @Test func aCountThatMovedFurtherThanOursStillSettles() async {
        let (m, feed) = await loaded([post(id: "p1", comments: 0)])
        m.recordCommentChange(postID: "p1", delta: +1)

        // Ours plus two from other people.
        feed.pages = [[post(id: "p1", comments: 3)]]
        await m.reload()

        #expect(m.displayCommentCount(for: m.posts[0]) == 3)
    }

    // MARK: - The same gap, one screen further in

    /// The owner found this after the feed was fixed: open a post that says
    /// "2 comments", add one, and it still says 2 — on the detail screen
    /// itself, while the comment sits visibly in the list below it.
    ///
    /// Same cause as the feed's: the number came from a document read before
    /// the comment existed. The list was right the whole time, which is what
    /// made it easy to miss.
    @Test func theDetailScreenCountMovesWhenAommentIsWritten() async {
        let feed = PostDetailViewModelTests.FakeFeed()
        feed.post = post(id: "p1", comments: 2)
        let comments = PostDetailViewModelTests.FakeComments()
        let model = PostDetailViewModel(postID: "p1", feed: feed, comments: comments)
        await model.load()
        #expect(model.commentCount == 2)

        model.draft = "TEST CONTENT one more"
        await model.send(authorID: "a", authorName: "A")

        #expect(model.commentCount == 3)
    }

    /// And when the post is read again, the server's own number takes over
    /// rather than being added to.
    @Test func theDetailScreenDoesNotCountItTwiceAfterTheTriggerLands() async {
        let feed = PostDetailViewModelTests.FakeFeed()
        feed.post = post(id: "p1", comments: 2)
        let comments = PostDetailViewModelTests.FakeComments()
        let model = PostDetailViewModel(postID: "p1", feed: feed, comments: comments)
        await model.load()
        model.draft = "TEST CONTENT one more"
        await model.send(authorID: "a", authorName: "A")
        #expect(model.commentCount == 3)

        feed.post = post(id: "p1", comments: 3)
        await model.load()

        #expect(model.commentCount == 3)
    }
}

// MARK: - Independent review: the interleavings, built from controlled timing
//
// Every test below fixes the order of events itself — with
// `FakeFeed.whileInFlight` (which runs inside an open read) and with
// `waitForPendingWork()` / `waitForPendingLikes()` — rather than sleeping for
// a duration and hoping. Nothing here repeats an operation until it happens to
// race; if a test passes, it passes because that interleaving was constructed,
// not because it was sampled.
//
// The two questions these were written to answer:
//
//   1. a movement in `commentCount` does not say *whose* comment moved it, so
//      "the number went up" is not evidence that our own write is in it;
//   2. a read can be older than our write, or simply taken before the trigger
//      ran, and treating either as "the aggregate declined to confirm us" is
//      how a correct offset gets thrown away.
@MainActor
struct CommentCountInterleavingTests {
    private static func post(id: String, comments: Int, likes: Int = 0) -> Post {
        Post(
            id: id, authorID: "a", authorName: "A", authorAvatarURL: nil,
            text: "TEST CONTENT \(id)", media: [], petID: nil, petName: nil,
            petAvatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            likeCount: likes, commentCount: comments, tags: []
        )
    }

    private func feedLoaded(
        _ posts: [Post], likes: FeedViewModelTests.FakeLikes = .init()
    ) async -> (FeedViewModel, FeedViewModelTests.FakeFeed) {
        let feed = FeedViewModelTests.FakeFeed()
        feed.pages = [posts]
        let model = FeedViewModel(feed: feed, likes: likes, pageSize: 20)
        await model.loadFirstPageIfNeeded()
        return (model, feed)
    }

    private func detail(
        on post: Post, comments: PostDetailViewModelTests.FakeComments = .init(),
        reporting: ((String, Int) -> Void)? = nil
    ) async -> (PostDetailViewModel, PostDetailViewModelTests.FakeFeed) {
        let feed = PostDetailViewModelTests.FakeFeed()
        feed.post = post
        let model = PostDetailViewModel(
            postID: post.id, feed: feed, comments: comments,
            onCommentCountChanged: reporting
        )
        await model.load()
        return (model, feed)
    }

    // MARK: - 1 + 3: the trigger is slow, and it arrives one comment at a time

    /// Two comments, then straight back to the feed, then the aggregate
    /// catches up **one invocation at a time** — which is what two separate
    /// trigger runs actually look like.
    ///
    /// The all-or-nothing test ("has the count moved at least as far as we are
    /// owed?") answers no to a count that has moved half way, while the
    /// baseline it measures against is re-based on that same read. The half
    /// that did arrive is then counted twice: once in the server's own number
    /// and once in an offset nothing reduced.
    @Test func aTriggerThatArrivesOneCommentAtATimeNeverInflatesTheCount() async {
        let (m, feed) = await feedLoaded([Self.post(id: "p1", comments: 5)])
        m.recordCommentChange(postID: "p1", delta: +1)
        m.recordCommentChange(postID: "p1", delta: +1)
        #expect(m.displayCommentCount(for: m.posts[0]) == 7, "two confirmed writes, no read yet")

        feed.pages = [[Self.post(id: "p1", comments: 6)]]
        await m.reload()
        #expect(
            m.displayCommentCount(for: m.posts[0]) == 7,
            "half the offset arrived and was counted twice: \(m.displayCommentCount(for: m.posts[0]))"
        )

        feed.pages = [[Self.post(id: "p1", comments: 7)]]
        await m.reload()
        #expect(
            m.displayCommentCount(for: m.posts[0]) == 7,
            "got \(m.displayCommentCount(for: m.posts[0]))"
        )
    }

    /// The same shape on the detail screen, which reached it a different way:
    /// there, *any* difference between the count it last saw and the count it
    /// just read threw the whole offset away.
    @Test func theDetailScreenKeepsTheHalfOfTheOffsetTheAggregateStillOwesIt() async {
        let comments = PostDetailViewModelTests.FakeComments()
        let (model, feed) = await detail(on: Self.post(id: "p1", comments: 2), comments: comments)

        model.draft = "TEST CONTENT one"
        await model.send(authorID: "a", authorName: "A")
        model.draft = "TEST CONTENT two"
        await model.send(authorID: "a", authorName: "A")
        #expect(model.commentCount == 4)

        // One of the two triggers has run.
        feed.post = Self.post(id: "p1", comments: 3)
        await model.load()

        #expect(model.commentCount == 4, "the second comment was dropped: \(model.commentCount)")
    }

    // MARK: - 9 + 1: a read that is older than the write

    /// A refresh that was already open when the comment was confirmed is
    /// holding a page sampled *before* the write. It cannot contain it, so it
    /// is not evidence that the aggregate declined to catch up — and it must
    /// not spend one of the three chances the offset gets.
    ///
    /// The like path has had this guard since `writeSequence` was added. The
    /// comment path never got one, so a person who pulls to refresh while
    /// their comment is being written loses a read they never had.
    @Test func aReadTakenBeforeTheWriteDoesNotSpendTheOffsetsBudget() async {
        let (m, feed) = await feedLoaded([Self.post(id: "p1", comments: 0)])

        feed.whileInFlight = { @MainActor @Sendable in
            m.recordCommentChange(postID: "p1", delta: +1)
        }
        await m.reload()
        #expect(m.displayCommentCount(for: m.posts[0]) == 1)

        // Two further refreshes, both taken after the write, both still ahead
        // of the trigger. Those are real chances the aggregate had and missed,
        // and two is inside the budget of three.
        await m.reload()
        await m.reload()

        #expect(
            m.displayCommentCount(for: m.posts[0]) == 1,
            "a confirmed comment vanished from the count: \(m.displayCommentCount(for: m.posts[0]))"
        )
    }

    /// Out of order: refresh A is open, refresh B runs to completion inside
    /// it with the trigger landed, and A then answers with the older number.
    /// A's answer describes a list that no longer exists and is dropped whole.
    @Test func aLateAnswerFromAnOlderRefreshIsNotAppliedAtAll() async {
        let (m, feed) = await feedLoaded([Self.post(id: "p1", comments: 0)])
        m.recordCommentChange(postID: "p1", delta: +1)

        let afterTheTrigger = Self.post(id: "p1", comments: 1)
        feed.whileInFlight = { @MainActor @Sendable in
            feed.pages = [[afterTheTrigger]]
            await m.reload()
        }
        await m.reload()

        #expect(m.posts[0].commentCount == 1, "the newer read is the one that stuck")
        #expect(m.displayCommentCount(for: m.posts[0]) == 1, "and it is not counted twice")
    }

    // MARK: - 2: somebody else is writing at the same time

    /// The first of the two doubts, stated as a test rather than argued.
    ///
    /// `commentCount` is one integer with no provenance. A stranger's comment
    /// landing before ours moves it by exactly as much as ours would have, so
    /// the client credits their write to us and stops holding our offset — and
    /// for that one read it shows one fewer than the truth. It recovers on the
    /// next read. **This is a boundary of the backend contract, not a bug the
    /// client can fix**: nothing exposed says whose write moved the number.
    @Test func aStrangersCommentIsCreditedToOursForOneReadAndThenSelfCorrects() async {
        let (m, feed) = await feedLoaded([Self.post(id: "p1", comments: 0)])
        m.recordCommentChange(postID: "p1", delta: +1)

        // Their comment's trigger runs first; ours has not.
        feed.pages = [[Self.post(id: "p1", comments: 1)]]
        await m.reload()
        #expect(
            m.displayCommentCount(for: m.posts[0]) == 1,
            "documented under-report: the truth is 2 and nothing on the wire says so"
        )

        // Ours lands too.
        feed.pages = [[Self.post(id: "p1", comments: 2)]]
        await m.reload()
        #expect(m.displayCommentCount(for: m.posts[0]) == 2, "no permanent drift, no double count")
    }

    /// The second doubt: every read is an old value, and it stays old because
    /// a stranger's delete cancelled our comment. "Has it caught up?" can then
    /// never answer yes, so an unbounded offset would be wrong on every reading
    /// of that post for the rest of the session.
    ///
    /// The feed bounds that at three reads. The detail screen did not bound it
    /// at all: its only rule was "drop it if the number changed", and a number
    /// that never changes never triggered it.
    @Test func anOffsetTheAggregateCanNeverConfirmIsGivenUpOnBothScreens() async {
        let (m, feed) = await feedLoaded([Self.post(id: "p1", comments: 2)])
        m.recordCommentChange(postID: "p1", delta: +1)
        feed.pages = [[Self.post(id: "p1", comments: 2)]]
        for _ in 0..<4 { await m.reload() }
        #expect(m.displayCommentCount(for: m.posts[0]) == 2, "the feed still insists")

        let comments = PostDetailViewModelTests.FakeComments()
        let (model, detailFeed) = await detail(on: Self.post(id: "p1", comments: 2), comments: comments)
        model.draft = "TEST CONTENT one"
        await model.send(authorID: "a", authorName: "A")
        #expect(model.commentCount == 3)

        detailFeed.post = Self.post(id: "p1", comments: 2)
        for _ in 0..<4 { await model.load() }
        #expect(model.commentCount == 2, "the detail screen held it forever: \(model.commentCount)")
    }

    // MARK: - 5: the server accepted it but we never heard

    /// An unknown outcome that turns out to have landed is a **confirmed
    /// write** — the client went and looked. It has to reach the count on both
    /// screens, and it must reach it by looking, never by sending again:
    /// `createCommentCallable` has no idempotency key.
    @Test func aCommentFoundAfterAnUnknownOutcomeIsCountedOnBothScreens() async {
        let (m, _) = await feedLoaded([Self.post(id: "p1", comments: 2)])
        let comments = PostDetailViewModelTests.FakeComments()
        comments.createError = CommentError.outcomeUnknown
        let (model, _) = await detail(
            on: Self.post(id: "p1", comments: 2), comments: comments,
            reporting: { id, delta in m.recordCommentChange(postID: id, delta: delta) }
        )

        comments.planLandedComment(
            PetNote.Comment(
                id: "server-1", authorID: "a", authorName: "A", authorAvatarURL: nil,
                text: "TEST CONTENT one", createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                replyTo: nil, isPending: false
            )
        )

        model.draft = "TEST CONTENT one"
        await model.send(authorID: "a", authorName: "A")
        await model.waitForPendingWork()

        #expect(comments.createCalls.count == 1, "looking is a read; nothing is ever resent")
        #expect(model.sendFailure?.tone == .resolved)
        #expect(model.comments.contains { $0.id == "server-1" })
        #expect(model.commentCount == 3, "the detail count ignored a write it proved exists")
        #expect(
            m.displayCommentCount(for: m.posts[0]) == 3,
            "and the feed was never told: \(m.displayCommentCount(for: m.posts[0]))"
        )
    }

    /// The other half: unknown, and it did **not** land. Nothing is counted,
    /// nothing is resent, and only now is sending again offered.
    @Test func anUnknownOutcomeThatDidNotLandCountsNothingAndResendsNothing() async {
        let (m, _) = await feedLoaded([Self.post(id: "p1", comments: 2)])
        let comments = PostDetailViewModelTests.FakeComments()
        comments.createError = CommentError.outcomeUnknown
        let (model, _) = await detail(
            on: Self.post(id: "p1", comments: 2), comments: comments,
            reporting: { id, delta in m.recordCommentChange(postID: id, delta: delta) }
        )

        model.draft = "TEST CONTENT one"
        await model.send(authorID: "a", authorName: "A")
        await model.waitForPendingWork()

        #expect(comments.createCalls.count == 1)
        #expect(model.sendFailure?.canRetry == true)
        #expect(model.commentCount == 2)
        #expect(m.displayCommentCount(for: m.posts[0]) == 2)
    }

    // MARK: - 4: paging interleaved with a write

    /// Page 2 said nothing about a post on page 1, so it is not a read that
    /// can confirm or deny page 1's offset.
    @Test func pagingDoesNotReconcileAPostItDidNotReRead() async {
        let feed = FeedViewModelTests.FakeFeed()
        feed.pages = [[Self.post(id: "p1", comments: 0)], [Self.post(id: "p2", comments: 0)]]
        let m = FeedViewModel(feed: feed, likes: FeedViewModelTests.FakeLikes(), pageSize: 1)
        await m.loadFirstPageIfNeeded()
        m.recordCommentChange(postID: "p1", delta: +1)

        await m.loadMoreIfNeeded(currentItem: m.posts.last)

        #expect(m.posts.map(\.id) == ["p1", "p2"])
        #expect(m.displayCommentCount(for: m.posts[0]) == 1)
    }

    // MARK: - 6: offline, then the network comes back

    /// A refresh that failed is not a reading of the aggregate. It must not
    /// spend the budget, and what is on screen has to stay right across it.
    @Test func refreshesThatFailedSayNothingAboutTheAggregate() async {
        let (m, feed) = await feedLoaded([Self.post(id: "p1", comments: 0)])
        m.recordCommentChange(postID: "p1", delta: +1)

        feed.error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        for _ in 0..<4 { await m.reload() }
        #expect(m.state == .failed(.offline))
        #expect(m.displayCommentCount(for: m.posts[0]) == 1, "still ours to show")

        feed.error = nil
        feed.pages = [[Self.post(id: "p1", comments: 1)]]
        await m.reload()
        #expect(m.displayCommentCount(for: m.posts[0]) == 1, "and not counted twice on recovery")
    }

    // MARK: - 7: a different person signs in

    /// The view keeps its `@State` across a change of user, so this is the
    /// same model object. The next person must be shown the server's number,
    /// not an offset the last person's trigger had not caught up with — and
    /// nothing contradicts that offset, because the post and its count look
    /// exactly the same to both accounts.
    @Test func switchingAccountDoesNotCarryTheCommentOffsetOver() async {
        let (m, _) = await feedLoaded([Self.post(id: "p1", comments: 0)])
        m.recordCommentChange(postID: "p1", delta: +1)
        #expect(m.displayCommentCount(for: m.posts[0]) == 1)

        m.prepare(for: "somebody-else")
        await m.loadFirstPageIfNeeded()

        #expect(
            m.displayCommentCount(for: m.posts[0]) == 0,
            "the next account was shown the last one's pending comment"
        )
    }

    // MARK: - 8: the feed and the detail screen hold the same post

    /// Two offsets evolving side by side against two separate reads. Neither
    /// may double count, and when both have reconciled they must agree.
    @Test func theFeedAndTheDetailScreenEachKeepTheirOwnOffsetAndAgreeInTheEnd() async {
        let (m, feedFake) = await feedLoaded([Self.post(id: "p1", comments: 2)])
        let comments = PostDetailViewModelTests.FakeComments()
        let (model, detailFeed) = await detail(
            on: Self.post(id: "p1", comments: 2), comments: comments,
            reporting: { id, delta in m.recordCommentChange(postID: id, delta: delta) }
        )

        model.draft = "TEST CONTENT one"
        await model.send(authorID: "a", authorName: "A")
        #expect(model.commentCount == 3)
        #expect(m.displayCommentCount(for: m.posts[0]) == 3, "the screen underneath is already right")

        // The trigger lands. The two screens read it independently.
        detailFeed.post = Self.post(id: "p1", comments: 3)
        await model.load()
        feedFake.pages = [[Self.post(id: "p1", comments: 3)]]
        await m.reload()

        #expect(model.commentCount == 3)
        #expect(m.displayCommentCount(for: m.posts[0]) == 3)
    }

    /// The two screens run separate implementations of the same rule. This
    /// drives both through the identical sequence and requires the same
    /// answer at every step — which is the thing that actually stops them
    /// drifting apart again, and is cheaper than merging them.
    @Test(arguments: [
        // (what the aggregate reports on each successive read, expected shown)
        ([2, 2, 2, 2], [3, 3, 2, 2]),   // never confirms: held, then given up on
        ([3, 3], [3, 3]),               // confirmed on the first read
        ([2, 3], [3, 3]),               // confirmed on the second
    ])
    func bothScreensAnswerTheSameWayForTheSameSequenceOfReads(
        _ readsAndExpected: ([Int], [Int])
    ) async {
        let (reads, expected) = readsAndExpected

        let (m, feed) = await feedLoaded([Self.post(id: "p1", comments: 2)])
        m.recordCommentChange(postID: "p1", delta: +1)

        let comments = PostDetailViewModelTests.FakeComments()
        let (model, detailFeed) = await detail(on: Self.post(id: "p1", comments: 2), comments: comments)
        model.draft = "TEST CONTENT one"
        await model.send(authorID: "a", authorName: "A")

        var fromFeed: [Int] = []
        var fromDetail: [Int] = []
        for count in reads {
            feed.pages = [[Self.post(id: "p1", comments: count)]]
            await m.reload()
            fromFeed.append(m.displayCommentCount(for: m.posts[0]))

            detailFeed.post = Self.post(id: "p1", comments: count)
            await model.load()
            fromDetail.append(model.commentCount)
        }

        #expect(fromFeed == expected, "feed: \(fromFeed)")
        #expect(fromDetail == expected, "detail: \(fromDetail)")
    }

    // MARK: - 10: the post goes away after the read

    /// A like write is how this client finds out the post is gone. The row is
    /// dropped and its like state with it; the comment offset was left behind,
    /// so if that id is ever served again it arrives carrying a pending
    /// comment from a post that no longer exists.
    @Test func aPostThatVanishedDoesNotLeaveItsCommentOffsetBehind() async {
        let likes = FeedViewModelTests.FakeLikes()
        likes.likeResult = .postNotFound
        let (m, feed) = await feedLoaded([Self.post(id: "p1", comments: 0)], likes: likes)
        m.recordCommentChange(postID: "p1", delta: +1)

        m.toggleLike(m.posts[0])
        await m.waitForPendingLikes()
        #expect(m.posts.isEmpty)

        feed.pages = [[Self.post(id: "p1", comments: 0)]]
        await m.reload()

        #expect(
            m.displayCommentCount(for: m.posts[0]) == 0,
            "a stranded offset came back with the row: \(m.displayCommentCount(for: m.posts[0]))"
        )
    }
}
