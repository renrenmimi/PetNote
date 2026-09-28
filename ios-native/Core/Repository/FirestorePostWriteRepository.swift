import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OSLog

// MARK: - Contract
//
// **TEMPORARY LOCATION.** The ownership contract puts repository *protocols* in
// the coordinator's half of `Core/Repository`. `PostWriteRepository` and the
// value types below belong in that shared file; they live here so this line can
// ship without editing somebody else's, and they are written to be moved
// wholesale rather than rewritten.

/// One publish attempt, identified by the id that makes it idempotent.
struct PublishRequest: Sendable, Equatable {
    /// Stable across every retry of this submission.
    ///
    /// The server derives the post's document id from `sha256(uid:operationId)`
    /// and writes with `.create()`, so a retry after a lost response returns the
    /// post the first attempt made instead of publishing a second one. This
    /// field is the entire reason a retry is safe; a fresh id per attempt gives
    /// back the duplicate-posting bug it was introduced to fix.
    let operationID: String
    let text: String
    let tags: [String]
    /// Required. `createPostCallable` refuses a post with no pet, and so does
    /// the composer, earlier and with better words.
    let petID: String
    let media: [UploadedAsset]
}

struct PublishOutcome: Sendable, Equatable {
    let postID: String
    /// True when this operation id had already published and the server handed
    /// back the earlier post. Not an error — it is the retry working.
    let deduplicated: Bool
}

/// The answer from `getPublishStatusCallable`.
///
/// **`notVisibleYet` is not "never published".** It is document existence at one
/// instant, and nothing cancelled the original request: a publish paused just
/// before its `.create()` answers this and then commits. Sound for telling
/// somebody "your earlier post did go through"; never sound as permission to
/// delete media. The server's own doc comment says exactly this, and
/// `AssetReclaim` is what stops the client acting otherwise.
enum PublishStatus: Sendable, Equatable {
    case published(postID: String)
    case notVisibleYet
}

/// Whether a bookmark write changed anything.
///
/// Three states for the same reason `LikeMutationResult` has three: a silent
/// "nothing happened" is indistinguishable from success at the call site, and
/// the UI has to be able to tell "already saved" from "that post is gone".
enum BookmarkResult: Sendable, Equatable {
    case changed
    case unchanged
    case postNotFound
}

/// One case per gate the post callables enforce, in the order the server checks
/// them (functions/src/posts.ts).
enum PostWriteError: Error, Sendable, Equatable {
    case notSignedIn
    case emailNotVerified
    case banned
    /// The caller has no access to the pet they named.
    case petNotAccessible
    case postNotFound
    case notTheAuthor
    case rateLimited
    /// The server refused the content itself. Never retryable: the same text
    /// will be refused again.
    case rejected(String)

    /// The request went out and no answer came back.
    ///
    /// **For publishing this is safe to retry, and that is the whole point of
    /// `operationID`.** It is the opposite of `CommentError.outcomeUnknown`,
    /// which must never be retried because `createCommentCallable` has no
    /// idempotency key — the two look identical and need opposite handling, so
    /// they are deliberately separate types rather than one shared enum.
    ///
    /// For update / delete / pin it is equally safe: each of those is a set or
    /// a delete against a known id, so repeating one reaches the same state.
    case outcomeUnknown

    case transport(String)
}

protocol PostWriteRepository: Sendable {
    /// At most one post per `operationID`, however many times this is called.
    func publish(_ request: PublishRequest) async throws -> PublishOutcome

    /// Informational only. Must not be used to authorise deleting media.
    func publishStatus(operationID: String) async throws -> PublishStatus

    /// Text, tags and pet. Media is not editable after posting — the web
    /// client says so on the screen and the callable takes no media field.
    func update(postID: String, text: String, tags: [String], petID: String) async throws

    func delete(postID: String) async throws

    /// `nil` unpins. Mirrors `setPinnedPostCallable`, which reads a missing or
    /// null postId as "unpin".
    func setPinned(postID: String?) async throws

    /// Bookmarks are the client-direct-write exception, like likes: the rules
    /// allow the owner to create and delete `users/{uid}/bookmarks/{postId}`.
    func bookmark(postID: String) async throws -> BookmarkResult
    func unbookmark(postID: String) async throws -> BookmarkResult
    func isBookmarked(postID: String) async throws -> Bool
}

/// A stable id for one publish attempt, reused across its retries.
///
/// Hex from a UUID with the dashes removed: 32 characters of `[0-9a-f]`, which
/// sits inside the server's `8-64 characters of A-Z, a-z, 0-9, - or _`. Not
/// security-sensitive — it only has to be unlikely to collide with this
/// person's other submissions — but it *is* correctness-sensitive, because an
/// id the server rejects turns every publish into an invalid-argument.
enum OperationID {
    static func new() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The server's rule, mirrored so a restored draft carrying a malformed id
    /// is caught here rather than by an `invalid-argument` at publish time.
    static func isValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...64).contains(trimmed.count) else { return false }
        return trimmed.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber
                || character == "-" || character == "_")
        }
    }
}

// MARK: - Implementation

/// Post writes: everything through a callable, except bookmarks.
///
/// The split is the rules'. `posts/**` refuses a direct client write, so create
/// / update / delete / pin all go through callables that enforce the gates.
/// `users/{uid}/bookmarks/{postId}` is explicitly owner-writable, so a bookmark
/// is a direct write — and a **create-only** one: the rule says
/// `allow update: if false`, which is why bookmarking something already
/// bookmarked reads first and reports `.unchanged` instead of writing again.
actor FirestorePostWriteRepository: PostWriteRepository {
    private let db: Firestore
    private let auth: Auth
    private let functions: Functions
    private let environment: AppEnvironment
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "postwrite")

    init(
        db: Firestore = .firestore(),
        auth: Auth = .auth(),
        functions: Functions = .functions(),
        environment: AppEnvironment = .current
    ) {
        self.db = db
        self.auth = auth
        self.functions = functions
        self.environment = environment
    }

    private func currentUID() throws -> String {
        guard let uid = auth.currentUser?.uid else { throw PostWriteError.notSignedIn }
        return uid
    }

    /// Every callable goes through `Core/Backend/CallableClient`, which owns
    /// the `sending` payload rule: a `[String: Any]` built inside this actor
    /// belongs to it, and handing it to the SDK's `@concurrent` method is a
    /// data race the compiler refuses. The payload is therefore constructed at
    /// the call site and given up, never stored.
    ///
    /// The one thing added here is the pre-flight refusal, which is this
    /// repository's to make: on a device pointed at a local emulator the
    /// Functions SDK will not attach an auth token to a plaintext request, so
    /// the call cannot succeed and is better refused with a reason than sent
    /// and misreported as a sign-in problem.
    private func callable(
        _ name: String, _ payload: sending [String: Any]
    ) async throws -> [String: Any] {
        guard environment.supportsCallables else {
            throw PostWriteError.transport(CallableTransport.unavailable)
        }
        do {
            return try await CallableClient.call(name, payload, functions: functions)
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: Publish

    func publish(_ request: PublishRequest) async throws -> PublishOutcome {
        guard OperationID.isValid(request.operationID) else {
            // Caught here rather than at the server, where it arrives as a
            // generic invalid-argument that reads like the post's content was
            // the problem.
            throw PostWriteError.rejected("This draft could not be identified. Start a new post.")
        }
        let payload: [String: Any] = [
            "text": request.text,
            "tags": request.tags,
            "media": request.media.map(\.callablePayload),
            "petId": request.petID,
            "operationId": request.operationID,
        ]
        let data = try await callable(Callables.createPost, payload)
        guard let postID = data["id"] as? String, !postID.isEmpty else {
            // The call returned, so the post may exist; we simply cannot name
            // it. Reported as unknown rather than as success, and safe to
            // retry — the operation id is what makes that true.
            log.error("createPostCallable returned an unexpected shape")
            throw PostWriteError.outcomeUnknown
        }
        return PublishOutcome(postID: postID, deduplicated: data["deduplicated"] as? Bool == true)
    }

    func publishStatus(operationID: String) async throws -> PublishStatus {
        let data = try await callable(Callables.getPublishStatus, ["operationId": operationID])
        if data["published"] as? Bool == true, let postID = data["postId"] as? String {
            return .published(postID: postID)
        }
        return .notVisibleYet
    }

    // MARK: Manage

    func update(postID: String, text: String, tags: [String], petID: String) async throws {
        _ = try await callable(Callables.updatePost, [
            "postId": postID, "text": text, "tags": tags, "petId": petID,
        ])
    }

    func delete(postID: String) async throws {
        _ = try await callable(Callables.deletePost, ["postId": postID])
    }

    func setPinned(postID: String?) async throws {
        // NSNull, not an omitted key: the callable reads null and missing the
        // same way, but sending the key makes "unpin" explicit at the wire and
        // stops a future server that distinguishes them from surprising us.
        _ = try await callable(Callables.setPinnedPost, ["postId": postID ?? NSNull()])
    }

    // MARK: Bookmarks (client-direct, by the rules)

    private func bookmarkRef(uid: String, postID: String) -> DocumentReference {
        db.collection("users").document(uid).collection("bookmarks").document(postID)
    }

    func bookmark(postID: String) async throws -> BookmarkResult {
        guard let validID = DeepLink.validDocumentID(postID) else { return .postNotFound }
        let uid = try currentUID()
        let reference = bookmarkRef(uid: uid, postID: validID)
        do {
            // Read first because the rule is create-only. A `setData(merge:)`
            // over an existing bookmark is an *update* as far as the rules are
            // concerned, and updates are denied — so the web client's
            // re-bookmark silently fails there, and here it reports the truth.
            if try await reference.getDocument().exists { return .unchanged }
            try await reference.setData([
                "postId": validID,
                "createdAt": FieldValue.serverTimestamp(),
            ])
            return .changed
        } catch {
            // The create rule requires the post to exist. That is the likeliest
            // reason for a refusal, and it is worth one read to say so rather
            // than showing a ban message to somebody whose post was deleted
            // while they were looking at it.
            if Self.isPermissionDenied(error) {
                let postExists = (try? await db.collection("posts").document(validID).getDocument().exists) ?? true
                if !postExists { return .postNotFound }
                throw PostWriteError.banned
            }
            throw Self.map(error)
        }
    }

    func unbookmark(postID: String) async throws -> BookmarkResult {
        guard let validID = DeepLink.validDocumentID(postID) else { return .postNotFound }
        let uid = try currentUID()
        let reference = bookmarkRef(uid: uid, postID: validID)
        do {
            guard try await reference.getDocument().exists else { return .unchanged }
            try await reference.delete()
            return .changed
        } catch {
            throw Self.map(error)
        }
    }

    func isBookmarked(postID: String) async throws -> Bool {
        guard let validID = DeepLink.validDocumentID(postID) else { return false }
        let uid = try currentUID()
        do {
            return try await bookmarkRef(uid: uid, postID: validID).getDocument().exists
        } catch {
            throw Self.map(error)
        }
    }

    static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == FirestoreErrorDomain
            && nsError.code == FirestoreErrorCode.permissionDenied.rawValue
    }

    /// Maps a callable failure onto the gates in functions/src/posts.ts.
    ///
    /// The message is matched only where one code means two different things.
    /// `permission-denied` is four gates — unverified email, banned, no access
    /// to the pet, not the author — and they need four different sentences.
    static func map(_ error: Error) -> PostWriteError {
        let nsError = error as NSError
        guard nsError.domain == FunctionsErrorDomain,
              let code = FunctionsErrorCode(rawValue: nsError.code) else {
            // Everything that never left the device arrives in its original
            // domain. A publish is idempotent, so even the genuinely ambiguous
            // ones are safe to retry; they are still reported honestly rather
            // than as success.
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorNotConnectedToInternet
                || nsError.code == NSURLErrorCannotConnectToHost
                || nsError.code == NSURLErrorDNSLookupFailed {
                return .transport("offline")
            }
            return .outcomeUnknown
        }
        let message = nsError.localizedDescription.lowercased()
        switch code {
        case .unauthenticated:
            return message.contains(CallableTransport.plaintextTokenRefusal)
                ? .transport(CallableTransport.unavailable)
                : .notSignedIn
        case .permissionDenied:
            if message.contains("verify") { return .emailNotVerified }
            if message.contains("banned") { return .banned }
            if message.contains("pet") { return .petNotAccessible }
            return .notTheAuthor
        case .notFound:
            return .postNotFound
        case .resourceExhausted:
            return .rateLimited
        case .invalidArgument, .outOfRange:
            return .rejected("That post was not accepted. Check the length and try different wording.")
        case .failedPrecondition:
            return .rejected("That post was not accepted.")
        case .deadlineExceeded, .unavailable, .cancelled, .aborted, .`internal`:
            return .outcomeUnknown
        default:
            return .transport("functions/\(code.rawValue)")
        }
    }
}
