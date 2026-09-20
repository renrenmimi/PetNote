import AVKit
import SwiftUI

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

    var body: some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.width / aspectRatio)
                .onChange(of: visibility(in: geometry), initial: true) { _, new in
                    report(new)
                }
                .onDisappear {
                    coordinator.reportOffscreen(id: id)
                }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding pauses everything; it does not resume on return.
            // §5D.6 says the rule has to be written down, and this is it:
            // coming back to the foreground leaves video paused until the
            // person scrolls, which is what makes returning quiet.
            if phase != .active { coordinator.suspendAll(reason: "scenePhase \(phase)") }
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
                VideoPlayer(player: player)
                    .disabled(true)   // playback is decided by the coordinator
                    .accessibilityHidden(true)
            }
        }
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
    private static let isProbing = ProcessInfo.processInfo.arguments.contains("-petnote-video-probe")

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
            coordinator.reportOffscreen(id: id)
            return
        }
        coordinator.reportVisibility(
            id: id,
            fraction: reading.fraction,
            distanceFromCentre: reading.distance
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
