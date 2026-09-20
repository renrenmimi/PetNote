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
        // No `.accessibilityAction(named: "Close")` here.
        //
        // Adding an action to this container promoted it to an accessibility
        // element and merged its children into it — so `fullImage.close`
        // resolved to an element 603pt wide at x=-100 on a 402pt screen,
        // covering the whole photo. A tap on it landed in the middle of the
        // picture, never on the X in the corner, and the cover stayed up.
        // dismiss() was never the problem; the tap never arrived.
        //
        // The same shape as the container-identifier trap this project has
        // hit three times: a modifier on a container quietly taking over what
        // its children report. The close button below already offers Close on
        // its own, so nothing is lost by not repeating it here.
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
                        .foregroundStyle(Palette.textOnBrand)
                        .frame(width: Layout.minTouchTarget, height: Layout.minTouchTarget)
                        // Not `.black.opacity()` — the design system guard is right
                        // that naming a colour here is the wrong move — and not a bare
                        // material either, which would ignore Reduce Transparency.
                        // Both decisions live in one place; see ControlScrim.
                        .controlScrim()
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
