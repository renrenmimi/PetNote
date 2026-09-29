import FirebaseFirestore
import Foundation
import OSLog

/// Reads the feed's "Following" tab, mirroring `getFollowingPosts`
/// (src/services/posts.ts:255).
///
/// Firestore's `in` takes at most thirty values, so the pets are asked about
/// thirty at a time and the answers merged (`FollowingPage`). Every query is
/// ordered by `createdAt` and then the document id, both descending, and the
/// merge sorts the same way, so the two agree on what comes next. A page
/// resumes after the (createdAt, id) of the last post it showed rather than
/// after a document snapshot, which belongs to the one query that returned
/// it; the web's source says why a plain `createdAt <` would not do: posts
/// that share a timestamp would be skipped.
///
/// The index this needs — `petId` ascending, `createdAt` and `__name__`
/// descending — is in `firestore.indexes.json`, and was READY on
/// `petnote-devtest` when read on 2026-09-28.
actor FirestoreFollowingPostsRepository: FollowingPostsReading {
    private let db: Firestore
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "feed")

    /// Cursor → where to resume. Cleared by every first page, so this cannot
    /// grow without bound across a session.
    private var resumePoints: [PageCursor: FollowingPage.Position] = [:]

    init(db: Firestore = .firestore()) {
        self.db = db
    }

    func posts(ofPets petIDs: [String], after cursor: PageCursor?, limit: Int) async throws -> Page<Post> {
        let pets = FollowingPage.distinct(petIDs)
        guard !pets.isEmpty, limit > 0 else { return .empty }
        if cursor == nil { resumePoints.removeAll() }

        var after: FollowingPage.Position?
        if let cursor {
            guard let position = resumePoints[cursor] else {
                // A cursor this repository did not issue, or one from before a
                // refresh. Starting over is safer than guessing.
                log.error("unknown following cursor; restarting from the first page")
                return try await posts(ofPets: pets, after: nil, limit: limit)
            }
            after = position
        }

        var candidates: [FollowingPage.Candidate] = []
        var undecodable = 0
        for chunk in FollowingPage.chunks(of: pets) {
            var query: Query = db.collection("posts")
                .whereField("petId", in: chunk)
                .order(by: "createdAt", descending: true)
                .order(by: FieldPath.documentID(), descending: true)
            if let after {
                query = query.start(after: [
                    Timestamp(seconds: after.seconds, nanoseconds: after.nanoseconds), after.id,
                ])
            }
            let snapshot = try await query.limit(to: limit + FollowingPage.extraPerQuery).getDocuments()
            for document in snapshot.documents {
                let data = document.data()
                guard let createdAt = data["createdAt"] as? Timestamp,
                      let post = PostDecoder.post(id: document.documentID, from: data) else {
                    undecodable += 1
                    continue
                }
                candidates.append(FollowingPage.Candidate(
                    post: post,
                    position: FollowingPage.Position(
                        seconds: createdAt.seconds, nanoseconds: createdAt.nanoseconds, id: document.documentID
                    )
                ))
            }
        }
        if undecodable > 0 {
            // Not fatal — a malformed document must not cost the page — but it
            // is a contract violation and should be visible.
            log.error("dropped \(undecodable) undecodable post(s) from the following feed")
        }

        let page = FollowingPage.merge(candidates, limit: limit)
        // "The page came back full", as everywhere else in this app.
        var next: PageCursor?
        if page.count == limit, let last = page.last {
            let token = PageCursor()
            resumePoints[token] = last.position
            next = token
        }
        return Page(items: page.map(\.post), next: next)
    }
}

/// The merge `getFollowingPosts` does after its chunked queries, without
/// Firebase in it, so it can be checked on its own.
enum FollowingPage {
    /// Firestore's limit on the values of one `in`.
    static let chunkSize = 30
    /// `perChunkLimit = limitCount + 5`: what each query asks for beyond a page,
    /// so a page is still full after the merge takes out what overlaps.
    static let extraPerQuery = 5

    /// Where a post sits in the order: `createdAt` to the nanosecond — a `Date`
    /// would round it, and a cursor a little off skips or repeats the post it
    /// was taken from — then the document id.
    struct Position: Sendable, Hashable {
        let seconds: Int64
        let nanoseconds: Int32
        let id: String
    }

    struct Candidate: Sendable {
        let post: Post
        let position: Position
    }

    /// The ids a query can be asked about, each once, in the order given.
    static func distinct(_ petIDs: [String]) -> [String] {
        var seen: Set<String> = []
        return petIDs.compactMap(DeepLink.validDocumentID).filter { seen.insert($0).inserted }
    }

    static func chunks(of petIDs: [String]) -> [[String]] {
        stride(from: 0, to: petIDs.count, by: chunkSize).map {
            Array(petIDs[$0..<min($0 + chunkSize, petIDs.count)])
        }
    }

    /// Each post once, newest first, the id breaking a tie, and a page of them.
    ///
    /// Ids are compared by their UTF-8 bytes, which is how Firestore orders
    /// them. The web compares them with `localeCompare`, which can disagree
    /// with the server for ids that differ only in case; that matters only for
    /// posts sharing a timestamp, and here the server's order wins.
    static func merge(_ candidates: [Candidate], limit: Int) -> [Candidate] {
        var seen: Set<String> = []
        let unique = candidates.filter { seen.insert($0.position.id).inserted }
        return Array(unique.sorted { comesFirst($0.position, $1.position) }.prefix(limit))
    }

    static func comesFirst(_ a: Position, _ b: Position) -> Bool {
        if a.seconds != b.seconds { return a.seconds > b.seconds }
        if a.nanoseconds != b.nanoseconds { return a.nanoseconds > b.nanoseconds }
        return b.id.utf8.lexicographicallyPrecedes(a.id.utf8)
    }
}
