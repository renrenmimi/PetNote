import FirebaseAuth
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

    private let environment: AppEnvironment

    init(
        db: Firestore = .firestore(),
        functions: Functions = .functions(),
        environment: AppEnvironment = .current
    ) {
        self.db = db
        self.functions = functions
        self.environment = environment
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

    /// Fault injection for the two send outcomes that cannot be produced by
    /// asking the server for them.
    ///
    /// §5C.10 asks for an *injected* lost response, and there is no other way
    /// to get one: the server either answers or it does not, and a test cannot
    /// make a successful answer go missing on the wire. `loseResponseAfterWrite`
    /// is the honest shape of that — the write really happens, and the client
    /// really never learns the outcome — which is what makes "did it land?"
    /// checkable against the server afterwards.
    ///
    /// Debug-only and argument-gated, like `-petnote-start-signed-out`: a
    /// release build has no code that can reach these, and nothing in the app's
    /// own UI passes them.
    #if DEBUG
    enum Fault: String, CaseIterable {
        /// Let the callable run, then throw the answer away.
        case loseResponseAfterWrite = "-petnote-comment-lose-response"
        /// Fail before anything is sent, the way no connection does.
        case neverSend = "-petnote-comment-offline"
        /// The request is abandoned before it is sent, and reported as an
        /// outcome nobody knows.
        ///
        /// The other half of `loseResponseAfterWrite`. That one covers an
        /// unknown outcome that *did* land, and the app resolves it by
        /// looking. This one covers the unknown outcome that did **not** land,
        /// which is the branch where the temptation to resend is strongest and
        /// where a resend would be free of consequence — so it is the branch
        /// that has to be shown never resending, and shown keeping the text.
        ///
        /// Injected rather than provoked, for the same reason as the other:
        /// a server that is reachable either answers or refuses, and neither
        /// is this.
        case loseRequestBeforeWrite = "-petnote-comment-lose-request"
    }

    private static var injectedFault: Fault? {
        let arguments = ProcessInfo.processInfo.arguments
        return Fault.allCases.first { arguments.contains($0.rawValue) }
    }
    #endif

    func create(postID: String, text: String, replyTo: String?) async throws -> String {
        var payload: [String: Any] = ["postId": postID, "text": text]
        if let replyTo { payload["replyToCommentId"] = replyTo }

        // Known in advance for a device pointed at a local emulator: the
        // request cannot carry credentials, so it cannot succeed. Refused here
        // rather than sent and misreported. The composer stays usable — the
        // person gets a reason, not a disabled control.
        guard environment.supportsCallables else {
            log.error("callables are unreachable from this build; refusing to send")
            throw CommentError.transport(Transport.unavailable)
        }

        #if DEBUG
        if Self.injectedFault == .neverSend {
            log.info("fault: refusing to send, as if there were no connection")
            throw Self.map(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        }
        if Self.injectedFault == .loseRequestBeforeWrite {
            // Nothing is written and nothing is claimed about it. The point is
            // the client's policy, not the server's state: the text has to
            // survive and nothing may go out again on its own.
            log.info("fault: abandoning the request and reporting an unknown outcome")
            throw CommentError.outcomeUnknown
        }
        #endif

        do {
            let user = Auth.auth().currentUser
            let token = try? await user?.getIDToken()
            log.info("""
                create: uid=\(user?.uid.prefix(6) ?? "nil", privacy: .public) \
                verified=\(user?.isEmailVerified == true) \
                tokenLength=\(token?.count ?? 0)
                """)
            let result = try await functions.httpsCallable("createCommentCallable").call(payload)
            guard let data = result.data as? [String: Any], let id = data["id"] as? String else {
                // The call succeeded but the shape is not what the contract
                // says. Treated as unknown rather than success: we cannot point
                // at a comment, and a retry could duplicate.
                log.error("createCommentCallable returned an unexpected shape")
                throw CommentError.outcomeUnknown
            }
            #if DEBUG
            if Self.injectedFault == .loseResponseAfterWrite {
                // The comment exists. We are throwing away the only thing that
                // said so, which is exactly what a dropped response does.
                log.info("fault: discarding a successful createCommentCallable response")
                throw CommentError.outcomeUnknown
            }
            #endif
            return id
        } catch let error as CommentError {
            throw error
        } catch {
            let nsError = error as NSError
            log.error("""
                create failed: domain=\(nsError.domain, privacy: .public) \
                code=\(nsError.code) \
                desc=\(nsError.localizedDescription, privacy: .public) \
                keys=\(nsError.userInfo.keys.map(String.init(describing:)).joined(separator: ","), privacy: .public)
                """)
            throw Self.map(error)
        }
    }

    /// Detail strings carried by `CommentError.transport`.
    ///
    /// `transport` already exists to carry a machine-readable reason for logs;
    /// this names the one the UI also has different words for. It is not a gate
    /// in the callable, so it is not a case of its own in `CommentError` —
    /// being offline is a transport fact, which is exactly what this case is.
    enum Transport {
        /// The request never left the device, and the send is therefore a
        /// certain failure that is safe to repeat.
        static let offline = "offline"

        /// This build cannot reach the callables at all.
        ///
        /// The Functions SDK refuses to put an auth token on a plaintext HTTP
        /// request to a non-loopback host, so a device talking to a local
        /// emulator over its LAN address never sends the request — it throws
        /// `unauthenticated` with the SDK's own words. A simulator is
        /// unaffected because it reaches the emulator on 127.0.0.1.
        ///
        /// A **certain** failure, and never retryable: the same build on the
        /// same network will refuse again, every time. Reporting it as a
        /// session problem, as `unauthenticated` otherwise would, sends the
        /// person to sign in again over and over for something that is not
        /// about them.
        static let unavailable = "callables-unavailable"
    }

    /// The SDK's own message when it refuses to attach tokens. Matched because
    /// the code it throws — `unauthenticated` — is the same one a genuinely
    /// signed-out caller gets, and the two need opposite handling.
    /// See Functions.swift `shouldAttachTokens`.
    private static let plaintextTokenRefusal = "refusing to send auth"

    /// URL errors that mean nothing was ever put on the wire.
    ///
    /// The distinction is the whole reason this list is explicit rather than
    /// "any NSURLError": a send that never left the device did not create a
    /// comment and can be repeated safely, while a send whose *response* was
    /// lost may have created one and must not be. The excluded codes are the
    /// ambiguous ones, and they stay ambiguous:
    ///
    ///   - `-1005` networkConnectionLost — the request may already have been
    ///     delivered and only the answer lost;
    ///   - `-1001` timedOut (the Functions SDK turns this into
    ///     `.deadlineExceeded` before we see it) — same;
    ///   - `-999` cancelled — we do not know how far it got.
    private static let neverSentURLErrorCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorDataNotAllowed,
        NSURLErrorCallIsActive,
        NSURLErrorSecureConnectionFailed,
    ]

    /// Maps the callable's failures onto the gates in functions/src/posts.ts.
    ///
    /// The message is matched only where the same code means two different
    /// things — `not-found` is both "post" and "reply target", and they need
    /// different words on screen.
    static func map(_ error: Error) -> CommentError {
        let nsError = error as NSError
        guard nsError.domain == FunctionsErrorDomain,
              let code = FunctionsErrorCode(rawValue: nsError.code) else {
            // The Functions SDK only rewrites two kinds of failure into its own
            // domain — a GTMSessionFetcher status, and NSURLErrorTimedOut into
            // `.deadlineExceeded` (Functions.swift `processedError`). Everything
            // else arrives here in its original domain, which is how a plain
            // "not connected to the internet" used to land in the branch below
            // and be reported as an outcome we could not determine. It is not:
            // the request never went out, so nothing was created and repeating
            // it cannot duplicate anything.
            if nsError.domain == NSURLErrorDomain,
               neverSentURLErrorCodes.contains(nsError.code) {
                return .transport(Transport.offline)
            }
            // No response at all. Not retryable automatically: the callable has
            // no idempotency key, so a resend can post twice.
            return .outcomeUnknown
        }
        let message = nsError.localizedDescription.lowercased()

        switch code {
        case .unauthenticated:
            // Told apart by the message, because the SDK reports "this build
            // cannot send credentials at all" with the same code as "you are
            // not signed in".
            if message.contains(plaintextTokenRefusal) {
                return .transport(Transport.unavailable)
            }
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
