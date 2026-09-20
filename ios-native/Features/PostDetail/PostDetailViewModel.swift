import Foundation
import Observation
import OSLog

/// Post detail plus its comments.
///
/// The comment state machine is the contract from functions/src/posts.ts:768,
/// one branch per gate. The branch that matters most is the one that does
/// nothing: **an unknown outcome is never retried automatically**, because
/// `createCommentCallable` has no idempotency key and a resend posts twice.
@MainActor
@Observable
final class PostDetailViewModel {
    enum LoadState: Equatable {
        case loading
        case loaded(Post)
        /// The post was there when the feed loaded and is not there now.
        case deleted
        case failed(String)
    }

    /// Comments load separately from the post: one failing must not take the
    /// other down (§6.5), and "none yet" must not be how a failure looks.
    enum CommentsState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var state: LoadState = .loading
    private(set) var comments: [Comment] = []
    private(set) var commentsState: CommentsState = .loading
    private(set) var hasMoreComments = true
    /// The count as the server last reported it. Everything else about the
    /// like is an offset from this, never a replacement for it.
    private(set) var serverLikeCount = 0
    /// A like that could not be applied. Shown inline and cleared by the view.
    var likeFailureMessage: String?

    /// The three facts that were previously squeezed into one counter, and
    /// each of which failed differently for it. Same structure as the feed's,
    /// for the same reasons — see `FeedViewModel.LikeState`.
    ///
    ///   - `serverLiked`: whether the like document exists. Authoritative.
    ///   - `intendedLiked`: what the person last asked for. Drives the heart.
    ///   - `unreflectedDelta`: what our confirmed writes have added that the
    ///     aggregate has not caught up with — `likeCount` is maintained by a
    ///     trigger that runs *after* the write.
    private struct LikeState {
        var serverLiked: Bool
        var intendedLiked: Bool
        var unreflectedDelta: Int
        var snapshotCount: Int
        var inFlight: Int
        var unconfirmedReads = 0
        var lastWriteSequence = 0
    }
    private var likeState: LikeState?
    private var likeTask: Task<Void, Never>?
    /// Bumped by every answered write, so a status read can be compared
    /// against it and discarded when it describes an older world.
    private var writeSequence = 0
    /// How many server reads an unconfirmed offset survives before the
    /// server's number is taken as it stands.
    private static let unconfirmedReadLimit = 3

    var isLiked: Bool { likeState?.intendedLiked ?? false }

    /// The number to draw: the server's count, plus what our confirmed writes
    /// have added that it has not caught up with, plus one for a tap that has
    /// not been answered.
    var likeCount: Int {
        guard let state = likeState else { return serverLikeCount }
        let pending = state.intendedLiked == state.serverLiked
            ? 0
            : (state.intendedLiked ? 1 : -1)
        return max(0, serverLikeCount + state.unreflectedDelta + pending)
    }

    var draft: String = ""
    private(set) var sendFailure: SendFailure?
    private(set) var isSending = false

    /// The server's cap (`VALIDATION_LIMITS.commentText`). Enforced here so an
    /// over-long comment is prevented rather than sent, rejected, and reported
    /// as something worth retrying.
    static let maxCommentLength = 500

    var remainingCharacters: Int { Self.maxCommentLength - draft.count }
    var isOverLength: Bool { draft.count > Self.maxCommentLength }

    struct SendFailure: Equatable {
        /// Whether this is still a problem or the report of one that resolved.
        ///
        /// An unknown outcome that turns out to have been a success has to say
        /// so, and saying it in the same red as a refusal would be its own
        /// small lie.
        enum Tone: Equatable {
            case problem
            case resolved
        }

        let message: String
        /// False for "we do not know if it went through" — the text stays, the
        /// person decides, and a refresh settles it.
        let canRetry: Bool
        var tone: Tone = .problem
        /// The server said this caller is not authenticated. The screen turns
        /// that into a question for the session rather than telling a
        /// signed-in person to sign in (§6.9).
        var needsReauthentication: Bool = false
    }

    /// Read by the screen so it can tell the session where the person is.
    let postID: String
    private let feed: any FeedRepository
    private let commentRepository: any CommentRepository
    private let likes: (any LikeRepository)?
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "comment")

    private var nextCursor: PageCursor?
    private var requestedCursors: Set<PageCursor> = []
    private var isLoadingComments = false
    /// Same reason as the feed's: a refresh must invalidate a page already in
    /// flight instead of racing it.
    private var commentGeneration = 0
    /// Bumped by every send. The settle-after-unknown check carries the value
    /// it started with, so a verdict about a send the person has already moved
    /// past is discarded rather than written over what they are doing now —
    /// the same guard `commentGeneration` gives the comment list.
    private var sendGeneration = 0
    private let pageSize: Int
    private let likeDeadline: Duration
    private let sleeper: @Sendable (Duration) async throws -> Void

    init(
        postID: String,
        feed: any FeedRepository,
        comments commentRepository: any CommentRepository,
        likes: (any LikeRepository)? = nil,
        pageSize: Int = 30,
        likeDeadline: Duration = .seconds(12),
        sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.postID = postID
        self.feed = feed
        self.commentRepository = commentRepository
        self.likes = likes
        self.pageSize = pageSize
        self.likeDeadline = likeDeadline
        self.sleeper = sleeper
    }

    func load() async {
        state = .loading
        do {
            guard let post = try await feed.post(id: postID) else {
                state = .deleted
                return
            }
            state = .loaded(post)
            serverLikeCount = post.likeCount
            await readLikeState(freshCount: post.likeCount, readSequence: writeSequence)
            await loadComments(reset: true)
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// Re-reads the like state — the document *and* the count — without
    /// reloading the whole screen.
    ///
    /// Reading the count is the point. It is maintained by a trigger that runs
    /// after the write, so a client that only ever adds and subtracts locally
    /// has no path back to the truth; this is that path.
    func refreshLikeState() async {
        // Sampled before the reads, so an answer that arrives after a write we
        // have since had confirmed can be recognised as older than it.
        let readSequence = writeSequence
        var freshCount: Int?
        if let post = try? await feed.post(id: postID) {
            freshCount = post.likeCount
            if case .loaded = state { state = .loaded(post) }
        }
        await readLikeState(freshCount: freshCount, readSequence: readSequence)
    }

    private func readLikeState(freshCount: Int?, readSequence: Int) async {
        guard let likes else { return }
        var serverSaysLiked: Bool?
        do {
            serverSaysLiked = try await likes.likedPostIDs(among: [postID]).contains(postID)
        } catch {
            // Not fatal: the heart renders unset and tapping still works. It
            // does mean a first tap on an already-liked post answers
            // `.unchanged`, which is exactly why that path must not keep an
            // offset.
            log.error("like status failed: \(error.localizedDescription, privacy: .public)")
        }
        apply(serverLiked: serverSaysLiked, freshCount: freshCount, readSequence: readSequence)
    }

    private func apply(serverLiked: Bool?, freshCount: Int?, readSequence: Int) {
        if let freshCount { serverLikeCount = freshCount }

        guard var existing = likeState else {
            // Nothing is known yet, and only an answer we actually received can
            // seed a belief.
            if let serverLiked {
                likeState = LikeState(
                    serverLiked: serverLiked, intendedLiked: serverLiked,
                    unreflectedDelta: 0, snapshotCount: freshCount ?? serverLikeCount,
                    inFlight: 0
                )
            }
            return
        }

        guard existing.lastWriteSequence <= readSequence else {
            // This read is older than a write we have since had answered. It
            // describes a world that no longer exists.
            return
        }

        if let serverLiked {
            if serverLiked != existing.serverLiked {
                // Someone else changed it. Whatever we had outstanding against
                // the old state no longer describes anything.
                existing.unreflectedDelta = 0
                existing.unconfirmedReads = 0
            } else {
                reconcile(&existing, against: freshCount ?? serverLikeCount)
            }
            existing.serverLiked = serverLiked
            // A tap that has not been answered still owns the intent.
            if existing.inFlight == 0 { existing.intendedLiked = serverLiked }
        } else {
            reconcile(&existing, against: freshCount ?? serverLikeCount)
        }

        existing.snapshotCount = freshCount ?? serverLikeCount
        likeState = existing
    }

    /// Decides whether an optimistic offset has been absorbed by the server's
    /// count, and drops it after `unconfirmedReadLimit` reads either way.
    ///
    /// It has to be bounded. A stranger's *unlike* cancelling our like leaves
    /// the count exactly where it was, so "has it caught up?" can never answer
    /// yes — and an offset held without a limit is wrong on every reading of
    /// that post for the rest of the session. Briefly wrong then right is
    /// recoverable; quietly wrong forever is not.
    private func reconcile(_ state: inout LikeState, against freshCount: Int) {
        guard state.unreflectedDelta != 0 else {
            state.unconfirmedReads = 0
            return
        }
        let moved = freshCount - state.snapshotCount
        let caughtUp = moved.signum() == state.unreflectedDelta.signum()
            && abs(moved) >= abs(state.unreflectedDelta)
        if caughtUp {
            state.unreflectedDelta = 0
            state.unconfirmedReads = 0
            return
        }
        state.unconfirmedReads += 1
        if state.unconfirmedReads >= Self.unconfirmedReadLimit {
            log.debug("dropping a like offset the aggregate never confirmed")
            state.unreflectedDelta = 0
            state.unconfirmedReads = 0
        }
    }

    func loadComments(reset: Bool = false) async {
        if reset {
            // The generation bump comes first: a page already in flight is
            // invalidated rather than allowed to repopulate a list this call is
            // about to replace. Doing the reset before the re-entrancy guard,
            // as this used to, wiped page 1 and then returned without asking
            // for a replacement.
            commentGeneration += 1
            comments.removeAll()
            nextCursor = nil
            requestedCursors.removeAll()
            hasMoreComments = true
            isLoadingComments = false
            commentsState = .loading
        }
        guard hasMoreComments, !isLoadingComments else { return }
        if let cursor = nextCursor {
            guard !requestedCursors.contains(cursor) else { return }
            requestedCursors.insert(cursor)
        }

        let thisGeneration = commentGeneration
        isLoadingComments = true
        defer { if thisGeneration == commentGeneration { isLoadingComments = false } }

        do {
            let page = try await commentRepository.comments(
                postID: postID,
                after: nextCursor,
                limit: pageSize
            )
            guard thisGeneration == commentGeneration else { return }
            let known = Set(comments.map(\.id))
            comments.append(contentsOf: page.items.filter { !known.contains($0.id) })
            nextCursor = page.next
            hasMoreComments = page.hasMore
            commentsState = .loaded
        } catch {
            guard thisGeneration == commentGeneration else { return }
            log.error("comments failed: \(error.localizedDescription, privacy: .public)")
            // Not silence: an empty list after a failure reads as "no comments",
            // which is a different fact.
            commentsState = .failed(Self.message(for: error))
            hasMoreComments = false
        }
    }

    func retryComments() async {
        commentsState = .loading
        hasMoreComments = true
        await loadComments(reset: comments.isEmpty)
    }

    func loadMoreCommentsIfNeeded(currentItem: Comment) async {
        guard case .loaded = commentsState else { return }
        guard let index = comments.firstIndex(where: { $0.id == currentItem.id }),
              index >= comments.count - 5 else { return }
        await loadComments()
    }

    func send(authorID: String, authorName: String) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        guard text.count <= Self.maxCommentLength else {
            sendFailure = .init(
                message: "Comments are limited to \(Self.maxCommentLength) characters.",
                canRetry: false
            )
            return
        }

        isSending = true
        sendGeneration += 1
        let thisSend = sendGeneration
        sendFailure = nil
        draft = ""

        // What was on screen before this send. If the outcome turns out to be
        // unknown, this is what makes "did it land?" answerable: a comment that
        // was not here before, from this author, with this text, is this send.
        let knownBefore = Set(comments.map(\.id))

        let pendingID = "pending-\(UUID().uuidString)"
        let placeholder = Comment(
            id: pendingID, authorID: authorID, authorName: authorName,
            authorAvatarURL: nil, text: text, createdAt: Date(),
            replyTo: nil, isPending: true
        )
        comments.insert(placeholder, at: 0)

        defer { isSending = false }
        do {
            let id = try await commentRepository.create(postID: postID, text: text, replyTo: nil)
            let confirmed = placeholder.confirmed(as: id)
            if let index = comments.firstIndex(where: { $0.id == pendingID }) {
                comments[index] = confirmed
            } else if !comments.contains(where: { $0.id == id }) {
                // The placeholder is gone — a refresh landed mid-send. The
                // comment exists on the server, so it goes back in rather than
                // vanishing and inviting the person to type it again.
                comments.insert(confirmed, at: 0)
            }
        } catch let error as CommentError {
            comments.removeAll { $0.id == pendingID }
            apply(
                error, restoring: text, authorID: authorID,
                knownBefore: knownBefore, generation: thisSend
            )
        } catch {
            comments.removeAll { $0.id == pendingID }
            draft = text
            sendFailure = .init(message: "Could not post that comment.", canRetry: true)
        }
    }

    private func apply(
        _ error: CommentError,
        restoring text: String,
        authorID: String,
        knownBefore: Set<String>,
        generation: Int
    ) {
        switch error {
        case .notSignedIn:
            draft = text
            // Not "sign in to comment": the person is looking at a signed-in
            // app. The screen asks the session whether that is still true, and
            // §6.9 takes over from there if it is not.
            sendFailure = .init(
                message: "Your session could not be verified. Checking…",
                canRetry: false,
                needsReauthentication: true
            )
        case .emailNotVerified:
            draft = text
            sendFailure = .init(message: "Verify your email before commenting.", canRetry: false)
        case .banned:
            draft = text
            sendFailure = .init(message: "This account cannot comment.", canRetry: false)
        case .blockedFromAuthor:
            draft = text
            // Neutral on purpose: which way the block runs is not ours to say.
            sendFailure = .init(message: "You cannot comment on this post.", canRetry: false)
        case .postNotFound:
            state = .deleted
            sendFailure = .init(message: "This post no longer exists.", canRetry: false)
        case .replyTargetNotFound:
            draft = text
            sendFailure = .init(message: "The comment you replied to was deleted.", canRetry: false)
        case .rateLimited:
            draft = text
            sendFailure = .init(message: "Too many comments just now. Wait a moment.", canRetry: true)
        case .rejected(let reason):
            // The server refused the content itself. Retrying the same text
            // cannot succeed, so it is not offered.
            draft = text
            sendFailure = .init(message: reason, canRetry: false)
        case .outcomeUnknown:
            draft = text
            sendFailure = .init(
                message: "We could not confirm that comment was posted. Checking…",
                canRetry: false
            )
            Task { [weak self] in
                await self?.settleUnknownOutcome(
                    text: text, authorID: authorID,
                    knownBefore: knownBefore, generation: generation
                )
            }
        case .transport(let detail):
            draft = text
            // Offline is a certain failure, not an uncertain one: the request
            // never left the device. It gets its own words because §6.11 asks
            // for an offline message that is distinguishable from a server one.
            switch detail {
            case FirestoreCommentRepository.Transport.offline:
                sendFailure = .init(
                    message: "You appear to be offline. Your comment is still here — "
                        + "send it again when you have a connection.",
                    canRetry: true
                )
            case FirestoreCommentRepository.Transport.unavailable:
                // Certain, and not retryable: this build on this network cannot
                // send a comment at all. The words say it is the build, because
                // the person has done nothing wrong and trying again — or
                // signing in again, which is what `unauthenticated` used to
                // suggest — cannot help.
                sendFailure = .init(
                    message: "This test build cannot post comments from a device. "
                        + "It reaches the local server over plain HTTP, which the "
                        + "Firebase SDK will not send credentials over. Your comment is still here.",
                    canRetry: false
                )
            default:
                sendFailure = .init(message: "Could not post that comment.", canRetry: true)
            }
        }
    }

    /// Settles a send whose outcome we never learned — by looking, never by
    /// sending again.
    ///
    /// `createCommentCallable` has no idempotency key, so a second request can
    /// create a second comment. **Nothing in this path retries.** It re-reads
    /// the list, which Firestore serves strongly consistently, and then says
    /// which of the two things happened instead of leaving the person to guess
    /// — because guessing is what produces the duplicate this whole branch
    /// exists to avoid.
    private func settleUnknownOutcome(
        text: String,
        authorID: String,
        knownBefore: Set<String>,
        generation: Int
    ) async {
        await loadComments(reset: true)

        // Anything the person has done since is theirs, not ours to overwrite.
        // The generation covers a send that started *and finished* while this
        // was reading, which `isSending` alone would have missed.
        guard generation == sendGeneration, !isSending else { return }

        guard case .loaded = commentsState else {
            // The check itself failed. We know no more than we did, and the
            // words must not pretend otherwise.
            sendFailure = .init(
                message: "We could not confirm that comment was posted, and could not check either. "
                    + "Refresh before sending it again.",
                canRetry: false
            )
            return
        }

        let landed = comments.contains {
            $0.authorID == authorID && $0.text == text && !knownBefore.contains($0.id)
        }
        if landed {
            // It is already on screen, from the refresh above. Clear the box so
            // the obvious next action is not the one that duplicates it — but
            // only if it still holds what we put back.
            if draft == text { draft = "" }
            sendFailure = .init(
                message: "That comment was posted after all.",
                canRetry: false,
                tone: .resolved
            )
        } else {
            // Worded as what was actually checked, not as a verdict. The read
            // covers the newest page, which is where a comment sent a moment
            // ago has to be — but saying "it was not posted" would be claiming
            // more than one page can support.
            sendFailure = .init(
                message: "We checked, and your comment is not in the list. "
                    + "It is still here — send it again if you want to.",
                canRetry: true
            )
        }
    }

    /// One tap. Serialised against the last one, answered under a deadline,
    /// and never allowed to throw away what the server said.
    ///
    /// The comment this replaced claimed the same three-state contract as the
    /// feed's. It had stopped being true in three ways at once, and each had a
    /// definite consequence:
    ///
    ///   - **nothing ordered the writes.** Each tap started its own detached
    ///     task, so a like and the unlike after it could arrive the other way
    ///     round and leave the server liked while the screen said otherwise;
    ///   - **a superseded answer was discarded whole.** `.unchanged` means the
    ///     server's count already contains that state, and dropping it left an
    ///     optimistic offset on screen that nothing in the session removed;
    ///   - **there was no deadline.** A request that never came back held the
    ///     intent optimistic forever, queued every later tap behind it, and
    ///     stopped any refresh from correcting either.
    func toggleLike() {
        guard likes != nil else { return }
        var state = likeState ?? LikeState(
            serverLiked: false, intendedLiked: false,
            unreflectedDelta: 0, snapshotCount: serverLikeCount, inFlight: 0
        )
        let shouldLike = !state.intendedLiked
        state.intendedLiked = shouldLike
        state.inFlight += 1
        likeState = state

        let previous = likeTask
        likeTask = Task { [weak self] in
            // Serialised, so the server sees the taps in the order they were
            // made rather than in whatever order the network delivers them.
            await previous?.value
            await self?.applyLike(shouldLike: shouldLike)
        }
    }

    /// What came back from one like write.
    ///
    /// `timedOut` is not `failed`. A failure means nothing was written and
    /// nothing is owed to the count; a timeout means *we do not know*, and the
    /// difference has to reach the state as "believe the next read" rather
    /// than "assume it did not happen".
    private enum LikeOutcome: Sendable {
        case answered(LikeMutationResult)
        case failed(String)
        case timedOut
    }

    /// Runs one like write under a deadline.
    ///
    /// The work runs in its own unstructured task and is *abandoned* when the
    /// deadline passes, not awaited: Firestore's async calls do not promise to
    /// return early on cancellation, so waiting for it would be exactly the
    /// wait this exists to end. The screen stops waiting; the network may not.
    private func answer(
        for operation: @escaping @Sendable () async throws -> LikeMutationResult
    ) async -> LikeOutcome {
        let (outcomes, send) = AsyncStream<LikeOutcome>.makeStream()
        let work = Task {
            do { send.yield(.answered(try await operation())) }
            catch { send.yield(.failed(error.localizedDescription)) }
        }
        let timer = Task { [sleeper, likeDeadline] in
            try? await sleeper(likeDeadline)
            send.yield(.timedOut)
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        var iterator = outcomes.makeAsyncIterator()
        return await iterator.next() ?? .timedOut
    }

    private func applyLike(shouldLike: Bool) async {
        guard let likes else { return }
        defer {
            if var state = likeState {
                state.inFlight = max(0, state.inFlight - 1)
                likeState = state
            }
        }

        let postID = self.postID
        let outcome = await answer {
            shouldLike
                ? try await likes.like(postID: postID)
                : try await likes.unlike(postID: postID)
        }
        guard var state = likeState else { return }

        switch outcome {
        case .answered(let result):
            writeSequence += 1
            state.lastWriteSequence = writeSequence

            switch result {
            case .changed:
                // **Recorded unconditionally.** The server's count really did
                // move, whether or not a later tap has since superseded this
                // request. Discarding it because the intent moved on is how a
                // like-then-unlike pair loses its +1 and keeps its -1.
                state.unreflectedDelta += shouldLike ? 1 : -1
                state.unconfirmedReads = 0
                state.serverLiked = shouldLike
                likeState = state
            case .unchanged:
                // The server was already in this state: nothing moved and the
                // count already accounts for it. Only the belief is corrected —
                // and it is corrected even when a later tap has superseded this
                // request, because it is a true statement about the server.
                state.serverLiked = shouldLike
                likeState = state
            case .postNotFound:
                self.state = .deleted
                likeState = nil
                likeFailureMessage = "That post no longer exists."
            }

        case .failed(let description):
            log.error("like write failed: \(description, privacy: .public)")
            // Nothing was written, so nothing is owed to the count.
            rollBackIntent(&state)
            likeFailureMessage = "Could not update the like. Try again."

        case .timedOut:
            log.error("like request for \(postID, privacy: .public) was never answered")
            // No offset recorded and `lastWriteSequence` not moved: we do not
            // know whether the write landed, so the next read is allowed to be
            // the authority on both the heart and the count.
            rollBackIntent(&state)
            likeFailureMessage = "Could not confirm that. Pull down to refresh."
        }
    }

    /// Returns the heart to what the server holds — but only when this is the
    /// last request outstanding, because a later tap owns the intent.
    private func rollBackIntent(_ state: inout LikeState) {
        guard state.inFlight <= 1 else { return }
        state.intendedLiked = state.serverLiked
        likeState = state
    }

    func dismissFailure() { sendFailure = nil }

    private static func message(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain || nsError.code == 14 {
            return "You appear to be offline."
        }
        // 7 is Firestore's permission-denied.
        if nsError.code == 7 { return "You do not have access to this post." }
        return "Could not load this post."
    }
}

private extension Comment {
    func confirmed(as id: String) -> Comment {
        Comment(
            id: id, authorID: authorID, authorName: authorName,
            authorAvatarURL: authorAvatarURL, text: text, createdAt: createdAt,
            replyTo: replyTo, isPending: false
        )
    }
}
