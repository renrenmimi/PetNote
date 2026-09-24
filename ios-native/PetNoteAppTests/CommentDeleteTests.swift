import FirebaseFunctions
import Foundation
import Testing

@testable import PetNote

/// Deleting a comment from the detail screen, by the rules the web client and
/// `deleteCommentCallable` share: the comment's author and the post's author
/// may, nobody else is offered it, and the list and the count only move once
/// the server has said the comment is gone.
@MainActor
struct CommentDeleteTests {
    private typealias FakeFeed = PostDetailViewModelTests.FakeFeed
    private typealias FakeComments = PostDetailViewModelTests.FakeComments

    /// The post is by "owner"; each comment is by whoever `comment(_:by:)` says.
    private static func post(commentCount: Int) -> Post {
        Post(
            id: "p1", authorID: "owner", authorName: "Owner", authorAvatarURL: nil,
            text: "TEST CONTENT", media: [], petID: nil, petName: nil,
            petAvatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            likeCount: 0, commentCount: commentCount, tags: []
        )
    }

    private static func comment(_ id: String, by author: String, pending: Bool = false) -> PetNote.Comment {
        PetNote.Comment(
            id: id, authorID: author, authorName: author, authorAvatarURL: nil,
            text: "TEST CONTENT \(id)", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            replyTo: nil, isPending: pending
        )
    }

    /// Reported to the feed, the way a written comment is.
    final class Reports: @unchecked Sendable {
        var changes: [(String, Int)] = []
    }

    private func loaded(
        _ comments: FakeComments,
        feed: FakeFeed = FakeFeed(),
        commentCount: Int,
        reports: Reports = Reports()
    ) async -> PostDetailViewModel {
        if feed.post == nil { feed.post = Self.post(commentCount: commentCount) }
        let model = PostDetailViewModel(
            postID: "p1", feed: feed, comments: comments,
            onCommentCountChanged: { reports.changes.append(($0, $1)) }
        )
        await model.load()
        return model
    }

    // MARK: - Who is offered it

    @Test func theCommentsAuthorAndThePostsAuthorAreOfferedItAndNobodyElse() async {
        let comments = FakeComments()
        comments.pages = [[Self.comment("c1", by: "writer")]]
        let model = await loaded(comments, commentCount: 1)
        let written = model.comments[0]

        #expect(model.canDelete(written, viewerID: "writer"))
        #expect(model.canDelete(written, viewerID: "owner"), "the post's author may delete comments on it")
        #expect(!model.canDelete(written, viewerID: "stranger"))
        #expect(!model.canDelete(written, viewerID: nil))
        #expect(!model.canDelete(Self.comment("c2", by: "writer", pending: true), viewerID: "writer"),
                "a comment still being sent has no id the server knows")

        #expect(model.isDeletingAsPostAuthor(written, viewerID: "owner"))
        #expect(!model.isDeletingAsPostAuthor(written, viewerID: "writer"))
        #expect(!model.isDeletingAsPostAuthor(Self.comment("c3", by: "owner"), viewerID: "owner"),
                "the owner deleting their own comment is deleting as its author")
    }

    // MARK: - What a delete does

    @Test func aConfirmedDeleteRemovesTheCommentAndBringsTheCountDownEverywhere() async {
        let comments = FakeComments()
        comments.pages = [[Self.comment("c1", by: "writer"), Self.comment("c2", by: "writer"), Self.comment("c3", by: "x")]]
        let reports = Reports()
        let model = await loaded(comments, commentCount: 3, reports: reports)

        await model.deleteComment(id: "c2")

        #expect(comments.deleteCalls == ["c2"])
        #expect(model.comments.map(\.id) == ["c1", "c3"])
        #expect(model.commentCount == 2)
        #expect(reports.changes.map { $0.0 } == ["p1"] && reports.changes.map { $0.1 } == [-1],
                "the feed was not told: \(reports.changes)")
        #expect(model.deleteFailure == nil)
    }

    /// The count is maintained by `onCommentDeleted`, which runs after the
    /// callable answers. A read of the post in between still says 3; the
    /// screen must not go back to it, and must not count the delete twice
    /// once the trigger has run.
    @Test func aReadFromBeforeTheTriggerDoesNotPutTheNumberBack() async {
        let comments = FakeComments()
        comments.pages = [[Self.comment("c1", by: "writer"), Self.comment("c2", by: "writer"), Self.comment("c3", by: "x")]]
        let feed = FakeFeed()
        let model = await loaded(comments, feed: feed, commentCount: 3)

        await model.deleteComment(id: "c1")
        #expect(model.commentCount == 2)

        feed.post = Self.post(commentCount: 3)   // the trigger has not run
        await model.reloadPost()
        #expect(model.commentCount == 2, "a stale read put the deleted comment back in the count")

        feed.post = Self.post(commentCount: 2)   // now it has
        await model.reloadPost()
        #expect(model.commentCount == 2, "the delete was counted twice")
    }

    @Test func aRefusedDeleteKeepsTheCommentAndSaysWhy() async {
        let comments = FakeComments()
        comments.pages = [[Self.comment("c1", by: "writer")]]
        comments.deleteError = CommentDeleteError.notAllowed
        let reports = Reports()
        let model = await loaded(comments, commentCount: 1, reports: reports)

        await model.deleteComment(id: "c1")

        #expect(model.comments.map(\.id) == ["c1"], "the comment left the list though the server kept it")
        #expect(model.commentCount == 1)
        #expect(reports.changes.isEmpty)
        #expect(model.deleteFailure == "You can't delete this comment.")
    }

    /// Unlike a lost *create*, a lost delete may be tried again: the server
    /// answers success for a comment that is already gone.
    @Test func anUnknownOutcomeKeepsTheCommentAndATryAgainFinishesIt() async {
        let comments = FakeComments()
        comments.pages = [[Self.comment("c1", by: "writer")]]
        comments.deleteError = CommentDeleteError.outcomeUnknown
        let model = await loaded(comments, commentCount: 1)

        await model.deleteComment(id: "c1")
        #expect(model.comments.map(\.id) == ["c1"])
        #expect(model.deleteFailure?.contains("safe") == true, "\(model.deleteFailure ?? "no message")")

        comments.deleteError = nil
        await model.deleteComment(id: "c1")
        #expect(model.comments.isEmpty)
        #expect(model.commentCount == 0, "the count came down more or less than once")
        #expect(model.deleteFailure == nil, "the old failure is still showing after a delete that worked")
    }

    @Test func offlineIsSaidAsOffline() async {
        let comments = FakeComments()
        comments.pages = [[Self.comment("c1", by: "writer")]]
        comments.deleteError = CommentDeleteError.offline
        let model = await loaded(comments, commentCount: 1)

        await model.deleteComment(id: "c1")
        #expect(model.deleteFailure == "You're offline, so the comment wasn't deleted.")
        #expect(model.comments.count == 1)
    }

    /// The row says a delete is on its way, the comment stays until the answer,
    /// and a second tap in the meantime sends nothing.
    @Test func whileADeleteIsOutTheCommentStaysAndASecondTapSendsNothing() async {
        let comments = FakeComments()
        comments.pages = [[Self.comment("c1", by: "writer")]]
        let model = await loaded(comments, commentCount: 1)
        comments.holdDelete()

        let first = Task { await model.deleteComment(id: "c1") }
        #expect(await eventuallyTrue { !comments.deleteCalls.isEmpty }, "the first delete never reached the server")
        #expect(model.deletingCommentIDs == ["c1"])
        #expect(model.comments.map(\.id) == ["c1"], "removed before the server answered")

        await model.deleteComment(id: "c1")
        #expect(comments.deleteCalls == ["c1"], "a second tap sent a second delete")

        comments.releaseDelete()
        await first.value
        #expect(model.deletingCommentIDs.isEmpty)
        #expect(model.comments.isEmpty)
        #expect(model.commentCount == 0)
    }

    @Test func aCommentNotInTheListIsNeverSent() async {
        let comments = FakeComments()
        comments.pages = [[Self.comment("c1", by: "writer")]]
        let model = await loaded(comments, commentCount: 1)

        await model.deleteComment(id: "not-in-the-list")
        #expect(comments.deleteCalls.isEmpty)
    }

    // MARK: - The callable's answers

    @Test func theServersRefusalsBecomeTheRightCase() {
        func mapped(_ code: FunctionsErrorCode, _ message: String) -> CommentDeleteError {
            FirestoreCommentRepository.mapDelete(
                NSError(domain: FunctionsErrorDomain, code: code.rawValue,
                        userInfo: [NSLocalizedDescriptionKey: message])
            )
        }
        #expect(mapped(.permissionDenied, "Cannot delete this comment.") == .notAllowed)
        #expect(mapped(.permissionDenied, "Banned users cannot delete comments.") == .banned)
        #expect(mapped(.unauthenticated, "Must be logged in.") == .notSignedIn)
        #expect(mapped(.resourceExhausted, "Too many requests.") == .rateLimited)
        #expect(FirestoreCommentRepository.mapDelete(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)) == .offline)
        #expect(FirestoreCommentRepository.mapDelete(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)) == .outcomeUnknown)
    }
}
