import FirebaseFirestore
import Foundation
import OSLog

/// Reads the feed, mirroring `getPosts` (src/services/posts.ts:195):
/// `orderBy("createdAt","desc")` paged with a document-snapshot cursor.
///
/// An actor because it owns the snapshots the opaque cursors stand for. A
/// `DocumentSnapshot` is not `Sendable`, so keeping them here is what lets the
/// rest of the app hand cursors around under complete strict concurrency.
actor FirestoreFeedRepository: FeedRepository {
    private let db: Firestore
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "feed")

    /// Cursor → the document to resume after. Cleared whenever a fresh first
    /// page is requested, so this cannot grow without bound across a session.
    private var resumePoints: [PageCursor: DocumentSnapshot] = [:]

    init(db: Firestore = .firestore()) {
        self.db = db
    }

    // MARK: - Fault injection

    /// The refresh and paging outcomes a healthy local emulator cannot be
    /// asked for.
    ///
    /// The previous round reported the behaviours below as "fixed, but not
    /// reproducible on the simulator", the reason given being that a loopback
    /// round trip is 90ms. That is a reason the *observation* failed, not a
    /// reason the behaviour cannot be checked: a query that succeeds cannot be
    /// talked into failing, and a window 90ms wide cannot be sampled — so both
    /// have to be made, not waited for. These make them.
    ///
    /// Two properties every one of these has, on purpose:
    ///
    ///   - **one-shot.** A fault that fires forever cannot show a retry
    ///     working, and "the retry worked" is half of what is being checked.
    ///   - **the injected answer is distinguishable.** A stalled refresh comes
    ///     back *empty*, so a test that samples after the stall rather than
    ///     during it sees an empty feed and fails. A pass cannot be bought by
    ///     reading the screen too late, which is exactly how the last round's
    ///     evidence went wrong.
    ///
    /// `#if PETNOTE_FAULT_INJECTION` and a `-petnote-` name, both deliberately.
    ///
    /// The condition rather than `DEBUG`: `Debug-TestCloud` is a Debug
    /// configuration and is the package that goes on the owner's phone, so
    /// `#if DEBUG` would put "make this refresh fail" in the acceptance build.
    /// Only `Debug-Emulator` defines `PETNOTE_FAULT_INJECTION`, and these
    /// tests only ever run there.
    ///
    /// The name because absence has to be provable rather than asserted:
    /// `scripts/build-testcloud-package.sh` greps the built binary for
    /// `petnote[A-Za-z-]+`, so a switch called `failNextPage` would be
    /// invisible to the only tool that can check the claim.
    #if PETNOTE_FAULT_INJECTION
    enum Fault: String, CaseIterable, Sendable {
        /// Pages of four instead of twenty, so the second page is requested
        /// without a person having to scroll past twenty cards to ask for it.
        case tinyPages = "-petnote-feed-tiny-pages"
        /// The first refresh stalls, and then answers empty.
        case stallThenEmptyRefresh = "-petnote-feed-refresh-stalls-then-empties"
        /// The first refresh fails outright.
        case failRefreshOnce = "-petnote-feed-refresh-fails-once"
        /// The first cursored read fails. Retrying the same cursor works.
        case failNextPageOnce = "-petnote-feed-next-page-fails-once"
    }

    /// All of them, not the first match: a useful scenario needs two at once
    /// (`tinyPages` to make page two reachable, and a failure to inject into
    /// it), and `first(where:)` would silently honour one and drop the other.
    private static var injectedFaults: Set<Fault> {
        let arguments = ProcessInfo.processInfo.arguments
        return Set(Fault.allCases.filter { arguments.contains($0.rawValue) })
    }

    private static let stall = Duration.seconds(8)
    private static let tinyPageSize = 4

    /// Faults already fired. Actor state, so "once" means once per process.
    private var spent: Set<Fault> = []
    /// How many first-page reads have been answered. The first is the screen
    /// filling up; anything after it is a refresh, and a fault that ate the
    /// first load would leave nothing on screen to prove anything about.
    private var firstPageReads = 0

    /// A fault this read should answer with instead of going to Firestore.
    ///
    /// Returns nil when there is nothing to inject, throws when the injected
    /// answer is a failure, and returns a page when it is a stall.
    private func injectedAnswer(for cursor: PageCursor?) async throws -> Page<Post>? {
        let faults = Self.injectedFaults.subtracting(spent)
        let isRefresh = cursor == nil && firstPageReads > 0

        // Failure before stall, and the order is load-bearing: the two are
        // armed together to build one interleaving — a refresh that fails so
        // the banner's retry can start a *second* one, which stalls long
        // enough for a third to overtake it. Checked the other way round, the
        // first pull would stall and there would be no banner to drive the
        // second from.
        if isRefresh, faults.contains(.failRefreshOnce) {
            spent.insert(.failRefreshOnce)
            log.info("fault: failing a refresh")
            throw Self.injectedFailure
        }
        if isRefresh, faults.contains(.stallThenEmptyRefresh) {
            spent.insert(.stallThenEmptyRefresh)
            log.info("fault: stalling a refresh, then answering empty")
            try? await Task.sleep(for: Self.stall)
            resumePoints.removeAll()
            return .empty
        }
        if cursor != nil, faults.contains(.failNextPageOnce) {
            spent.insert(.failNextPageOnce)
            log.info("fault: failing one cursored read")
            throw Self.injectedFailure
        }
        return nil
    }

    /// Shaped like what Firestore reports for a refused or unavailable query,
    /// so `FeedViewModel.kind(of:)` sorts it the same way a real one would.
    private static var injectedFailure: Error {
        NSError(
            domain: "FIRFirestoreErrorDomain", code: 13,
            userInfo: [NSLocalizedDescriptionKey: "injected feed failure"]
        )
    }
    #endif

    func posts(after cursor: PageCursor?, limit requestedLimit: Int) async throws -> Page<Post> {
        #if PETNOTE_FAULT_INJECTION
        if let injected = try await injectedAnswer(for: cursor) { return injected }
        if cursor == nil { firstPageReads += 1 }
        let limit = Self.injectedFaults.contains(.tinyPages) ? Self.tinyPageSize : requestedLimit
        #else
        let limit = requestedLimit
        #endif

        if cursor == nil { resumePoints.removeAll() }

        var query: Query = db.collection("posts")
            .order(by: "createdAt", descending: true)
            .limit(to: limit)

        if let cursor {
            guard let resume = resumePoints[cursor] else {
                // A cursor this repository did not issue, or one from a session
                // that has been torn down. Starting over is safer than guessing.
                log.error("unknown feed cursor; restarting from the first page")
                return try await posts(after: nil, limit: limit)
            }
            query = query.start(afterDocument: resume)
        }

        let snapshot = try await query.getDocuments()
        let posts = snapshot.documents.compactMap {
            PostDecoder.post(id: $0.documentID, from: $0.data())
        }
        if posts.count != snapshot.documents.count {
            // Not fatal — a malformed document must not cost the page — but it
            // is a contract violation and should be visible.
            log.error("dropped \(snapshot.documents.count - posts.count) undecodable post(s)")
        }

        // `hasMore` is "the page came back full", exactly as the web client has
        // it. A full last page yields one more request that returns nothing,
        // which is the honest reading of what the server told us.
        var next: PageCursor?
        if snapshot.documents.count == limit, let last = snapshot.documents.last {
            let token = PageCursor()
            resumePoints[token] = last
            next = token
        }
        return Page(items: posts, next: next)
    }

    func post(id: String) async throws -> Post? {
        guard let validID = DeepLink.validDocumentID(id) else { return nil }
        let document = try await db.collection("posts").document(validID).getDocument()
        guard document.exists, let data = document.data() else { return nil }
        return PostDecoder.post(id: document.documentID, from: data)
    }
}
