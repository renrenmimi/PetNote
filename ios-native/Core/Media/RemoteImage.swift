import OSLog
import SwiftUI

/// An image from the network, with the three states it can be in.
///
/// Two rules here come from defects that shipped:
///   - **the placeholder reserves the final height**, because an image that
///     arrives and pushes the text someone is reading is the layout jump §6.4
///     forbids;
///   - **the placeholder does not pulse.** The web client's pulsing grey block
///     became a permanent 464pt grey rectangle when an onLoad race meant the
///     opacity never came back — a still block would at least have looked like
///     what it was.
struct RemoteImage: View {
    /// How the picture is fitted to the space it is given.
    enum Fit {
        /// **Fill a reserved frame and crop.** The frame comes from
        /// `aspectRatio` and exists before the bytes do, which is what stops
        /// the layout moving when they land. Anything not that shape loses
        /// its edges — deliberately, and the feed says so with the "tap for
        /// the whole photo" hint.
        case reservedFrame
        /// **Show the whole picture, whatever shape it is.** Used where the
        /// promise is the picture rather than a stable row height: nothing
        /// below it can be pushed around, so there is no layout to protect
        /// and no reason to crop.
        case whole
    }

    let url: URL?
    /// width ÷ height. The caller decides; see `MediaView` for where it comes
    /// from when the URL does not say.
    ///
    /// Only used by `.reservedFrame`: in `.whole` the picture's own shape is
    /// the one that is drawn, which is the entire point of that mode.
    var aspectRatio: CGFloat = 1
    var cornerRadius: CGFloat = 0
    var size: CloudinaryURL.Size = .medium
    var fit: Fit = .reservedFrame

    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        switch fit {
        case .reservedFrame:
            GeometryReader { geometry in
                content(longestEdge: geometry.size.width)
                    .frame(width: geometry.size.width, height: geometry.size.width / aspectRatio)
                    .clipShape(.rect(cornerRadius: cornerRadius))
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
        case .whole:
            // No `.frame` and no `.aspectRatio` imposed from here: the picture
            // is allowed to be whatever shape it is, inside whatever space the
            // caller gave. Forcing a ratio was the defect — `FullImageView`
            // asked for 1:1 and got a centre-cropped square on the one screen
            // whose whole job is showing the picture uncropped.
            GeometryReader { geometry in
                content(longestEdge: max(geometry.size.width, geometry.size.height))
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    @ViewBuilder
    private func content(longestEdge: CGFloat) -> some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                // `.scaledToFit` in `.whole`: every pixel of the photo is on
                // screen, letterboxed rather than cropped.
                .aspectRatio(contentMode: fit == .whole ? .fit : .fill)
                .accessibilityHidden(true)
        } else if failed {
            retryable
        } else {
            placeholder
                // The width is part of the key, and that is a fix, not a
                // detail. `.task(id:)` only re-runs when the id changes, so a
                // first layout pass that reports width 0 — which happens — used
                // to start a load that returned immediately, and nothing ever
                // asked again: a permanent grey rectangle. Quantised to the
                // loader's own step so that a one-point width change does not
                // start a second download.
                .task(id: LoadKey(attempt: attempt, pixels: pixels(for: longestEdge))) {
                    await load(longestEdge: longestEdge)
                }
        }
    }

    private var placeholder: some View {
        Palette.secondaryBackground
            .accessibilityHidden(true)
    }

    private var retryable: some View {
        Button {
            failed = false
            attempt += 1
        } label: {
            VStack(spacing: Spacing.s) {
                Image(systemName: "arrow.clockwise")
                Text("Tap to retry")
                    .font(Typography.caption)
            }
            .foregroundStyle(Palette.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.secondaryBackground)
            .contentShape(.rect)
        }
        // Stops the tap reaching the row underneath: retrying an image must not
        // navigate anywhere (§5.6).
        .buttonStyle(.plain)
        .accessibilityIdentifier("image.retry")
        .accessibilityLabel("Image failed to load. Tap to retry.")
    }

    private func pixels(for width: CGFloat) -> CGFloat {
        ImageLoader.quantizedPixels(width * displayScale)
    }

    /// What a load is keyed on: which attempt, and which decoded size.
    private struct LoadKey: Equatable {
        let attempt: Int
        let pixels: CGFloat
    }

    /// Test-only, and off unless a launch argument turns it on.
    ///
    /// Proving that nothing moves when a photo arrives means being able to see
    /// the moment before it arrives; on a simulator with a warm cache that
    /// moment is a few milliseconds long. Absent in the app a person runs —
    /// the key is not in any plist, so this reads nil and costs one lookup at
    /// first use.
    ///
    /// Behind `#if DEBUG`, and the key name is why: `petnoteImageDelayMilliseconds`
    /// has no `-petnote-` prefix, so an audit grepping for the prefix misses
    /// it entirely. Reading it at runtime and ignoring the answer would still
    /// leave the literal in the shipped binary.
    private static let artificialDelayMilliseconds: Int = {
        #if DEBUG
        return UserDefaults.standard.integer(forKey: "petnoteImageDelayMilliseconds")
        #else
        return 0
        #endif
    }()

    private func load(longestEdge: CGFloat) async {
        guard let url, longestEdge > 0 else { return }
        if Self.artificialDelayMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(Self.artificialDelayMilliseconds))
        }
        Logger(subsystem: "dev.local.petnote.native", category: "media")
            .debug("load \(url.lastPathComponent, privacy: .public) @\(Int(longestEdge))pt")
        let optimized = CloudinaryURL.optimized(url, size: size)
        // The *longest* edge, because that is what the decoder's
        // `ThumbnailMaxPixelSize` caps. In `.reservedFrame` that is the width
        // and nothing changes; in `.whole` a tall photo is taller than it is
        // wide, and asking by width alone decoded it to a fraction of the
        // size it is drawn at — a soft picture on the one screen someone
        // opened to look closely.
        let requestedPixels = longestEdge * displayScale
        do {
            image = try await ImageLoader.shared.image(for: optimized, maxPixelSize: requestedPixels)
        } catch {
            // Cancellation is not failure, and it arrives under two names:
            // `CancellationError` from Swift, `URLError(.cancelled)` from
            // `URLSession`. The loader now normalises it, and this is the
            // second lock on the same door — a row that has gone away must
            // never write `failed`, because `failed` survives the row coming
            // back and puts "Tap to retry" over a photo that was fine.
            guard !Task.isCancelled, !ImageLoader.isCancellation(error) else { return }
            failed = true
        }
    }
}
