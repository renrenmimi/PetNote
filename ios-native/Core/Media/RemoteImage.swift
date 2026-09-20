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
    let url: URL?
    /// width ÷ height. The caller decides; see `MediaView` for where it comes
    /// from when the URL does not say.
    let aspectRatio: CGFloat
    var cornerRadius: CGFloat = 0
    var size: CloudinaryURL.Size = .medium

    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            content(width: geometry.size.width)
                .frame(width: geometry.size.width, height: geometry.size.width / aspectRatio)
                .clipShape(.rect(cornerRadius: cornerRadius))
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
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
                .task(id: LoadKey(attempt: attempt, pixels: pixels(for: width))) {
                    await load(width: width)
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
    private static let artificialDelayMilliseconds: Int = {
        UserDefaults.standard.integer(forKey: "petnoteImageDelayMilliseconds")
    }()

    private func load(width: CGFloat) async {
        guard let url, width > 0 else { return }
        if Self.artificialDelayMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(Self.artificialDelayMilliseconds))
        }
        Logger(subsystem: "dev.local.petnote.native", category: "media")
            .debug("load \(url.lastPathComponent, privacy: .public) @\(Int(width))pt")
        let optimized = CloudinaryURL.optimized(url, size: size)
        let requestedPixels = width * displayScale
        do {
            image = try await ImageLoader.shared.image(for: optimized, maxPixelSize: requestedPixels)
        } catch is CancellationError {
            // Scrolled away before it arrived; not a failure state.
        } catch {
            failed = true
        }
    }
}
