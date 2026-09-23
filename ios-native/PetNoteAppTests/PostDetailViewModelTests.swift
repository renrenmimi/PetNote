import Foundation
import FirebaseFunctions
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
        fileprivate var issued: [PageCursor] = []
        /// Every cursor a read was asked for, in order. A skipped page and a
        /// repeated one both look correct in `comments` alone if the fake
        /// answers consistently; this is what tells them apart.
        var cursorsRequested: [PageCursor?] = []

        /// Runs at the very start of a read, before `readError` is consulted.
        ///
        /// The same window `FeedViewModelTests.FakeFeed.beforeAnswering`
        /// opens, for the same reason: what the screen is holding while a read
        /// that is going to fail is still out cannot be sampled after it.
        /// One-shot.
        var beforeAnswering: (@Sendable () async -> Void)?
        /// Runs after the page has been chosen and before it is handed back,
        /// so a second refresh can overtake this one and the page this read
        /// returns is genuinely the one it sampled first. One-shot.
        var whileInFlight: (@Sendable () async -> Void)?

        func holdCreate() {
            let (s, c) = AsyncStream<Void>.makeStream()
            stream = s
            releaseCreate = c
        }

        func comments(postID: String, after cursor: PageCursor?, limit: Int) async throws -> Page<PetNote.Comment> {
            cursorsRequested.append(cursor)
            if let hook = beforeAnswering {
                beforeAnswering = nil
                await hook()
            }
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
            let page = Page(items: pages[index], next: next)
            if let hook = whileInFlight {
                whileInFlight = nil
                await hook()
            }
            return page
        }

        func create(postID: String, text: String, replyTo: String?) async throws -> String {
            createCalls.append(text)
            if let stream { for await _ in stream { break } }
            if let createError { throw createError }
            return createdID
        }

        var deleteError: Error?
        var deleteCalls: [String] = []
        private var deleteGate: AsyncStream<Void>?
        private var deleteOpener: AsyncStream<Void>.Continuation?

        /// Holds every delete until `releaseDelete()`.
        func holdDelete() {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            deleteGate = stream
            deleteOpener = continuation
        }

        func releaseDelete() {
            deleteOpener?.finish()
            deleteGate = nil
            deleteOpener = nil
        }

        func delete(postID: String, commentID: String) async throws {
            deleteCalls.append(commentID)
            if let deleteGate { for await _ in deleteGate { break } }
            if let deleteError { throw deleteError }
        }

        /// Makes the *next* read return `pages` as if the write had landed.
        ///
        /// This is the shape of the case that matters: the callable's response
        /// was lost, but the comment is on the server, so a re-read finds it.
        func planLandedComment(_ comment: PetNote.Comment) {
            pages = [[comment]]
            issued.removeAll()
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

    // MARK: - After the author edits the post

    /// The edit was made from this screen, so the screen has to show it — and
    /// must not blank itself or drop the comments to do so.
    @Test func anEditedPostIsReReadWithoutBlankingTheScreen() async {
        let comments = FakeComments()
        comments.pages = [[Self.comment("c1")]]
        let feed = FakeFeed()
        feed.post = Self.post()
        let model = await loaded(comments: comments, feed: feed)
        let readsBefore = comments.cursorsRequested.count

        feed.post = Post(
            id: "p1", authorID: "uid", authorName: "A", authorAvatarURL: nil,
            text: "TEST CONTENT edited", media: [], petID: nil, petName: nil,
            petAvatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            likeCount: 0, commentCount: 1, tags: []
        )
        await model.reloadPost()

        guard case .loaded(let post) = model.state else {
            Issue.record("expected the edited post on screen, got \(model.state)")
            return
        }
        #expect(post.text == "TEST CONTENT edited")
        #expect(model.comments.map(\.id) == ["c1"], "the comments stay")
        #expect(comments.cursorsRequested.count == readsBefore, "the comments are not re-read")
    }

    /// A failed re-read is not a failed edit. The version on screen stays.
    @Test func aFailedReReadKeepsWhatIsOnScreen() async {
        let feed = FakeFeed()
        feed.post = Self.post()
        let model = await loaded(feed: feed)

        feed.error = URLError(.notConnectedToInternet)
        await model.reloadPost()

        guard case .loaded(let post) = model.state else {
            Issue.record("a failed re-read replaced the post with \(model.state)")
            return
        }
        #expect(post.text == "TEST CONTENT")
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

    /// This used to read "Sign in to comment." on a screen the person had
    /// reached *by* signing in — an instruction with nothing on screen to
    /// carry it out with. The refusal now starts a session check instead
    /// (§6.9), and the words say what is happening rather than blaming the
    /// person for a state they are not in.
    @Test func notSignedInDoesNotTellASignedInPersonToSignIn() async {
        let comments = FakeComments()
        comments.createError = CommentError.notSignedIn
        let model = await loaded(comments: comments)
        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")

        let message = model.sendFailure?.message ?? ""
        #expect(!message.lowercased().contains("sign in to"), "dead-end instruction: \(message)")
        #expect(model.sendFailure?.needsReauthentication == true, "the session is what gets asked")
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

    // MARK: - Offline is a certain failure, not an uncertain one

    /// The Functions SDK only rewrites a GTMSessionFetcher status and
    /// NSURLErrorTimedOut into its own domain (Functions.swift
    /// `processedError`); everything else arrives in the original domain. A
    /// plain "not connected" therefore reached the mapper as NSURLErrorDomain
    /// and was reported as an outcome we could not determine — which is the
    /// wrong fact, and the one that costs the person a retry they could safely
    /// have had.
    @Test(arguments: [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorDataNotAllowed,
        NSURLErrorSecureConnectionFailed,
    ])
    func aRequestThatNeverLeftTheDeviceIsACertainFailure(code: Int) {
        let mapped = FirestoreCommentRepository.map(NSError(domain: NSURLErrorDomain, code: code))
        #expect(mapped == .transport(FirestoreCommentRepository.Transport.offline))
    }

    /// The ambiguous ones must stay ambiguous: for these the request may have
    /// been delivered and only the answer lost, and a resend posts twice.
    @Test(arguments: [
        NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut,
        NSURLErrorCancelled,
    ])
    func aRequestThatMayHaveArrivedStaysUnknown(code: Int) {
        let mapped = FirestoreCommentRepository.map(NSError(domain: NSURLErrorDomain, code: code))
        #expect(mapped == .outcomeUnknown, "code \(code) was mapped to \(mapped)")
    }

    @Test func offlineSendsKeepTheTextAndSayOfflineNotFailed() async {
        let comments = FakeComments()
        comments.createError = CommentError.transport(FirestoreCommentRepository.Transport.offline)
        let model = await loaded(comments: comments)
        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")

        let message = model.sendFailure?.message ?? ""
        #expect(message.lowercased().contains("offline"), "got: \(message)")
        #expect(model.sendFailure?.canRetry == true, "nothing was sent, so sending again is safe")
        #expect(model.draft == "TEST CONTENT hello")
        // §6.11: the offline words must not be the server's words.
        #expect(message != "Could not post that comment.")
    }

    @Test func aServerSideTransportFailureUsesDifferentWordsFromOffline() async {
        let offline = FakeComments()
        offline.createError = CommentError.transport(FirestoreCommentRepository.Transport.offline)
        let a = await loaded(comments: offline)
        a.draft = "TEST CONTENT hello"
        await a.send(authorID: "uid", authorName: "A")

        let server = FakeComments()
        server.createError = CommentError.transport("functions/13")
        let b = await loaded(comments: server)
        b.draft = "TEST CONTENT hello"
        await b.send(authorID: "uid", authorName: "A")

        #expect(a.sendFailure?.message != b.sendFailure?.message)
    }

    // MARK: - Settling an unknown outcome, by looking and never by resending

    /// The response was lost but the comment did land. Re-reading finds it, and
    /// the person is told so — because leaving them with "we could not confirm"
    /// and their text still in the box is an invitation to post it twice.
    @Test func anUnknownOutcomeThatLandedIsReportedAsPosted() async {
        let comments = FakeComments()
        comments.createError = CommentError.outcomeUnknown
        let model = await loaded(comments: comments)

        let landed = PetNote.Comment(
            id: "server-1", authorID: "uid", authorName: "A", authorAvatarURL: nil,
            text: "TEST CONTENT hello", createdAt: Date(), replyTo: nil, isPending: false
        )
        comments.planLandedComment(landed)

        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")
        await settle()

        #expect(comments.createCalls.count == 1, "never sent a second time")
        #expect(model.sendFailure?.tone == .resolved)
        #expect(model.sendFailure?.canRetry == false, "there is nothing left to retry")
        #expect(model.draft.isEmpty, "the box is cleared so the obvious next tap is not a duplicate")
        #expect(model.comments.contains { $0.id == "server-1" })
    }

    /// The response was lost and the comment did not land. A fresh read is
    /// authoritative, so now — and only now — sending again is offered.
    @Test func anUnknownOutcomeThatDidNotLandBecomesRetryable() async {
        let comments = FakeComments()
        comments.createError = CommentError.outcomeUnknown
        let model = await loaded(comments: comments)

        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")
        #expect(model.sendFailure?.canRetry == false, "not before we have looked")

        await settle()

        #expect(comments.createCalls.count == 1, "looking is a read; it never resends")
        #expect(model.sendFailure?.canRetry == true, "we looked, it is not there, so it is safe")
        #expect(model.draft == "TEST CONTENT hello")
    }

    /// The check itself failed. We know no more than before, so the words must
    /// not pretend we do and the retry must not be offered.
    @Test func anUnknownOutcomeWeCannotCheckStaysUnknown() async {
        let comments = FakeComments()
        comments.createError = CommentError.outcomeUnknown
        let model = await loaded(comments: comments)
        comments.readError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)

        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")
        await settle()

        #expect(comments.createCalls.count == 1)
        #expect(model.sendFailure?.canRetry == false, "we still do not know")
        let message = model.sendFailure?.message ?? ""
        #expect(message.contains("could not check"), "got: \(message)")
        #expect(model.draft == "TEST CONTENT hello")
    }

    /// A comment that was already on screen before the send must not be
    /// mistaken for the one that just went missing — otherwise sending the same
    /// text twice would always report the second one as having landed.
    @Test func anOlderCommentWithTheSameTextIsNotMistakenForThisOne() async {
        let comments = FakeComments()
        let earlier = PetNote.Comment(
            id: "earlier", authorID: "uid", authorName: "A", authorAvatarURL: nil,
            text: "TEST CONTENT hello", createdAt: Date(), replyTo: nil, isPending: false
        )
        comments.pages = [[earlier]]
        let model = await loaded(comments: comments)
        #expect(model.comments.count == 1)

        comments.createError = CommentError.outcomeUnknown
        comments.planLandedComment(earlier)   // the re-read returns only the old one

        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")
        await settle()

        #expect(model.sendFailure?.tone == .problem, "the old comment is not evidence this one landed")
        #expect(model.sendFailure?.canRetry == true)
        #expect(model.draft == "TEST CONTENT hello")
    }

    /// If the person has started another send while the check was running, the
    /// check's verdict is about a moment that has passed and must not overwrite
    /// what they are doing now.
    @Test func settlingDoesNotStompASendThePersonStartedMeanwhile() async {
        let comments = FakeComments()
        comments.createError = CommentError.outcomeUnknown
        let model = await loaded(comments: comments)

        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")

        // A second send, held open, starts before the check finishes.
        comments.createError = nil
        comments.holdCreate()
        model.draft = "TEST CONTENT second"
        async let second: Void = model.send(authorID: "uid", authorName: "A")
        await settle()
        #expect(model.isSending, "the second send is still in flight")
        comments.releaseCreate?.finish()
        await second

        #expect(comments.createCalls.count == 2, "one per deliberate tap, none from the check")
    }

    // MARK: - An unauthenticated server is a session question, not a sign-in hint

    /// Telling a person who is looking at a signed-in app to "sign in" is a
    /// dead end: there is nothing on that screen to act on. §6.9 wants the
    /// session checked instead, which is what this flag asks the screen to do.
    @Test func anUnauthenticatedRefusalAsksTheSessionRatherThanThePerson() async {
        let comments = FakeComments()
        comments.createError = CommentError.notSignedIn
        let model = await loaded(comments: comments)
        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")

        #expect(model.sendFailure?.needsReauthentication == true)
        #expect(model.draft == "TEST CONTENT hello", "the text survives whatever the session does next")
        #expect(model.sendFailure?.canRetry == false, "retrying the same dead token cannot help")
    }

    @Test func everyOtherRefusalLeavesTheSessionAlone() async {
        for error: CommentError in [
            .emailNotVerified, .banned, .blockedFromAuthor, .rateLimited,
            .rejected("no"), .outcomeUnknown, .transport("functions/13"),
        ] {
            let comments = FakeComments()
            comments.createError = error
            let model = await loaded(comments: comments)
            model.draft = "TEST CONTENT hello"
            await model.send(authorID: "uid", authorName: "A")
            #expect(
                model.sendFailure?.needsReauthentication != true,
                "\(error) must not end anyone's session"
            )
        }
    }

    // MARK: - Paging and refreshing, interleaved

    /// Paging while a refresh is in flight must not append the old page on top
    /// of the new list — the ids would be from a list that no longer exists.
    @Test func pagingThatLandsAfterARefreshIsDiscarded() async {
        let comments = FakeComments()
        comments.pages = [
            [Self.comment("c1"), Self.comment("c2")],
            [Self.comment("c3"), Self.comment("c4")],
        ]
        let model = await loaded(comments: comments)
        #expect(model.comments.count == 2)

        // Read the element BEFORE the task: the right-hand side of an `async
        // let` runs inside the new task, so this would otherwise be read after
        // the reset had emptied the array.
        let second = model.comments[1]
        async let paging: Void = model.loadMoreCommentsIfNeeded(currentItem: second)
        await model.loadComments(reset: true)
        await paging

        let ids = model.comments.map(\.id)
        #expect(Set(ids).count == ids.count, "no duplicates after the interleave: \(ids)")
        #expect(model.comments.contains { $0.id == "c1" }, "page one survived")
    }

    /// A send that lands while a refresh is in flight, and a page arriving on
    /// top of both. The comment must be on screen exactly once.
    @Test func aSendARefreshAndAPageAllAtOnceLeaveOneCopy() async {
        let comments = FakeComments()
        comments.pages = [[Self.comment("c1"), Self.comment("c2")]]
        let model = await loaded(comments: comments)
        comments.holdCreate()
        model.draft = "TEST CONTENT hello"

        async let sending: Void = model.send(authorID: "uid", authorName: "A")
        try? await Task.sleep(for: .milliseconds(40))
        await model.loadComments(reset: true)
        comments.releaseCreate?.finish()
        await sending

        let matches = model.comments.filter { $0.id == comments.createdID }
        #expect(matches.count == 1, "the comment is on screen \(matches.count) times")
    }

    /// Gives the detached settle-after-unknown check a chance to run.
    ///
    /// It is one await against a fake that answers immediately, so this is a
    /// scheduling gap rather than a wait for work — hence yields rather than a
    /// single long sleep.
    private func settle(within seconds: Double = 0.5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            await Task.yield()
        }
    }

    /// A like repository that records order, can be held open, and can be told
    /// never to answer at all.
    ///
    /// No lock: every call is made from the main actor by the model under
    /// test, and `NSLock` is unavailable from an async context anyway.
    final class FakeLikes: LikeRepository, @unchecked Sendable {
        enum Call: Equatable { case like(String); case unlike(String) }

        var calls: [Call] = []

        /// Answers, consumed in order. Anything past the end answers
        /// `.changed`.
        var results: [LikeMutationResult] = []
        var errors: [Int: Error] = [:]
        /// Requests that go out and never come back — the case that wedges a
        /// post forever.
        var neverAnswers = false
        var likedIDs: Set<String> = []
        var statusError: Error?

        private var gate: AsyncStream<Void>?
        private var opener: AsyncStream<Void>.Continuation?

        /// Holds every call until `release()`.
        func hold() {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            gate = stream
            opener = continuation
        }

        func release() {
            opener?.finish()
            gate = nil
            opener = nil
        }

        func likedPostIDs(among postIDs: [String]) async throws -> Set<String> {
            if let statusError { throw statusError }
            return likedIDs.intersection(postIDs)
        }

        func like(postID: String) async throws -> LikeMutationResult {
            try await answer(.like(postID))
        }

        func unlike(postID: String) async throws -> LikeMutationResult {
            try await answer(.unlike(postID))
        }

        private func answer(_ call: Call) async throws -> LikeMutationResult {
            let index = calls.count
            calls.append(call)
            let held = gate

            if let held { for await _ in held { break } }
            if neverAnswers {
                // Never returns and never throws. Not `Task.sleep`: a sleep can
                // be cancelled, and the point of this case is a request that
                // cannot be got rid of.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }

            if let error = errors[index] { throw error }
            return index < results.count ? results[index] : .changed
        }
    }

    private func loadedWithLikes(
        count: Int,
        serverLiked: Bool = false,
        likes: FakeLikes,
        deadline: ManualDeadline = ManualDeadline()
    ) async -> PostDetailViewModel {
        let feed = FakeFeed()
        feed.post = Post(
            id: "p1", authorID: "uid", authorName: "A", authorAvatarURL: nil,
            text: "TEST CONTENT", media: [], petID: nil, petName: nil,
            petAvatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            likeCount: count, commentCount: 0, tags: []
        )
        if serverLiked { likes.likedIDs = ["p1"] }
        let model = PostDetailViewModel(
            postID: "p1", feed: feed, comments: FakeComments(), likes: likes,
            // Passed by the test or not at all: see `ManualDeadline`.
            sleeper: deadline.sleeper
        )
        await model.load()
        return model
    }

    private func spin(_ times: Int = 40) async {
        for _ in 0..<times {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Like convergence (the drift the feed already fixed)

    /// Two taps must reach the server in the order they were made.
    ///
    /// The detail screen fired each write in its own unstructured `Task` with
    /// nothing ordering them, so a like and the unlike that follows it could
    /// arrive the other way round — leaving the server *liked* while the screen
    /// says it is not. Nothing in the session corrects that.
    @Test func twoTapsAreSerialisedInTheOrderTheyWereMade() async {
        let likes = FakeLikes()
        let model = await loadedWithLikes(count: 5, likes: likes)
        likes.hold()

        model.toggleLike()
        await spin(6)
        model.toggleLike()
        await spin(6)

        #expect(likes.calls.count == 1, "both writes went out at once: \(likes.calls)")
        likes.release()
        await spin()

        #expect(likes.calls == [.like("p1"), .unlike("p1")], "out of order: \(likes.calls)")
    }

    /// An answer that a later tap has superseded still says something true
    /// about the server, and throwing it away loses that.
    ///
    /// `.unchanged` means the server's count already contains this state. The
    /// old code dropped the whole answer when the intent had moved on, so the
    /// optimistic offset it should have cancelled stayed on screen for the rest
    /// of the session.
    @Test func asupersededAnswerStillCorrectsTheCount() async {
        let likes = FakeLikes()
        // The server already holds this like, but the status read fails, so the
        // screen starts out believing it is not liked — the exact situation
        // that makes a first tap answer `.unchanged`.
        likes.statusError = NSError(domain: "test", code: 13)
        likes.likedIDs = ["p1"]
        likes.results = [.unchanged, .changed]
        let model = await loadedWithLikes(count: 5, likes: likes)
        #expect(model.likeCount == 5)

        likes.hold()
        model.toggleLike()          // like — the server will answer .unchanged
        await spin(6)
        model.toggleLike()          // unlike — supersedes it
        likes.release()
        await spin()

        // The server holds 5 and, after the unlike, 4. What must not happen is
        // the screen keeping the +1 from a tap the server said changed nothing.
        #expect(model.isLiked == false)
        #expect(model.likeCount == 4, "the count kept an offset the server denied: \(model.likeCount)")
    }

    /// A request that is never answered must not wedge the post.
    ///
    /// With no deadline the intent stays optimistic forever, every later tap
    /// queues behind it, and no refresh is allowed to correct it.
    @Test func aRequestThatIsNeverAnsweredGivesUpAndSaysSo() async {
        let likes = FakeLikes()
        likes.neverAnswers = true
        // The deadline passes when the test says, not after 80ms of a clock
        // that CI's runner can stretch past anything. What is asserted is that
        // the request started one and that reaching it produces the right state.
        let deadline = ManualDeadline()
        let model = await loadedWithLikes(count: 5, likes: likes, deadline: deadline)

        model.toggleLike()
        await spin(6)
        #expect(deadline.durations.count == 1, "the request went out with no deadline: \(deadline.durations)")
        #expect(model.isLiked, "optimistic while it is in flight")
        deadline.pass()
        await spin(60)

        #expect(model.isLiked == false, "the heart is still showing a like nothing confirmed")
        #expect(model.likeCount == 5, "the count is still carrying an unconfirmed +1")
        #expect(model.likeFailureMessage != nil, "nothing told the person it could not be confirmed")
    }

    /// A refresh has to be allowed to correct the number.
    ///
    /// `likeCount` is maintained by a trigger that runs after the write, so a
    /// confirmed write does not mean the aggregate has moved — and a client
    /// that only ever adds and subtracts locally has no way back to the truth.
    @Test func aRefreshAdoptsTheServersCountOnceItHasCaughtUp() async {
        let likes = FakeLikes()
        let feed = FakeFeed()
        feed.post = Self.post()
        let model = PostDetailViewModel(
            postID: "p1", feed: feed, comments: FakeComments(), likes: likes,
            sleeper: ManualDeadline.never
        )
        feed.post = Post(
            id: "p1", authorID: "uid", authorName: "A", authorAvatarURL: nil,
            text: "TEST CONTENT", media: [], petID: nil, petName: nil,
            petAvatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            likeCount: 5, commentCount: 0, tags: []
        )
        await model.load()

        model.toggleLike()
        await spin()
        #expect(model.likeCount == 6, "the tap is not reflected at all")

        // The trigger has run, and two other people liked it meanwhile.
        feed.post = Post(
            id: "p1", authorID: "uid", authorName: "A", authorAvatarURL: nil,
            text: "TEST CONTENT", media: [], petID: nil, petName: nil,
            petAvatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            likeCount: 8, commentCount: 0, tags: []
        )
        likes.likedIDs = ["p1"]
        await model.refreshLikeState()
        await spin()

        #expect(model.likeCount == 8, "the server's number was not adopted: \(model.likeCount)")
        #expect(model.isLiked == true)
    }

    // MARK: - A build that cannot reach the callables at all

    /// The Functions SDK refuses to put an auth token on a plaintext HTTP
    /// request to a non-loopback host, and reports it with the *same* code a
    /// genuinely signed-out caller gets. Told apart by the message, because
    /// the two need opposite handling: one is a session problem, the other is
    /// the build, and telling the second person to sign in again is an
    /// instruction that can never work.
    @Test func theSDKsPlaintextTokenRefusalIsNotASessionProblem() {
        let refusal = NSError(
            domain: FunctionsErrorDomain,
            code: FunctionsErrorCode.unauthenticated.rawValue,
            userInfo: [NSLocalizedDescriptionKey:
                "Refusing to send Auth, FCM, and AppCheck tokens over HTTP to non-loopback host."]
        )
        #expect(
            FirestoreCommentRepository.map(refusal)
                == .transport(FirestoreCommentRepository.Transport.unavailable)
        )
    }

    /// A real unauthenticated answer still has to be one.
    @Test func arealUnauthenticatedAnswerIsStillASessionProblem() {
        let unauthenticated = NSError(
            domain: FunctionsErrorDomain,
            code: FunctionsErrorCode.unauthenticated.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Must be logged in."]
        )
        #expect(FirestoreCommentRepository.map(unauthenticated) == .notSignedIn)
    }

    @Test func anUnreachableCallableIsAcertainFailureWithItsOwnWords() async {
        let comments = FakeComments()
        comments.createError = CommentError.transport(
            FirestoreCommentRepository.Transport.unavailable
        )
        let model = await loaded(comments: comments)
        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")

        let message = model.sendFailure?.message ?? ""
        #expect(model.sendFailure?.canRetry == false, "retrying this build cannot ever work")
        #expect(model.sendFailure?.needsReauthentication != true, "this is not about the session")
        #expect(message.contains("build"), "does not say what is actually wrong: \(message)")
        #expect(model.draft == "TEST CONTENT hello", "the text is kept")
        // Nothing of the SDK's own wording reaches the screen.
        for leak in ["Refusing to send", "non-loopback", "FIRFunctions", "code=16"] {
            #expect(!message.contains(leak), "raw SDK error leaked: \(leak)")
        }
    }

    /// The composer is not disabled by any of this. A control that stops
    /// working is a worse answer than a control that explains itself.
    @Test func anUnreachableCallableDoesNotDisableTheComposer() async {
        let comments = FakeComments()
        comments.createError = CommentError.transport(
            FirestoreCommentRepository.Transport.unavailable
        )
        let model = await loaded(comments: comments)
        model.draft = "TEST CONTENT hello"
        await model.send(authorID: "uid", authorName: "A")

        #expect(!model.isSending, "the composer was left in a sending state")
        #expect(!model.isOverLength)
        // Sending again is possible — it will fail again, and say why again.
        await model.send(authorID: "uid", authorName: "A")
        #expect(comments.createCalls.count == 2)
    }

    // MARK: - Comment refresh and paging failure, with the round trip held open
    //
    // Same discipline as `FeedViewModelTests`' section of the same name: the
    // moment being asked about is constructed with `beforeAnswering` /
    // `whileInFlight` rather than sampled for. The comment list had all of the
    // feed's refresh problems one screen further in, and two of its own.

    private func detailLoaded(
        _ comments: FakeComments, pageSize: Int = 30
    ) async -> PostDetailViewModel {
        let feed = FakeFeed()
        feed.post = Self.post()
        let model = PostDetailViewModel(
            postID: "p1", feed: feed, comments: comments, pageSize: pageSize
        )
        await model.load()
        return model
    }

    /// 1. Pulling to refresh does not empty the list while the read is out.
    ///
    /// `loadComments(reset:)` cleared `comments` at the top and refilled it
    /// when the answer came back, so everything the person was reading was
    /// gone for the length of the round trip — 90ms on a loopback, and the
    /// length of the network anywhere else.
    @Test func aCommentsRefreshInFlightStillHoldsTheCommentsItIsReplacing() async {
        let comments = FakeComments()
        comments.pages = [[Self.comment("c1"), Self.comment("c2")]]
        let model = await detailLoaded(comments)
        #expect(model.comments.map(\.id) == ["c1", "c2"])

        let during = CommentReading()
        comments.pages = [[Self.comment("c3")]]
        comments.whileInFlight = { @MainActor @Sendable in during.take(from: model) }
        await model.loadComments(reset: true)

        #expect(during.commentIDs == ["c1", "c2"], "the list went blank mid-refresh: \(during.commentIDs)")
        #expect(model.comments.map(\.id) == ["c3"], "and the replacement did arrive")
    }

    /// 2. A refresh that fails keeps the comments and offers a retry, rather
    /// than reporting "could not load comments" about comments it deleted on
    /// the way to saying so.
    @Test func aFailedCommentsRefreshKeepsTheCommentsAndStaysRetryable() async {
        let comments = FakeComments()
        comments.pages = [[Self.comment("c1"), Self.comment("c2")]]
        let model = await detailLoaded(comments)

        let during = CommentReading()
        comments.readError = NSError(domain: "test", code: 13)
        comments.beforeAnswering = { @MainActor @Sendable in during.take(from: model) }
        await model.loadComments(reset: true)

        #expect(during.commentIDs == ["c1", "c2"], "the rows went before the failure did")
        #expect(model.comments.map(\.id) == ["c1", "c2"], "a failed refresh emptied the list")
        if case .failed = model.commentsState {} else {
            Issue.record("expected .failed, got \(model.commentsState)")
        }

        // And the retry the failure line offers actually re-reads.
        comments.readError = nil
        comments.pages = [[Self.comment("c9")]]
        await model.retryComments()
        #expect(model.commentsState == .loaded)
        #expect(model.comments.map(\.id) == ["c9"], "got \(model.comments.map(\.id))")
    }

    /// 3. Losing page two does not take page one off the screen.
    @Test func aFailedNextCommentPageKeepsThePagesAlreadyRead() async {
        let comments = FakeComments()
        comments.pages = [[Self.comment("c1")], [Self.comment("c2")], [Self.comment("c3")]]
        let model = await detailLoaded(comments, pageSize: 1)
        #expect(model.comments.map(\.id) == ["c1"])

        let during = CommentReading()
        comments.readError = NSError(domain: "test", code: 13)
        comments.beforeAnswering = { @MainActor @Sendable in during.take(from: model) }
        await model.loadMoreCommentsIfNeeded(currentItem: model.comments[0])

        #expect(during.commentIDs == ["c1"], "page one was already gone while page two was out")
        #expect(model.comments.map(\.id) == ["c1"], "a lost page took the read one with it")
        if case .failed = model.commentsState {} else {
            Issue.record("expected .failed, got \(model.commentsState)")
        }
    }

    /// 4. A refresh that has been overtaken must not put its older answer back.
    @Test func aLateCommentsRefreshAnswerDoesNotOverwriteANewerOne() async {
        let comments = FakeComments()
        comments.pages = [[Self.comment("first")]]
        let model = await detailLoaded(comments)

        comments.pages = [[Self.comment("stale")]]
        comments.whileInFlight = { @MainActor @Sendable in
            comments.pages = [[Self.comment("newest")]]
            await model.loadComments(reset: true)
        }
        await model.loadComments(reset: true)

        #expect(model.comments.map(\.id) == ["newest"], "the overtaken refresh was applied: \(model.comments.map(\.id))")
        #expect(model.commentsState == .loaded)
    }

    /// 4b. And a failure from an overtaken refresh must not break a screen the
    /// newer one has just filled.
    @Test func aLateCommentsFailureDoesNotOverwriteANewerSuccess() async {
        let comments = FakeComments()
        comments.pages = [[Self.comment("first")]]
        let model = await detailLoaded(comments)

        comments.readError = NSError(domain: "test", code: 13)
        comments.beforeAnswering = { @MainActor @Sendable in
            comments.readError = nil
            comments.pages = [[Self.comment("newest")]]
            await model.loadComments(reset: true)
            comments.readError = NSError(domain: "test", code: 13)
        }
        await model.loadComments(reset: true)

        #expect(model.commentsState == .loaded, "a superseded failure broke a screen that had just loaded")
        #expect(model.comments.map(\.id) == ["newest"])
    }

    /// 5. Retrying a lost comment page fetches the page that was lost, adds it
    /// once, and leaves paging able to carry on.
    ///
    /// Before the cursor was released on failure this could not work at all:
    /// `retryComments` walked into the spent-cursor guard and returned having
    /// done nothing, so the screen sat on `.loading` — the spinner under the
    /// comments, forever, from a button that reported nothing when pressed.
    @Test func retryingALostCommentPageAddsItOnceAndSkipsNothing() async {
        let comments = FakeComments()
        comments.pages = [[Self.comment("c1")], [Self.comment("c2")], [Self.comment("c3")]]
        let model = await detailLoaded(comments, pageSize: 1)

        comments.readError = NSError(domain: "test", code: 13)
        await model.loadMoreCommentsIfNeeded(currentItem: model.comments[0])
        let failedCursor = comments.cursorsRequested.last

        comments.readError = nil
        await model.retryComments()

        #expect(comments.cursorsRequested.last == failedCursor, "the retry skipped the page that was lost")
        #expect(model.comments.map(\.id) == ["c1", "c2"], "got \(model.comments.map(\.id))")
        #expect(model.commentsState == .loaded, "got \(model.commentsState)")

        // Paging carries on from there rather than from a hole. Driven from
        // the last row rather than from index 1: when this fails it fails by
        // leaving one comment on screen, and indexing would turn a reported
        // expectation into a trap that takes the rest of the suite with it.
        guard let lastRow = model.comments.last else { return }
        await model.loadMoreCommentsIfNeeded(currentItem: lastRow)
        #expect(model.comments.map(\.id) == ["c1", "c2", "c3"], "got \(model.comments.map(\.id))")
        let ids = model.comments.map(\.id)
        #expect(Set(ids).count == ids.count, "a comment was added twice: \(ids)")
    }
}

/// One instant of what the detail screen was holding, taken from inside an
/// open read. The comment half of `Reading`; see it for why this is a
/// `@MainActor` class rather than captured locals.
@MainActor
final class CommentReading {
    var commentIDs: [String] = []
    var state: PostDetailViewModel.CommentsState = .loading

    func take(from model: PostDetailViewModel) {
        commentIDs = model.comments.map(\.id)
        state = model.commentsState
    }
}
