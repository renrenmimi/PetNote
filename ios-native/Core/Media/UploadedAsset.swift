import Foundation

/// Media that has already reached Cloudinary.
///
/// The *record*, not the bytes. Once an upload succeeds the file is on the CDN,
/// so a retry does not have to send it again and a relaunch can pick the work
/// back up — which is the whole reason this is `Codable` and goes into the
/// draft (src/pages/Create.tsx keeps the same thing in its `PostDraft`).
///
/// `publicID` travels with the URL because it is what a delete would need.
/// Nothing in this app deletes — see `AssetReclaim` — but the id is the only
/// part that cannot be recovered afterwards, so it is kept rather than
/// discarded on the strength of a policy that may one day change.
struct UploadedAsset: Sendable, Equatable, Codable {
    /// Cloudinary's own split. It decides the upload endpoint, the preset the
    /// server signs, and the advisory size ceiling — so it is not the same
    /// thing as `MediaItem.Kind` even though the two currently agree.
    enum ResourceType: String, Sendable, Codable {
        case image
        case video
    }

    let url: URL
    let publicID: String
    let resourceType: ResourceType
    /// Poster frame for a video. Absent for images.
    let thumbnailURL: URL?

    var kind: MediaItem.Kind {
        switch resourceType {
        case .image: .image
        case .video: .video
        }
    }

    /// The shape `createPostCallable` expects in its `media` array
    /// (functions/src/posts.ts). Built here rather than at the call site so the
    /// optional `thumbUrl` is omitted rather than sent as null — the server
    /// filters on `typeof item.url === "string"` and a null thumb would be
    /// carried into the document.
    var callablePayload: [String: Any] {
        var payload: [String: Any] = ["url": url.absoluteString, "type": kind.rawValue]
        if let thumbnailURL { payload["thumbUrl"] = thumbnailURL.absoluteString }
        return payload
    }
}

/// Whether the composer may delete an attempt's uploaded media. **It may not.**
///
/// A direct port of src/utils/mediaReclaim.ts, including the part that makes it
/// a type rather than a comment: there is no `reclaim: true` case, so a
/// deletion along this path has to get past the compiler rather than past a
/// reviewer.
///
/// The failure it exists for: publishing commits server-side and the response
/// is lost, so the client shows "failed" and keeps the assets for a retry. Then
/// the person changes a photo, or discards the draft, or comes back to an
/// expired one. Each of those exits used to delete the assets — and a real post
/// already referenced them. A live post pointing at deleted images is not
/// undoable; an orphaned asset on the CDN is bounded and collectable.
///
/// In particular a `published: false` from `getPublishStatusCallable` is **not**
/// grounds to delete. That answer is document existence at one instant and
/// nothing cancelled the original request: a publish paused just before its
/// `.create()` answers false and then commits. The server's own doc comment
/// says so.
enum AssetReclaim {
    /// Why reclaim was withheld. Both cases are "no".
    enum Decision: Sendable, Equatable {
        case noAssets
        case automaticReclaimDisabled
    }

    static func decide(assets: [UploadedAsset]) -> Decision {
        assets.isEmpty ? .noAssets : .automaticReclaimDisabled
    }
}
