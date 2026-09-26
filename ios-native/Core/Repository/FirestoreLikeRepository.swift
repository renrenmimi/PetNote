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

    // MARK: - Fault injection (emulator builds only)

    /// The one like outcome the server cannot be asked to produce: a request
    /// that goes out, lands, and is never answered.
    ///
    /// 5A.10's deadline exists for exactly this case and nothing reachable
    /// through the UI can reach it — a server that is up either answers or
    /// refuses, and a server that is down refuses quickly. So the deadline was
    /// only ever exercised by a unit test over an injected fake, which proves
    /// the controller's arithmetic and says nothing about the screen.
    ///
    /// `writeThenNeverAnswer` is the honest shape of it. The like document is
    /// really created — the write is not skipped, faked or rolled back — and
    /// the client really never learns that it was. That is what makes the two
    /// questions this is here to answer answerable at all: what the screen
    /// does when the answer never comes, and whether the app wrote anything a
    /// second time while it was waiting.
    ///
    /// **Emulator-only, and gated at compile time rather than at runtime.**
    /// It was `#if DEBUG`, which is also true of Debug-TestCloud — the package
    /// that goes on the phone — so this switch was in it. The rule in
    /// `Config/Debug-Emulator.xcconfig` is that anything which makes the app
    /// misbehave is `PETNOTE_FAULT_INJECTION`; the package audit found this
    /// one on the wrong side of it. Now `scripts/fault-switches.sh` lists it
    /// and the audit proves it absent from the device package. Nothing in the
    /// app's own UI passes the flag.
    #if PETNOTE_FAULT_INJECTION
    enum Fault: String, CaseIterable {
        case writeThenNeverAnswer = "-petnote-like-lose-response"
    }

    private static var injectedFault: Fault? {
        let arguments = ProcessInfo.processInfo.arguments
        return Fault.allCases.first { arguments.contains($0.rawValue) }
    }

    /// Continuations from `neverAnswer()`, kept so that nothing resumes them
    /// and nothing reclaims them.
    ///
    /// A `CheckedContinuation` that is merely dropped is *diagnosed* — the
    /// runtime logs a continuation misuse — and a diagnostic is not what is
    /// being reproduced. Holding them is also the difference between a call
    /// that never returns and one that returns late: `Task.sleep` comes back
    /// as soon as the caller cancels, and `FeedViewModel.answer(for:)` cancels
    /// the abandoned work on its way out. Firestore's own calls make no
    /// promise to return early on cancellation, which is the situation the
    /// deadline was written for.
    private var parkedContinuations: [CheckedContinuation<Void, Never>] = []

    private func neverAnswer() async {
        await withCheckedContinuation { parkedContinuations.append($0) }
    }
    #endif

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
            #if PETNOTE_FAULT_INJECTION
            if Self.injectedFault == .writeThenNeverAnswer {
                // After the write, deliberately. The document exists and the
                // trigger will count it; what is being thrown away is only the
                // caller's knowledge that either happened.
                log.info("fault: the like was written and this call will never return")
                await neverAnswer()
            }
            #endif
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
