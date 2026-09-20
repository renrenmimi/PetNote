import SwiftUI

/// A post's media: a photo, or a video with real playback.
struct MediaView: View {
    /// Which post this media belongs to.
    ///
    /// Part of the identity handed to the playback coordinator, and it has to
    /// be: the id used to be the media URL alone, and two posts carrying the
    /// same video — the seed has three clips across six posts, and a repost
    /// would do it in production — were then one video as far as the
    /// coordinator was concerned. Both rows would report visibility under the
    /// same key, one would overwrite the other, and whichever lost would never
    /// play.
    let postID: String
    let item: MediaItem
    var size: CloudinaryURL.Size = .medium

    /// Used when the URL carries no `ar_` hint. 4:5 because pet photos are
    /// mostly portrait, and because a guess that is stable beats a guess that
    /// changes once the bytes arrive.
    ///
    /// This is a fallback, not a size source. `MediaItem` has no width or
    /// height, so the feed frame is deliberately fixed and the full image is
    /// reachable by tapping — see `MediaFrame` below and docs/media-sizing.md.
    static let defaultRatio: CGFloat = 4.0 / 5.0
    /// Ratios outside this range are filled and cropped rather than letting one
    /// post own the whole screen.
    static let narrowest: CGFloat = 4.0 / 5.0
    static let widest: CGFloat = 16.0 / 9.0

    /// The ratio the feed draws at, and whether anything is being cut off.
    static func frame(for url: URL) -> MediaFrame {
        guard let declared = CloudinaryURL.aspectRatio(of: url) else {
            return MediaFrame(ratio: defaultRatio, isCropped: true, declaredRatio: nil)
        }
        let clamped = min(max(declared, narrowest), widest)
        return MediaFrame(
            ratio: clamped,
            isCropped: abs(clamped - declared) > 0.001,
            declaredRatio: declared
        )
    }

    private var mediaFrame: MediaFrame { Self.frame(for: item.url) }

    /// Test-only redirection, off unless a launch argument sets it.
    ///
    /// A UI test that wants to prove *a picture reached the glass* needs media
    /// whose colours it knows in advance; the seeded feed points at
    /// Cloudinary's demo cloud, where the frame at 0.4s is whatever it is and
    /// the bytes arrive when the network feels like it. Pointing playback at a
    /// local clip changes nothing about the path under test — same decoder,
    /// same coordinator, same view — and makes the assertion possible. The
    /// keys do not exist in any plist, so this is nil in the real app.
    /// `string(forKey:)` and not `url(forKey:)`: the latter turns a plain
    /// string into a *file* URL, which would quietly rewrite
    /// `http://127.0.0.1/clip.mp4` into a path that does not exist.
    private static let overrideVideoURL = UserDefaults.standard
        .string(forKey: "petnoteVideoURLOverride").flatMap(URL.init(string:))
    private static let overridePosterURL = UserDefaults.standard
        .string(forKey: "petnoteVideoPosterOverride").flatMap(URL.init(string:))

    /// Test-only: renders every media item as a video, and only when an
    /// override URL is also set (so it can do nothing in a shipped build).
    ///
    /// The seed has six videos among 210 posts, which is the right proportion
    /// for a feed and the wrong one for "scroll a real list past thirty
    /// videos": reaching thirty would mean paging most of the way through the
    /// feed. This makes every row a video, which is not what a feed looks like
    /// and is a harder test of the ceiling than a feed would be.
    private static let everythingIsVideo =
        ProcessInfo.processInfo.arguments.contains("-petnote-all-media-is-video")
        && overrideVideoURL != nil

    static func kind(of item: MediaItem) -> MediaItem.Kind {
        everythingIsVideo ? .video : item.kind
    }

    static func playbackURL(for item: MediaItem) -> URL {
        overrideVideoURL ?? item.url
    }

    static func posterURL(for item: MediaItem, size: CloudinaryURL.Size) -> URL? {
        if let overridePosterURL { return overridePosterURL }
        // Derived, not the stored thumbUrl: the web feed always calls
        // getVideoThumbnail(url, imageSize) and never reads thumbUrl, so the
        // stored 400x400 c_fill crop would be a second rendition of the same
        // frame — the cache split §7.4 forbids.
        return CloudinaryURL.videoPoster(item.url, size: size) ?? item.thumbnailURL
    }

    var body: some View {
        switch Self.kind(of: item) {
        case .image:
            RemoteImage(url: item.url, aspectRatio: mediaFrame.ratio, size: size)
                // The label needs an element to land on. RemoteImage hides its
                // own contents from VoiceOver (they are pixels), so without
                // this a post that is only a photo is announced as having no
                // media at all.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(mediaFrame.isCropped ? "Photo, cropped to fit" : "Photo")
        case .video:
            VideoPlayerView(
                // Post first, URL second, and the URL is the post's own even
                // when the bytes come from somewhere else: two rows that play
                // the same file must still be two videos to the coordinator.
                id: "\(postID)|\(item.url.absoluteString)",
                url: Self.playbackURL(for: item),
                // Derived, not the stored thumbUrl: the web feed always calls
                // getVideoThumbnail(url, imageSize) and never reads thumbUrl,
                // so the stored 400x400 c_fill crop would be a second
                // rendition of the same frame — the cache split §7.4 forbids.
                posterURL: Self.posterURL(for: item, size: size),
                aspectRatio: mediaFrame.ratio
            )
        }
    }
}

/// What the feed decided to draw, and whether that hides part of the image.
struct MediaFrame: Equatable {
    let ratio: CGFloat
    /// True when the frame is not the image's own shape, so something is being
    /// cut off and the full image has to be reachable some other way.
    let isCropped: Bool
    /// What the URL said, when it said anything.
    let declaredRatio: CGFloat?
}
