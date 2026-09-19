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
    private(set) var isLiked = false
    private(set) var likeCount = 0

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
        let message: String
        /// False for "we do not know if it went through" — the text stays, the
        /// person decides, and a refresh settles it.
        let canRetry: Bool
    }

    private let postID: String
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
    private var likeIntent = 0
    private let pageSize: Int

    init(
        postID: String,
        feed: any FeedRepository,
        comments commentRepository: any CommentRepository,
        likes: (any LikeRepository)? = nil,
        pageSize: Int = 30
    ) {
        self.postID = postID
        self.feed = feed
        self.commentRepository = commentRepository
        self.likes = likes
        self.pageSize = pageSize
    }

    func load() async {
        state = .loading
        do {
            guard let post = try await feed.post(id: postID) else {
                state = .deleted
                return
            }
            state = .loaded(post)
            likeCount = post.likeCount
            await loadLikeStatus()
            await loadComments(reset: true)
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    private func loadLikeStatus() async {
        guard let likes else { return }
        do {
            isLiked = try await likes.likedPostIDs(among: [postID]).contains(postID)
        } catch {
            log.error("like status failed: \(error.localizedDescription, privacy: .public)")
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
        sendFailure = nil
        draft = ""

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
            apply(error, restoring: text)
        } catch {
            comments.removeAll { $0.id == pendingID }
            draft = text
            sendFailure = .init(message: "Could not post that comment.", canRetry: true)
        }
    }

    private func apply(_ error: CommentError, restoring text: String) {
        switch error {
        case .notSignedIn:
            draft = text
            sendFailure = .init(message: "Sign in to comment.", canRetry: false)
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
                message: "We could not confirm that comment was posted. Refresh to check before sending again.",
                canRetry: false
            )
            Task { await loadComments(reset: true) }
        case .transport:
            draft = text
            sendFailure = .init(message: "Could not post that comment.", canRetry: true)
        }
    }

    /// Same three-state contract as the feed's, and the same rule: `.unchanged`
    /// means the server's count already includes this like, so the optimistic
    /// offset comes back off.
    func toggleLike() {
        guard let likes else { return }
        let shouldLike = !isLiked
        isLiked = shouldLike
        likeCount = max(0, likeCount + (shouldLike ? 1 : -1))

        let intent = likeIntent + 1
        likeIntent = intent

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = shouldLike
                    ? try await likes.like(postID: self.postID)
                    : try await likes.unlike(postID: self.postID)
                guard self.likeIntent == intent else { return }
                switch result {
                case .changed:
                    break
                case .unchanged:
                    self.likeCount = max(0, self.likeCount + (shouldLike ? -1 : 1))
                case .postNotFound:
                    self.state = .deleted
                }
            } catch {
                guard self.likeIntent == intent else { return }
                self.isLiked = !shouldLike
                self.likeCount = max(0, self.likeCount + (shouldLike ? -1 : 1))
            }
        }
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
