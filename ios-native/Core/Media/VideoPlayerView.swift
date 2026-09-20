import AVFoundation
import SwiftUI
import UIKit

/// A video in the feed.
///
/// Four states, and which one is showing is always knowable from the outside:
/// the poster frame (no player), the poster still up while the video opens
/// (a player exists but the decoder has not said how big the picture is), the
/// picture itself, and a retryable failure. The poster is underneath all of
/// them, which is what makes the height stable — §5D.5 asks that starting
/// playback not move anything — and is also why a video that is still opening
/// shows a photo rather than a black rectangle.
///
/// **This view owns no playback state.** It used to keep its own `@State`
/// player, failure flag and KVO observation, and all three drifted from the
/// coordinator that actually owns the player: when the ceiling evicted a
/// player the row went on holding it, so `livePlayerCount` read zero while the
/// object was still alive and the row drew an empty black `VideoPlayer`
/// forever. Reading through the coordinator makes that state unrepresentable.
struct VideoPlayerView: View {
    let id: String
    let url: URL
    let posterURL: URL?
    let aspectRatio: CGFloat

    @Environment(VideoPlaybackCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase

    /// The last visibility reading, kept so that a retry can re-ask for a
    /// player without waiting for the row to move. A tap is the event; nothing
    /// about the geometry changes when someone taps retry, so `onChange` will
    /// not fire again on its own.
    @State private var lastReading: VisibilityReading?

    /// Identifies this view instance to the coordinator.
    ///
    /// A new one whenever SwiftUI builds fresh state for this row, which is
    /// exactly when a row has been replaced rather than updated — and that is
    /// the case the coordinator has to be able to recognise. See `reporters`
    /// there.
    @State private var instance = UUID()

    var body: some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.width / aspectRatio)
                .onChange(of: visibility(in: geometry), initial: true) { _, new in
                    report(new)
                }
                .onDisappear {
                    coordinator.reportOffscreen(id: id, reporter: instance, reason: "onDisappear")
                }
                // **Coming back has to re-open the conversation.**
                //
                // Leaving the feed for a post tears every player down and —
                // because `SignedInView` calls `releaseAll` on the way back
                // too — empties the coordinator's idea of what is on screen.
                // The decision is made from that map, so an empty map means no
                // video is eligible and nothing plays. `onChange` cannot fix
                // it: the geometry of a row that never moved is the same
                // number it was before, so the comparison says nothing
                // happened and the row stays silent. A feed in that state is
                // not slow, it is stuck, and the only thing that got it out
                // was a scroll.
                //
                // Re-reading the geometry rather than replaying the last
                // reading, so a row that reappears somewhere else reports
                // where it actually is.
                .onAppear {
                    report(visibility(in: geometry))
                }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .onChange(of: scenePhase) { _, phase in
            // `.background` only. `.inactive` is not backgrounding — it is
            // what a phone reports while the control centre is being pulled
            // down, while the app switcher is open, while a call banner is
            // up. Treating it the same way meant a glance at the control
            // centre stopped the video and, because returning is deliberately
            // quiet, left it stopped until the person happened to scroll.
            //
            // §5D.6's rule — coming back from the background does not resume
            // on its own — is unchanged and is still what makes returning
            // quiet. This narrows what counts as leaving.
            guard phase == .background else { return }
            coordinator.suspendAll(reason: "scenePhase \(phase)")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let failure = coordinator.failure(for: id) {
            retryable(failure)
        } else {
            ZStack(alignment: .bottomTrailing) {
                surface
                // A sibling of the surface, not a child of it: the surface is
                // one accessibility element so that a test can ask it what it
                // is showing, and a control buried inside such an element
                // cannot be reached by VoiceOver or by a tap in a test.
                if coordinator.activePlayer(for: id) != nil {
                    muteButton
                }
            }
        }
    }

    /// The picture area: the poster, and the video on top of it once there is
    /// a video to show.
    ///
    /// One accessibility element carrying a machine-readable value, so a UI
    /// test can pair *what this row believes* with a screenshot of *what this
    /// row drew*. That pairing is the only way to tell "the coordinator says it
    /// is playing" from "there is a picture on the glass", and those two have
    /// already been different once.
    private var surface: some View {
        ZStack {
            // Always present, always the same height. Nothing moves when a
            // player arrives, and nothing is black while it opens.
            poster

            if let player = coordinator.activePlayer(for: id), coordinator.hasPicture(for: id) {
                // An `AVPlayerLayer` we own, **not** SwiftUI's `VideoPlayer`.
                //
                // Honest history, because this was first changed for a reason
                // that turned out to be wrong: `VideoPlayer` was blamed for
                // the oversized accessibility rectangle on this row, and it
                // was measured innocent — the number did not move after AVKit
                // was gone. The real fix is the `.accessibility` content shape
                // below.
                //
                // Kept anyway, on its own merits. `VideoPlayer` is an
                // `AVPlayerViewController`: a whole view controller per feed
                // row, bringing transport controls this feed does not want
                // (hence the `.disabled(true)` that used to be here), its own
                // accessibility subtree we then have to hide, and a black
                // backing that fills the letterbox bars. A layer-backed
                // `UIView` is the smallest thing that can show a frame, and
                // its transparent bars let the poster underneath show through
                // instead.
                PlayerLayerView(player: player)
                    .allowsHitTesting(false)   // playback is decided by the coordinator
                    .accessibilityHidden(true)
            }
        }
        // **The rectangle this row claims to occupy is its own.**
        //
        // Without this it claimed a 670x502.7 rectangle starting at x = -134,
        // on a 402pt-wide screen — the aspect-*fill* rectangle of a 4:3 clip
        // at the row's height, overhanging both edges. Measured, in
        // `testTheVideoRowReportsTheRectangleItActuallyDrew`. Drawing was
        // never wrong; VoiceOver's focus rectangle for the row was, and so
        // was every frame-based decision a test could make about it.
        //
        // Two likelier-looking causes were tried and measured *not* to be it:
        // it is not `AVPlayerViewController` (the number is unchanged after
        // this view stopped using AVKit at all) and it is not the poster
        // overflowing `scaledToFill` (unchanged after `.clipped()`). Rather
        // than keep guessing which descendant reports the oversized shape,
        // state the shape: `.accessibility` content shape is the supported way
        // to say "this is my accessibility rectangle", and one ZStack is
        // exactly the scope it should cover.
        .contentShape(.accessibility, Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("video.surface")
        .accessibilityLabel(coordinator.playingID == id ? "Video" : "Video, not playing")
        // Empty unless a test asked for it: nobody should hear "state=picture
        // playing=true size=320x240" read aloud.
        .accessibilityValue(Self.isProbing ? stateDescription : "")
    }

    private var poster: some View {
        ZStack {
            RemoteImage(url: posterURL, aspectRatio: aspectRatio)
            if !coordinator.hasPicture(for: id) {
                Image(systemName: "play.circle.fill")
                    .font(Typography.pageTitle)
                    .foregroundStyle(Palette.textOnBrand)
                    .shadow(radius: 8)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityHidden(true)
    }

    /// Set once: reading the argument list per row per redraw is waste, and
    /// the answer cannot change while the process is alive.
    private static let isProbing: Bool = {
        // **`#if DEBUG`, not a runtime check.** A runtime check still compiles
        // the literal `-petnote-video-probe` into the binary, where `strings`
        // finds it and a release-candidate audit fails — the switch being off
        // is not the same as the switch not being there. Excluded at compile
        // time, the string has nowhere to exist.
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-petnote-video-probe")
        #else
        return false
        #endif
    }()

    private var stateDescription: String {
        let size = coordinator.presentationSizes[id] ?? .zero
        let state: String
        if coordinator.failure(for: id) != nil {
            state = "failed"
        } else if coordinator.activePlayer(for: id) == nil {
            state = "poster"
        } else if !coordinator.hasPicture(for: id) {
            state = "opening"
        } else {
            state = "picture"
        }
        return "state=\(state) playing=\(coordinator.playingID == id) "
            + "size=\(Int(size.width))x\(Int(size.height)) "
            + "advanced=\(coordinator.advanced.contains(id))"
    }

    private var muteButton: some View {
        Button {
            coordinator.toggleMute()
        } label: {
            Image(systemName: coordinator.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
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
        .padding(Spacing.s)
        .accessibilityIdentifier("video.mute")
        .accessibilityLabel(coordinator.isMuted ? "Unmute video" : "Mute video")
    }

    private func retryable(_ message: String) -> some View {
        Button {
            // A real reload: the coordinator forgets the failure and builds a
            // new player from the URL it remembered. Re-sending the last
            // visibility reading covers the case where the row is the only
            // thing on screen and nothing will move to trigger it.
            coordinator.retry(id: id)
            if let lastReading { report(lastReading) }
        } label: {
            VStack(spacing: Spacing.s) {
                Image(systemName: "arrow.clockwise")
                Text(message)
                    .font(Typography.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Palette.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.secondaryBackground)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("video.retry")
    }

    /// Fraction of this view's height that is inside the screen, and how far
    /// its centre is from the screen's centre.
    private func visibility(in geometry: GeometryProxy) -> VisibilityReading {
        let frame = geometry.frame(in: .global)
        let screen = UIScreen.main.bounds
        let intersection = frame.intersection(screen)
        let fraction = frame.height > 0 ? max(0, intersection.height) / frame.height : 0
        let distance = abs(frame.midY - screen.midY)
        return VisibilityReading(fraction: fraction, distance: distance)
    }

    private func report(_ reading: VisibilityReading) {
        lastReading = reading
        guard reading.fraction > 0 else {
            coordinator.reportOffscreen(id: id, reporter: instance, reason: "fraction 0")
            return
        }
        coordinator.reportVisibility(
            id: id,
            fraction: reading.fraction,
            distanceFromCentre: reading.distance,
            reporter: instance
        )
        _ = coordinator.player(for: id, url: url)
    }
}

/// Equatable so `onChange` only fires when the reading really moves.
struct VisibilityReading: Equatable {
    let fraction: CGFloat
    let distance: CGFloat

    static func == (lhs: VisibilityReading, rhs: VisibilityReading) -> Bool {
        // Quantised: a scroll produces a continuous stream of readings, and
        // re-deciding on every pixel would thrash the coordinator.
        Int(lhs.fraction * 20) == Int(rhs.fraction * 20)
            && Int(lhs.distance / 20) == Int(rhs.distance / 20)
    }
}

/// The video picture, and nothing else.
///
/// Deliberately the smallest thing that can show a frame: one `AVPlayerLayer`
/// inside one `UIView`. See the note at the call site for why SwiftUI's
/// `VideoPlayer` is not used — the short version is that `AVPlayerViewController`
/// reports an accessibility rectangle that is not the rectangle it drew, and
/// nothing on the SwiftUI side reaches far enough in to correct it.
///
/// `.resizeAspect` on purpose: the whole frame is shown, letterboxed, which is
/// what `VideoPlayer` did and what keeps the row's height honest. The bars are
/// transparent rather than black, so what shows through them is the poster
/// underneath — a better answer than black for a 4:3 clip in a 4:5 row.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerHost {
        let view = PlayerLayerHost()
        view.backgroundColor = .clear
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        // Pixels are not an accessibility element. The row above already
        // carries the label and the machine-readable state.
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: PlayerLayerHost, context: Context) {
        // Identity, not equality: the coordinator hands the same object back
        // for the same row, and re-setting it would restart the render
        // pipeline on every redraw.
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    /// The layer keeps a strong reference to the player, and the coordinator —
    /// not this view — decides when a player stops existing. Letting go here
    /// is what makes `teardown` actually free the decoder instead of leaving
    /// it owned by a layer in a row that has gone away.
    static func dismantleUIView(_ view: PlayerLayerHost, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

/// A `UIView` whose backing layer *is* the player layer.
///
/// Rather than adding a sublayer and resizing it by hand: a sublayer does not
/// follow its view's bounds, so every rotation and every row resize needs
/// code, and the frame it is left with between the two is visibly wrong.
final class PlayerLayerHost: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // Safe by construction: `layerClass` above is the only thing that
        // decides what this is.
        layer as! AVPlayerLayer
    }
}
