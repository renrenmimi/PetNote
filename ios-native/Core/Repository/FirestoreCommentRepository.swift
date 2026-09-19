import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OSLog

/// Comments: read straight from the subcollection, write only through the
/// callable.
///
/// The rules refuse a direct write, and going around them would skip every gate
/// the callable enforces (verified email, not banned, post exists, no block
/// between the two people, reply target exists).
actor FirestoreCommentRepository: CommentRepository {
    private let db: Firestore
    private let functions: Functions
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "comment")
    private var resumePoints: [PageCursor: DocumentSnapshot] = [:]

    init(db: Firestore = .firestore(), functions: Functions = .functions()) {
        self.db = db
        self.functions = functions
    }

    func comments(postID: String, after cursor: PageCursor?, limit: Int) async throws -> Page<Comment> {
        guard let validID = DeepLink.validDocumentID(postID) else { return .empty }
        if cursor == nil { resumePoints.removeAll() }

        var query: Query = db.collection("posts").document(validID).collection("comments")
            .order(by: "createdAt", descending: true)
            .limit(to: limit)
        if let cursor {
            guard let resume = resumePoints[cursor] else {
                return try await comments(postID: postID, after: nil, limit: limit)
            }
            query = query.start(afterDocument: resume)
        }

        let snapshot = try await query.getDocuments()
        let comments = snapshot.documents.compactMap { document -> Comment? in
            let data = document.data()
            guard let authorID = data["authorId"] as? String, !authorID.isEmpty else { return nil }
            let replyTo: Comment.ReplyTarget?
            if let raw = data["replyTo"] as? [String: Any],
               let commentID = raw["commentId"] as? String {
                replyTo = Comment.ReplyTarget(
                    commentID: commentID,
                    authorName: raw["authorName"] as? String ?? ""
                )
            } else {
                replyTo = nil
            }
            return Comment(
                id: document.documentID,
                authorID: authorID,
                authorName: data["authorName"] as? String ?? "",
                authorAvatarURL: (data["authorAvatar"] as? String).flatMap(URL.init(string:)),
                text: data["text"] as? String ?? "",
                // A comment written a moment ago may not have its server
                // timestamp yet; showing it as "now" beats dropping it.
                createdAt: (data["createdAt"] as? PostDate)?.postDate ?? Date(),
                replyTo: replyTo,
                isPending: false
            )
        }

        var next: PageCursor?
        if snapshot.documents.count == limit, let last = snapshot.documents.last {
            let token = PageCursor()
            resumePoints[token] = last
            next = token
        }
        return Page(items: comments, next: next)
    }

    func create(postID: String, text: String, replyTo: String?) async throws -> String {
        var payload: [String: Any] = ["postId": postID, "text": text]
        if let replyTo { payload["replyToCommentId"] = replyTo }

        do {
            let result = try await functions.httpsCallable("createCommentCallable").call(payload)
            guard let data = result.data as? [String: Any], let id = data["id"] as? String else {
                // The call succeeded but the shape is not what the contract
                // says. Treated as unknown rather than success: we cannot point
                // at a comment, and a retry could duplicate.
                log.error("createCommentCallable returned an unexpected shape")
                throw CommentError.outcomeUnknown
            }
            return id
        } catch let error as CommentError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    /// Maps the callable's failures onto the gates in functions/src/posts.ts.
    ///
    /// The message is matched only where the same code means two different
    /// things — `not-found` is both "post" and "reply target", and they need
    /// different words on screen.
    static func map(_ error: Error) -> CommentError {
        let nsError = error as NSError
        guard nsError.domain == FunctionsErrorDomain,
              let code = FunctionsErrorCode(rawValue: nsError.code) else {
            // No response at all. Not retryable automatically: the callable has
            // no idempotency key, so a resend can post twice.
            return .outcomeUnknown
        }
        let message = nsError.localizedDescription.lowercased()

        switch code {
        case .unauthenticated:
            return .notSignedIn
        case .permissionDenied:
            if message.contains("verify") { return .emailNotVerified }
            if message.contains("banned") { return .banned }
            return .blockedFromAuthor
        case .notFound:
            return message.contains("reply") ? .replyTargetNotFound : .postNotFound
        case .resourceExhausted:
            return .rateLimited
        case .invalidArgument, .failedPrecondition, .outOfRange:
            // The server validates length (500 characters) and shape. These are
            // refusals of the content, not transport problems, and offering a
            // retry would be offering something that cannot work.
            return .rejected("That comment was not accepted. Check the length and try different wording.")
        case .deadlineExceeded, .unavailable, .cancelled:
            return .outcomeUnknown
        default:
            // The numeric code, not the SDK's message: that text is not ours
            // to show and is only ever used for logs.
            return .transport("functions/\(code.rawValue)")
        }
    }
}
