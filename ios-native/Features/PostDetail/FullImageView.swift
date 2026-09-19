import SwiftUI

/// The whole photo, uncropped.
///
/// Exists because the feed frame is a compromise: `MediaItem` carries no width
/// or height, so the feed cannot know an image's shape before the bytes land
/// and picks a stable frame instead (§6.4 forbids the layout jumping when the
/// image arrives). That frame crops anything outside 4:5–16:9, so there has to
/// be somewhere the full image is reachable, and this is it.
///
/// Deliberately minimal — pinch to zoom, drag to pan, tap to dismiss. Not a
/// gallery: paging between a post's images, sharing and saving are later work.
struct FullImageView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private static let maxZoom: CGFloat = 4

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // .large: the detail rendition, matching the web client's
            // imageSize="large" on its own detail screen.
            RemoteImage(url: url, aspectRatio: 1, size: .large)
                .aspectRatio(contentMode: .fit)
                .scaleEffect(zoom)
                .offset(offset)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            zoom = min(max(1, committedZoom * value.magnification), Self.maxZoom)
                        }
                        .onEnded { _ in
                            committedZoom = zoom
                            if zoom <= 1 { resetPan() }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard zoom > 1 else { return }
                            offset = CGSize(
                                width: committedOffset.width + value.translation.width,
                                height: committedOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in committedOffset = offset }
                )
                .accessibilityLabel("Photo, full size")
                .accessibilityHint("Pinch to zoom")

            closeButton
        }
        .statusBarHidden()
        .onTapGesture(count: 2) { toggleZoom() }
        .accessibilityAction(named: "Close") { dismiss() }
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(Typography.body)
                        .foregroundStyle(.white)
                        .frame(width: Layout.minTouchTarget, height: Layout.minTouchTarget)
                        .background(.black.opacity(0.4), in: .circle)
                        .contentShape(.circle)
                }
                .accessibilityIdentifier("fullImage.close")
                .accessibilityLabel("Close")
            }
            Spacer()
        }
        .padding(Layout.pageInset)
    }

    private func toggleZoom() {
        withAnimation(.snappy) {
            if zoom > 1 {
                zoom = 1
                committedZoom = 1
                resetPan()
            } else {
                zoom = 2
                committedZoom = 2
            }
        }
    }

    private func resetPan() {
        offset = .zero
        committedOffset = .zero
    }
}
