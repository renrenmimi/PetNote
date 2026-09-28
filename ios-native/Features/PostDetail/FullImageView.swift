import SwiftUI

/// The whole photo, uncropped.
///
/// Exists because the feed frame is a compromise: `MediaItem` carries no width
/// or height, so the feed cannot know an image's shape before the bytes land
/// and picks a stable frame instead (§6.4 forbids the layout jumping when the
/// image arrives). That frame crops anything outside 4:5–16:9, so there has to
/// be somewhere the full image is reachable, and this is it.
///
/// Deliberately minimal — pinch to zoom, drag to pan, double-tap to toggle
/// zoom, and the X to close. Not a gallery: paging between a post's images,
/// sharing and saving are later work.
///
/// **There is no single-tap-to-dismiss and no drag-down-to-dismiss**, and an
/// earlier version of this comment claimed the first of those. A single tap
/// cannot dismiss while a double tap toggles zoom without every double tap
/// paying a recognition delay, and `.fullScreenCover` offers no interactive
/// dismissal. The X is the way out; docs/media-sizing.md says the same.
struct FullImageView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let maxZoom: CGFloat = 4

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // .large: the detail rendition, matching the web client's
            // imageSize="large" on its own detail screen.
            //
            // **`.whole`, and it was not.** This asked for `aspectRatio: 1`,
            // and `RemoteImage` answered by reserving a square and filling it
            // — `scaledToFill` inside a fixed frame, then clipped. On the one
            // screen whose entire reason to exist is
            // docs/media-sizing.md's "裁切是压缩显示，不是丢失内容", a 4:1
            // panorama showed its middle quarter and a 1:4 portrait showed
            // its middle quarter, with no way to reach the rest: pinching
            // zooms the crop, it does not restore what was clipped away.
            // Measured in `FullImageViewTests`.
            RemoteImage(url: url, size: .large, fit: .whole)
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
                // **Without this there is nothing to put the label on.**
                //
                // `RemoteImage` hides its own contents from VoiceOver — they
                // are pixels — so labelling it labels a subtree with no
                // element in it, and the photo is simply not there: VoiceOver
                // on this screen found the Close button and nothing else, and
                // the "Pinch to zoom" hint was announced to no one. The same
                // line, for the same reason, is already in `MediaView`.
                //
                // On the image and not on the ZStack: a modifier on the
                // container would swallow the close button, which is the trap
                // recorded at the bottom of this file.
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("fullImage.photo")
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
        // Reduce Motion is about exactly this: a large scale transform across
        // the whole screen. The zoom still happens — turning the feature off
        // would be a different and worse answer — it simply arrives without
        // being animated there.
        withAnimation(reduceMotion ? nil : .snappy) {
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
