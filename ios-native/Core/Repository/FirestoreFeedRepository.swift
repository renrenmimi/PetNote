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

    func posts(after cursor: PageCursor?, limit: Int) async throws -> Page<Post> {
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
