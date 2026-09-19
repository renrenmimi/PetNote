import Foundation

protocol FeedRepository: Sendable {
    /// Newest first, matching `getPosts` (src/services/posts.ts:195):
    /// `orderBy("createdAt","desc")` with a snapshot cursor.
    func posts(after cursor: PageCursor?, limit: Int) async throws -> Page<Post>

    func post(id: String) async throws -> Post?
}

protocol CommentRepository: Sendable {
    /// Newest first, matching `getComments` (src/services/posts.ts:439).
    func comments(postID: String, after cursor: PageCursor?, limit: Int) async throws -> Page<Comment>

    /// Goes through `createCommentCallable`; writing the subcollection directly
    /// is refused by the rules and would skip every gate below.
    ///
    /// - Throws: `CommentError`, one case per gate the callable enforces.
    /// - Returns: the new comment's id.
    func create(postID: String, text: String, replyTo: String?) async throws -> String
}

protocol LikeRepository: Sendable {
    func like(postID: String) async throws -> LikeMutationResult
    func unlike(postID: String) async throws -> LikeMutationResult

    /// Batched on purpose: the web client replaced N parallel `getDocs` with one
    /// collection-group `(userId, postId in)` query, and the native client must
    /// not regress to N+1 (engineering spec §14).
    func likedPostIDs(among postIDs: [String]) async throws -> Set<String>
}

/// Three states, not a Bool and not Void.
///
/// `likePost` used to return void and silently return when the post was gone,
/// so a caller could not tell success from failure: tapping a deleted post's
/// heart turned it red and incremented the count with no write behind it.
/// The source comment in src/services/posts.ts records that; keeping the three
/// states is what stops it happening again.
enum LikeMutationResult: Sendable, Equatable {
    /// The write happened. The server trigger will move the count.
    case changed
    /// The server was already in this state. The count already includes it.
    case unchanged
    /// The post no longer exists: roll the optimistic update back and drop the
    /// row from the list.
    case postNotFound
}

/// One case per gate in `createCommentCallable` (functions/src/posts.ts:768),
/// in the order the server checks them. The UI has to tell them apart: they
/// need different words and different recovery.
enum CommentError: Error, Sendable, Equatable {
    case notSignedIn
    case emailNotVerified
    case banned
    /// Either direction of a block. The message must not say which — that would
    /// leak who blocked whom.
    case blockedFromAuthor
    case postNotFound
    case replyTargetNotFound
    case rateLimited
    /// The server refused the content itself — too long, malformed, or failing
    /// a precondition. Carries the words to show, and is never retryable:
    /// the same text will be refused again.
    case rejected(String)

    /// The request went out and no answer came back.
    ///
    /// **Must not be retried automatically.** `createCommentCallable` has no
    /// idempotency key, so a resend can post the comment twice. Keep the text,
    /// say it is uncertain, and let a refresh settle it.
    case outcomeUnknown

    case transport(String)
}
