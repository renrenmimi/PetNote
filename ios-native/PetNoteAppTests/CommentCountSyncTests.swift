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
