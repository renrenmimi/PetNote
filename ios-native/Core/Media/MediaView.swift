import SwiftUI

/// A post's media: a photo, or a video with real playback.
struct MediaView: View {
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

    var body: some View {
        switch item.kind {
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
                id: item.url.absoluteString,
                url: item.url,
                // Derived, not the stored thumbUrl: the web feed always calls
                // getVideoThumbnail(url, imageSize) and never reads thumbUrl,
                // so the stored 400x400 c_fill crop would be a second
                // rendition of the same frame — the cache split §7.4 forbids.
                posterURL: CloudinaryURL.videoPoster(item.url, size: size) ?? item.thumbnailURL,
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
