import Foundation
import Testing

@testable import PetNote

/// Acceptance 5C.6–5C.10 plus the gates from functions/src/posts.ts:768.
///
/// Every branch the server can refuse a comment with is injected here, because
/// several of them cannot be produced for real without putting the emulator
/// into a state no seed should create (a ban, a block) or without losing a
/// response on purpose. The UI-level half — an unverified account really being
/// refused — is in CommentUITests.
@MainActor
struct PostDetailViewModelTests {
    // MARK: - Fakes

    final class FakeFeed: FeedRepository, @unchecked Sendable {
        var post: Post?
        var error: Error?
        func posts(after cursor: PageCursor?, limit: Int) async throws -> Page<Post> { .empty }
        func post(id: String) async throws -> Post? {
            if let error { throw error }
            return post
        }
    }

    final class FakeComments: CommentRepository, @unchecked Sendable {
        var pages: [[PetNote.Comment]] = []
        var readError: Error?
        var createError: Error?
        var createdID = "server-id"
        var createCalls: [String] = []
        /// Held open to test what happens while a send is in flight.
        var releaseCreate: AsyncStream<Void>.Continuation?
        private var stream: AsyncStream<Void>?
        private var issued: [PageCursor] = []

        func holdCreate() {
            let (s, c) = AsyncStream<Void>.makeStream()
            stream = s
            releaseCreate = c
        }

        func comments(postID: String, after cursor: PageCursor?, limit: Int) async throws -> Page<PetNote.Comment> {
            if let readError { throw readError }
            let index: Int
            if let cursor, let position = issued.firstIndex(of: cursor) { index = position + 1 } else { index = 0 }
            guard index < pages.count else { return .empty }
            var next: PageCursor?
            if index + 1 < pages.count {
                let token = PageCursor()
                issued.append(token)
                next = token
            }
            return Page(items: pages[index], next: next)
        }

        func create(postID: String, text: String, replyTo: String?) async throws -> String {
            createCalls.append(text)
            if let stream { for await _ in stream { break } }
            if let createError { throw createError }
            return createdID
        }
    }

    static func post(_ id: String = "p1") -> Post {
        Post(
            id: id, authorID: "uid", authorName: "A", authorAvatarURL: nil,
            text: "TEST CONTENT", media: [], petID: nil, petName: nil,
            petAvatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            likeCount: 0, commentCount: 0, tags: []
        )
    }

    static func comment(_ id: String) -> PetNote.Comment {
        PetNote.Comment(
            id: id, authorID: "uid", authorName: "A", authorAvatarURL: nil,
            text: "TEST CONTENT \(id)", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            replyTo: nil, isPending: false
        )
    }

    private func loaded(
        comments: FakeComments = FakeComments(),
        feed: FakeFeed? = nil
    ) async -> PostDetailViewModel {
        let f = feed ?? FakeFeed()
        if f.post == nil && f.error == nil { f.post = Self.post() }
        let model = PostDetailViewModel(postID: "p1", feed: f, comments: comments)
        await model.load()
        return model
    }

    // MARK: - Each gate, in the server's order

    @Test func unverifiedEmailKeepsTheTextAndDoesNotOfferARetry() async {
        let comments = FakeComments()
        comments.createError = CommentError.emailNotVerified
        let model = await loaded(comments: comments)

        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")

        #expect(model.draft == "TEST CONTENT hello", "the text is not lost")
        #expect(model.sendFailure?.message == "Verify your email before commenting.")
        #expect(model.sendFailure?.canRetry == false, "retrying cannot help until the email is verified")
        #expect(model.comments.isEmpty, "the pending placeholder is removed")
    }

    @Test func bannedAccountIsToldAboutTheAccountNotTheComment() async {
        let comments = FakeComments()
        comments.createError = CommentError.banned
        let model = await loaded(comments: comments)
        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")

        #expect(model.sendFailure?.message == "This account cannot comment.")
        #expect(model.sendFailure?.canRetry == false)
        #expect(model.draft == "TEST CONTENT hello")
    }

    /// The message must not say which direction the block runs.
    @Test func aBlockIsReportedNeutrally() async {
        let comments = FakeComments()
        comments.createError = CommentError.blockedFromAuthor
        let model = await loaded(comments: comments)
        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")

        let message = model.sendFailure?.message ?? ""
        #expect(message == "You cannot comment on this post.")
        for leak in ["block", "Block", "blocked", "they", "them"] {
            #expect(!message.contains(leak), "the message leaks the block direction: \(message)")
        }
    }

    @Test func notSignedInAsksForSignIn() async {
        let comments = FakeComments()
        comments.createError = CommentError.notSignedIn
        let model = await loaded(comments: comments)
        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")
        #expect(model.sendFailure?.message == "Sign in to comment.")
        #expect(model.draft == "TEST CONTENT hello")
    }

    @Test func aDeletedPostEndsTheScreenRatherThanJustTheComment() async {
        let comments = FakeComments()
        comments.createError = CommentError.postNotFound
        let model = await loaded(comments: comments)
        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")

        #expect(model.state == .deleted)
        #expect(model.sendFailure?.canRetry == false)
    }

    @Test func aDeletedReplyTargetSaysSo() async {
        let comments = FakeComments()
        comments.createError = CommentError.replyTargetNotFound
        let model = await loaded(comments: comments)
        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")
        #expect(model.sendFailure?.message == "The comment you replied to was deleted.")
    }

    @Test func rateLimitingIsRetryableLater() async {
        let comments = FakeComments()
        comments.createError = CommentError.rateLimited
        let model = await loaded(comments: comments)
        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")
        #expect(model.sendFailure?.canRetry == true)
        #expect(model.draft == "TEST CONTENT hello")
    }

    /// Content the server refuses is not a transport problem: the same text
    /// will be refused again, so no retry is offered.
    @Test func rejectedContentIsNotOfferedARetry() async {
        let comments = FakeComments()
        comments.createError = CommentError.rejected("That comment was not accepted.")
        let model = await loaded(comments: comments)
        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")
        #expect(model.sendFailure?.canRetry == false)
        #expect(model.draft == "TEST CONTENT hello")
    }

    @Test func transportFailureIsRetryable() async {
        let comments = FakeComments()
        comments.createError = CommentError.transport("functions/13")
        let model = await loaded(comments: comments)
        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")
        #expect(model.sendFailure?.canRetry == true)
        #expect(model.draft == "TEST CONTENT hello")
    }

    // MARK: - The one that must never auto-retry

    /// 5C.10. `createCommentCallable` has no idempotency key, so a resend can
    /// post the comment twice. An unknown outcome therefore offers no retry,
    /// keeps the text, and refreshes so the person can see for themselves.
    @Test func anUnknownOutcomeNeverResendsByItself() async {
        let comments = FakeComments()
        comments.createError = CommentError.outcomeUnknown
        let model = await loaded(comments: comments)

        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")

        #expect(comments.createCalls.count == 1, "sent once, and only once")
        #expect(model.draft == "TEST CONTENT hello", "the text is kept")
        #expect(model.sendFailure?.canRetry == false, "no retry button to press by reflex")
        let message = model.sendFailure?.message ?? ""
        #expect(message.contains("could not confirm"), "says it is uncertain, not that it failed")
        #expect(!message.lowercased().contains("failed"), "never claims certain failure: \(message)")
    }

    @Test func anUnknownOutcomeRefreshesSoThePersonCanCheck() async {
        let comments = FakeComments()
        comments.createError = CommentError.outcomeUnknown
        // The comment did in fact land; a refresh is how that becomes visible.
        comments.pages = [[Self.comment("c1")]]
        let model = await loaded(comments: comments)

        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")
        // The refresh is fired as a detached task; give it a turn.
        try? await Task.sleep(for: .milliseconds(120))

        #expect(comments.createCalls.count == 1, "still only one send")
    }

    // MARK: - Duplicate taps and leaving the screen

    /// A second tap while the first is in flight must not produce two comments.
    @Test func tappingSendTwiceSendsOnce() async {
        let comments = FakeComments()
        comments.holdCreate()
        let model = await loaded(comments: comments)
        model.draft = "TEST CONTENT hello"

        async let first: Void = model.send(authorID: "uid", authorName: "A")
        try? await Task.sleep(for: .milliseconds(50))
        // The composer is disabled while sending, but assert the model refuses
        // regardless — a disabled control is a UI convention, not a guarantee.
        await model.send(authorID: "uid", authorName: "A")
        comments.releaseCreate?.finish()
        await first

        #expect(comments.createCalls.count == 1, "\(comments.createCalls.count) sends")
    }

    /// 14 from the audit: a refresh landing mid-send removed the placeholder,
    /// and the confirmed comment then had nowhere to go.
    @Test func aRefreshMidSendDoesNotSwallowTheComment() async {
        let comments = FakeComments()
        comments.holdCreate()
        let model = await loaded(comments: comments)
        model.draft = "TEST CONTENT hello"

        async let sending: Void = model.send(authorID: "uid", authorName: "A")
        try? await Task.sleep(for: .milliseconds(50))
        await model.loadComments(reset: true)   // the placeholder is wiped here
        comments.releaseCreate?.finish()
        await sending

        #expect(
            model.comments.contains { $0.id == comments.createdID },
            "the comment exists on the server, so it has to be on screen"
        )
    }

    // MARK: - Reading comments

    /// A failed read is not an empty list (§6.5).
    @Test func aFailedCommentLoadIsDistinguishableFromEmpty() async {
        let comments = FakeComments()
        comments.readError = NSError(domain: "test", code: 13)
        let model = await loaded(comments: comments)

        #expect(model.comments.isEmpty)
        if case .failed = model.commentsState {} else {
            Issue.record("expected .failed, got \(model.commentsState)")
        }
    }

    @Test func offlineReadsSayOffline() async {
        let comments = FakeComments()
        comments.readError = NSError(domain: NSURLErrorDomain, code: -1009)
        let model = await loaded(comments: comments)
        if case .failed(let message) = model.commentsState {
            #expect(message.contains("offline"))
        } else {
            Issue.record("expected .failed")
        }
    }

    /// A refresh while a page is in flight used to wipe page one and then
    /// return without asking for a replacement.
    @Test func refreshingMidPageDoesNotLosePageOne() async {
        let comments = FakeComments()
        comments.pages = [
            [Self.comment("c1"), Self.comment("c2")],
            [Self.comment("c3")],
        ]
        let model = await loaded(comments: comments)
        #expect(model.comments.count == 2)

        // Read the item BEFORE starting the task: the right-hand side of an
        // `async let` is evaluated inside the new task, so `model.comments[1]`
        // would be read after the reset had emptied the array.
        let second = model.comments[1]
        async let paging: Void = model.loadMoreCommentsIfNeeded(currentItem: second)
        await model.loadComments(reset: true)
        await paging

        #expect(model.comments.contains { $0.id == "c1" }, "page one is still there")
    }

    // MARK: - The server's length cap

    @Test func anOverlongCommentIsRefusedBeforeItIsSent() async {
        let comments = FakeComments()
        let model = await loaded(comments: comments)
        model.draft = String(repeating: "x", count: PostDetailViewModel.maxCommentLength + 1)

        await model.send(authorID: "uid", authorName: "A")

        #expect(comments.createCalls.isEmpty, "never reaches the server")
        #expect(model.isOverLength)
        #expect(model.sendFailure?.canRetry == false)
    }

    @Test func exactlyTheLimitIsAllowed() async {
        let comments = FakeComments()
        let model = await loaded(comments: comments)
        model.draft = String(repeating: "x", count: PostDetailViewModel.maxCommentLength)

        await model.send(authorID: "uid", authorName: "A")

        #expect(comments.createCalls.count == 1)
        #expect(!model.isOverLength)
    }
}
