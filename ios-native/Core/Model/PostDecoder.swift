import Foundation

/// Turns a Firestore document into a `Post`.
///
/// This mirrors `toPost` in src/services/posts.ts, which is the contract's
/// source of truth for field normalization, and it mirrors it deliberately
/// rather than by convention:
///
///   - `tags` that is not an array becomes `[]` (the web client crashed on
///     `post.tags.map` without this);
///   - `likeCount` / `commentCount` are clamped at 0, because a create→delete
///     race inside trigger latency can briefly drive the denormalized counter
///     negative and that must never reach the screen;
///   - a malformed `media` entry is dropped, not fatal: one bad item must not
///     cost the whole page.
///
/// It is a pure function over a dictionary so it can be tested without Firebase.
enum PostDecoder {
    static func post(id: String, from data: [String: Any]) -> Post? {
        // authorId and createdAt are the only fields a post cannot be rendered
        // without: everything else has a sensible degraded form.
        guard let authorID = data["authorId"] as? String, !authorID.isEmpty else { return nil }
        guard let createdAt = (data["createdAt"] as? PostDate)?.postDate else { return nil }

        return Post(
            id: id,
            authorID: authorID,
            authorName: data["authorName"] as? String ?? "",
            authorAvatarURL: url(data["authorAvatar"]),
            text: data["text"] as? String ?? "",
            media: media(from: data),
            petID: nonEmpty(data["petId"]),
            petName: nonEmpty(data["petName"]),
            petAvatarURL: url(data["petAvatarUrl"]),
            createdAt: createdAt,
            likeCount: count(data["likeCount"]),
            commentCount: count(data["commentCount"]),
            tags: tags(data["tags"])
        )
    }

    // MARK: - Field normalization

    static func count(_ raw: Any?) -> Int {
        // Firestore hands back NSNumber, so an Int-typed count can arrive as
        // Int64 or Double depending on how it was written.
        let value: Int
        switch raw {
        case let int as Int: value = int
        case let int64 as Int64: value = Int(int64)
        case let double as Double where double.isFinite: value = Int(double)
        default: return 0
        }
        return max(0, value)
    }

    static func tags(_ raw: Any?) -> [String] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { $0 as? String }
    }

    static func media(from data: [String: Any]) -> [MediaItem] {
        if let array = data["media"] as? [[String: Any]] {
            let items = array.compactMap(mediaItem(from:))
            if !items.isEmpty { return items }
        }
        // Posts written before `media` existed carry a single mediaUrl/mediaType
        // pair; the seed keeps both in sync, and production still has the old
        // shape, so read it rather than showing those posts with no image.
        if let legacy = mediaItem(from: ["url": data["mediaUrl"] as Any, "type": data["mediaType"] as Any]) {
            return [legacy]
        }
        return []
    }

    private static func mediaItem(from raw: [String: Any]) -> MediaItem? {
        guard let mediaURL = url(raw["url"]) else { return nil }
        guard let kind = MediaItem.Kind(rawValue: (raw["type"] as? String) ?? "") else { return nil }
        return MediaItem(url: mediaURL, kind: kind, thumbnailURL: url(raw["thumbUrl"]))
    }

    private static func url(_ raw: Any?) -> URL? {
        guard let string = raw as? String, !string.isEmpty else { return nil }
        // Only http(s): a document field must not be able to point the client at
        // file:// or a custom scheme.
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    private static func nonEmpty(_ raw: Any?) -> String? {
        guard let string = raw as? String, !string.isEmpty else { return nil }
        return string
    }
}
