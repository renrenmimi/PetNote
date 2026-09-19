import SwiftUI

/// A post's media. Stage 5 renders images and video poster frames; playback is
/// stage 5D.
struct MediaView: View {
    let item: MediaItem
    var size: CloudinaryURL.Size = .medium

    /// Used when the URL carries no `ar_` hint. 4:5 because pet photos are
    /// mostly portrait, and because a guess that is stable beats a guess that
    /// changes once the bytes arrive.
    private static let defaultRatio: CGFloat = 4.0 / 5.0
    /// Ratios outside this range are filled and cropped rather than letting one
    /// post own the whole screen.
    private static let narrowest: CGFloat = 4.0 / 5.0
    private static let widest: CGFloat = 16.0 / 9.0

    private var ratio: CGFloat {
        let declared = CloudinaryURL.aspectRatio(of: item.url) ?? Self.defaultRatio
        return min(max(declared, Self.narrowest), Self.widest)
    }

    var body: some View {
        switch item.kind {
        case .image:
            RemoteImage(url: item.url, aspectRatio: ratio, size: size)
                // The label needs an element to land on. RemoteImage hides its
                // own contents from VoiceOver (they are pixels), so without
                // this a post that is only a photo is announced as having no
                // media at all — the video branch below already did it right.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Photo")
        case .video:
            ZStack {
                RemoteImage(
                    // Derived, not the stored thumbUrl: the web feed always
                    // calls getVideoThumbnail(url, imageSize) and never reads
                    // thumbUrl, so using the stored 400x400 c_fill crop would
                    // ask the CDN for a second rendition of the same frame —
                    // the cache split §7.4 forbids — and crop it besides.
                    url: CloudinaryURL.videoPoster(item.url, size: size) ?? item.thumbnailURL,
                    aspectRatio: ratio,
                    size: size
                )
                Image(systemName: "play.circle.fill")
                    .font(Typography.pageTitle)
                    .foregroundStyle(Palette.textOnBrand)
                    .shadow(radius: 8)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Video")
        }
    }
}
