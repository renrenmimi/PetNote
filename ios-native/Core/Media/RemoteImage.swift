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
                .task(id: attempt) { await load(width: width) }
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

    private func load(width: CGFloat) async {
        guard let url, width > 0 else { return }
        let optimized = CloudinaryURL.optimized(url, size: size)
        let pixels = width * displayScale
        do {
            image = try await ImageLoader.shared.image(for: optimized, maxPixelSize: pixels)
        } catch is CancellationError {
            // Scrolled away before it arrived; not a failure state.
        } catch {
            failed = true
        }
    }
}
