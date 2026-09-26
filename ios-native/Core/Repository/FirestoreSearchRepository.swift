import FirebaseFirestore
import Foundation
import OSLog

/// The search screen's reads: prefix matches on people, pets and tags, posts by
/// tag, and the discovery rankings.
///
/// Every query here is the web client's, field for field (src/services/
/// search.ts, hashtags.ts, explore.ts, pets.ts `getUserPetCounts`), and every
/// one is served by an index that `firestore.indexes.json` already declares —
/// single-field ranges, `tags CONTAINS + createdAt DESC`, and the
/// collection-group `family.userId` override. None needs a new index, which
/// matters because this client may not deploy one.
///
/// Firestore has no full-text search. A "text" query is a tag match, exactly
/// as on the web: typing `cat` finds posts tagged `cat`, not posts containing
/// the word.
actor FirestoreSearchRepository: SearchRepository {
    private let db: Firestore
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "search")

    /// `"\u{f8ff}"`, the highest code point in the Private Use Area: the
    /// conventional upper bound that turns a range into "starts with".
    static let prefixCeiling = "\u{f8ff}"

    init(db: Firestore = .firestore()) {
        self.db = db
    }

    // MARK: - Search

    func people(prefix: String, limit: Int) async throws -> [PublicProfile] {
        guard !prefix.isEmpty else { return [] }
        let snapshot = try await read {
            try await db.collection("users")
                .order(by: "displayNameLower")
                .whereField("displayNameLower", isGreaterThanOrEqualTo: prefix)
                .whereField("displayNameLower", isLessThanOrEqualTo: prefix + Self.prefixCeiling)
                .limit(to: limit)
                .getDocuments()
        }
        return snapshot.documents.map { SocialDecoder.profile(id: $0.documentID, from: $0.data()) }
    }

    func pets(prefix: String, limit: Int) async throws -> [Pet] {
        guard !prefix.isEmpty else { return [] }
        // The web page runs both and merges: `nameLower` catches everything
        // written since that field existed, `name` catches older pets that
        // only have the display name.
        async let lower = petsWhere("nameLower", startsWith: prefix, limit: limit)
        async let exact = petsWhere("name", startsWith: prefix, limit: limit)
        return SearchLogic.mergePets(lower: try await lower, exact: try await exact, limit: limit)
    }

    private func petsWhere(_ field: String, startsWith prefix: String, limit: Int) async throws -> [Pet] {
        let snapshot = try await read {
            try await db.collection("pets")
                .order(by: field)
                .whereField(field, isGreaterThanOrEqualTo: prefix)
                .whereField(field, isLessThanOrEqualTo: prefix + Self.prefixCeiling)
                .limit(to: limit)
                .getDocuments()
        }
        return snapshot.documents.compactMap { PetDecoder.pet(id: $0.documentID, from: $0.data()) }
    }

    func tags(prefix: String, limit: Int) async throws -> [Hashtag] {
        guard !prefix.isEmpty else { return [] }
        let snapshot = try await read {
            try await db.collection("hashtags")
                .whereField("name", isGreaterThanOrEqualTo: prefix)
                .whereField("name", isLessThanOrEqualTo: prefix + Self.prefixCeiling)
                .order(by: "name")
                .limit(to: limit)
                .getDocuments()
        }
        return snapshot.documents.compactMap { Self.hashtag(from: $0.data()) }
    }

    func posts(taggedWith tag: String, limit: Int) async throws -> [Post] {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }
        let snapshot = try await read {
            try await db.collection("posts")
                .whereField("tags", arrayContains: normalized)
                .order(by: "createdAt", descending: true)
                .limit(to: limit)
                .getDocuments()
        }
        return snapshot.documents.compactMap { PostDecoder.post(id: $0.documentID, from: $0.data()) }
    }

    func petCounts(forUsers userIDs: [String]) async throws -> [String: Int] {
        let valid = userIDs.compactMap(DeepLink.validDocumentID)
        var counts = Dictionary(valid.map { ($0, 0) }, uniquingKeysWith: { first, _ in first })
        for batch in IDBatches.make(valid) {
            let snapshot = try await read {
                try await db.collectionGroup("family")
                    .whereField("userId", in: batch)
                    .getDocuments()
            }
            for document in snapshot.documents {
                if let user = document.data()["userId"] as? String, counts[user] != nil {
                    counts[user, default: 0] += 1
                }
            }
        }
        return counts
    }

    // MARK: - Discovery

    func popularTags(limit: Int) async throws -> [Hashtag] {
        let snapshot = try await read {
            try await db.collection("hashtags")
                .order(by: "postCount", descending: true)
                .limit(to: limit)
                .getDocuments()
        }
        return snapshot.documents.compactMap { Self.hashtag(from: $0.data()) }
    }

    func posts(since date: Date, limit: Int) async throws -> [Post] {
        let snapshot = try await read {
            try await db.collection("posts")
                .whereField("createdAt", isGreaterThanOrEqualTo: Timestamp(date: date))
                .order(by: "createdAt", descending: true)
                .limit(to: limit)
                .getDocuments()
        }
        return snapshot.documents.compactMap { PostDecoder.post(id: $0.documentID, from: $0.data()) }
    }

    func petsByFollowers(limit: Int) async throws -> [Pet] {
        try await petsOrdered(by: "followerCount", limit: limit)
    }

    func petsByPostCount(limit: Int) async throws -> [Pet] {
        try await petsOrdered(by: "postCount", limit: limit)
    }

    private func petsOrdered(by field: String, limit: Int) async throws -> [Pet] {
        let snapshot = try await read {
            try await db.collection("pets")
                .order(by: field, descending: true)
                .limit(to: limit)
                .getDocuments()
        }
        return snapshot.documents.compactMap { PetDecoder.pet(id: $0.documentID, from: $0.data()) }
    }

    func latestPosts(limit: Int) async throws -> [Post] {
        let snapshot = try await read {
            try await db.collection("posts")
                .order(by: "createdAt", descending: true)
                .limit(to: limit)
                .getDocuments()
        }
        return snapshot.documents.compactMap { PostDecoder.post(id: $0.documentID, from: $0.data()) }
    }

    func pets(ids: [String]) async throws -> [Pet] {
        let valid = ids.compactMap(DeepLink.validDocumentID)
        var found: [String: Pet] = [:]
        for batch in IDBatches.make(valid) {
            let snapshot = try await read {
                try await db.collection("pets")
                    .whereField(FieldPath.documentID(), in: batch)
                    .getDocuments()
            }
            for document in snapshot.documents {
                if let pet = PetDecoder.pet(id: document.documentID, from: document.data()) {
                    found[pet.id] = pet
                }
            }
        }
        return valid.compactMap { found[$0] }
    }

    // MARK: - Plumbing

    static func hashtag(from data: [String: Any]) -> Hashtag? {
        guard let name = SocialDecoder.nonEmpty(data["name"]) else { return nil }
        return Hashtag(name: name, postCount: PetDecoder.count(data["postCount"]))
    }

    private func read<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            log.error("search read failed: \(String(describing: error), privacy: .public)")
            throw FirestoreSocialRepository.mapFirestore(error)
        }
    }
}
