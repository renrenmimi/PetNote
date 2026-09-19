import Foundation

/// A feed post, already normalized. Anything that reads a `Post` can assume
/// `tags` and `media` are arrays and the counts are non-negative — that is the
/// whole point of decoding through `PostDecoder`.
struct Post: Sendable, Equatable, Identifiable {
    let id: String
    let authorID: String
    let authorName: String
    let authorAvatarURL: URL?
    let text: String
    let media: [MediaItem]
    let petID: String?
    let petName: String?
    let petAvatarURL: URL?
    let createdAt: Date
    let likeCount: Int
    let commentCount: Int
    let tags: [String]
}

extension Post {
    /// The optimistic like offset is the only field the client ever changes on
    /// a post it did not create, so it is the only copy helper that exists.
    func withLikeCount(_ count: Int) -> Post {
        Post(
            id: id, authorID: authorID, authorName: authorName,
            authorAvatarURL: authorAvatarURL, text: text, media: media,
            petID: petID, petName: petName, petAvatarURL: petAvatarURL,
            createdAt: createdAt, likeCount: count, commentCount: commentCount,
            tags: tags
        )
    }
}

struct MediaItem: Sendable, Equatable {
    enum Kind: String, Sendable {
        case image
        case video
    }

    let url: URL
    let kind: Kind
    /// Poster frame for a video. Absent for images.
    let thumbnailURL: URL?
}

/// Firestore's `Timestamp` is not available to the model layer, so the decoder
/// accepts anything that can say what date it is. `FirestoreTimestamp+Post.swift`
/// conforms the SDK type; tests conform their own.
protocol PostDate {
    var postDate: Date { get }
}

extension Date: PostDate {
    var postDate: Date { self }
}
