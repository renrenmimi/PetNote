import FirebaseAuth
import FirebaseFirestore
import Foundation
import OSLog

/// Likes.
///
/// Two invariants from the rules and the server's own comments, both of which
/// have teeth:
///
///  1. **The client writes `counted: false`.** `onLikeCreated` flips it to true
///     in the same transaction that moves `likeCount`. The field used to be
///     optional, and `shared.ts` read *absent* as *already counted*; writing a
///     like without it, then deleting it before the trigger ran, made
///     `onLikeDeleted` apply `increment(-1)` for a like that had never been
///     counted. Net −1 on someone else's post, repeatable.
///  2. **The count is never written from here.** Optimistic updates change what
///     is on screen and nothing else.
actor FirestoreLikeRepository: LikeRepository {
    private let db: Firestore
    private let auth: Auth
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "feed")

    /// Firestore's `in` operator takes at most 30 values.
    private static let inQueryLimit = 30

    init(db: Firestore = .firestore(), auth: Auth = .auth()) {
        self.db = db
        self.auth = auth
    }

    private func currentUID() throws -> String {
        guard let uid = auth.currentUser?.uid else { throw LikeError.notSignedIn }
        return uid
    }

    func like(postID: String) async throws -> LikeMutationResult {
        guard let validID = DeepLink.validDocumentID(postID) else { return .postNotFound }
        let uid = try currentUID()

        // Existence is checked before the write, as the web client does, so a
        // like on a deleted post is reported rather than silently dropped.
        let post = db.collection("posts").document(validID)
        guard try await post.getDocument().exists else { return .postNotFound }

        let like = post.collection("likes").document(uid)

        // Deliberately not a transaction, for two reasons that point the same
        // way. The rules allow `create` and `delete` on a like and say nothing
        // about `update`, so they deny it: a second write to a like that
        // already exists is refused by the server, which makes the rules
        // themselves the concurrency guard. And Firestore's transaction block
        // is not isolated to this actor, so handing it `db` is a data race the
        // compiler is right to refuse.
        if try await like.getDocument().exists { return .unchanged }

        do {
            try await like.setData([
                "userId": uid,
                "postId": validID,
                "createdAt": FieldValue.serverTimestamp(),
                // Required by the rules, and false is the only value accepted.
                // See this type's documentation for what the alternative cost.
                "counted": false,
            ])
            return .changed
        } catch {
            let nsError = error as NSError
            log.error("""
                like write failed: domain=\(nsError.domain, privacy: .public) \
                code=\(nsError.code) desc=\(nsError.localizedDescription, privacy: .public)
                """)
            // Lost a race with another client: the document now exists, so the
            // write became an update and was denied. The server is in the state
            // the caller wanted, and the count already reflects it.
            if Self.isPermissionDenied(error), try await like.getDocument().exists {
                log.debug("like already present; treating denial as unchanged")
                return .unchanged
            }
            throw error
        }
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == FirestoreErrorDomain
            && nsError.code == FirestoreErrorCode.permissionDenied.rawValue
    }

    func unlike(postID: String) async throws -> LikeMutationResult {
        guard let validID = DeepLink.validDocumentID(postID) else { return .postNotFound }
        let uid = try currentUID()
        let like = db.collection("posts").document(validID).collection("likes").document(uid)

        guard try await like.getDocument().exists else { return .unchanged }
        // Only the like document is removed; `onLikeDeleted` owns the count.
        try await like.delete()
        return .changed
    }

    /// One collection-group query per 30 posts, not one query per post.
    ///
    /// The web client already made this trade (`useBatchLikeStatus`), and the
    /// engineering spec calls out not regressing to N+1 — every extra read here
    /// is paid for on every screenful, by every user.
    func likedPostIDs(among postIDs: [String]) async throws -> Set<String> {
        guard !postIDs.isEmpty else { return [] }
        let uid = try currentUID()
        let valid = postIDs.compactMap(DeepLink.validDocumentID)

        var liked: Set<String> = []
        for chunk in stride(from: 0, to: valid.count, by: Self.inQueryLimit).map({
            Array(valid[$0..<min($0 + Self.inQueryLimit, valid.count)])
        }) {
            // Collection-group reads of likes are restricted to your own by the
            // rules, so this query is only ever answerable for the caller.
            let snapshot = try await db.collectionGroup("likes")
                .whereField("userId", isEqualTo: uid)
                .whereField("postId", in: chunk)
                .getDocuments()
            for document in snapshot.documents {
                if let postID = document.data()["postId"] as? String { liked.insert(postID) }
            }
        }
        log.debug("batched like status for \(valid.count) posts in \((valid.count + Self.inQueryLimit - 1) / Self.inQueryLimit) queries")
        return liked
    }
}

enum LikeError: Error, Sendable {
    case notSignedIn
}
