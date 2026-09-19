import AVKit
import SwiftUI

/// A video in the feed.
///
/// Three states, and which one is showing is always knowable from the outside:
/// the poster frame (no player), the player (playing or paused), and a
/// retryable failure. The poster is what shows whenever there is no player,
/// which is also what makes the height stable — §5D.5 asks that starting
/// playback not move anything.
struct VideoPlayerView: View {
    let id: String
    let url: URL
    let posterURL: URL?
    let aspectRatio: CGFloat

    @Environment(VideoPlaybackCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase

    @State private var player: AVPlayer?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.width / aspectRatio)
                .onChange(of: visibility(in: geometry), initial: true) { _, new in
                    report(new)
                }
                .onDisappear {
                    coordinator.reportOffscreen(id: id)
                    player = nil
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
        if failed {
            retryable
        } else if let player {
            ZStack(alignment: .bottomTrailing) {
                VideoPlayer(player: player)
                    .disabled(true)   // playback is decided by the coordinator
                    .accessibilityHidden(true)
                muteButton
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Video")
        } else {
            // No player: the poster. Same height, so nothing moves when one
            // appears.
            ZStack {
                RemoteImage(url: posterURL, aspectRatio: aspectRatio)
                Image(systemName: "play.circle.fill")
                    .font(Typography.pageTitle)
                    .foregroundStyle(Palette.textOnBrand)
                    .shadow(radius: 8)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Video, not playing")
        }
    }

    private var muteButton: some View {
        Button {
            coordinator.toggleMute()
        } label: {
            Image(systemName: coordinator.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(Typography.body)
                .foregroundStyle(Palette.textOnBrand)
                .frame(width: Layout.minTouchTarget, height: Layout.minTouchTarget)
                .background(.black.opacity(0.35), in: .circle)
                .contentShape(.circle)
        }
        .padding(Spacing.s)
        .accessibilityIdentifier("video.mute")
        .accessibilityLabel(coordinator.isMuted ? "Unmute video" : "Mute video")
    }

    private var retryable: some View {
        Button {
            failed = false
            attempt += 1
            player = nil
        } label: {
            VStack(spacing: Spacing.s) {
                Image(systemName: "arrow.clockwise")
                Text("Video failed to load. Tap to retry.")
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
        guard reading.fraction > 0 else {
            coordinator.reportOffscreen(id: id)
            player = nil
            return
        }
        coordinator.reportVisibility(
            id: id,
            fraction: reading.fraction,
            distanceFromCentre: reading.distance
        )
        let granted = coordinator.player(for: id, url: url)
        if granted !== player { player = granted }
    }
}

/// Equatable so `onChange` only fires when the reading really moves.
private struct VisibilityReading: Equatable {
    let fraction: CGFloat
    let distance: CGFloat

    static func == (lhs: VisibilityReading, rhs: VisibilityReading) -> Bool {
        // Quantised: a scroll produces a continuous stream of readings, and
        // re-deciding on every pixel would thrash the coordinator.
        Int(lhs.fraction * 20) == Int(rhs.fraction * 20)
            && Int(lhs.distance / 20) == Int(rhs.distance / 20)
    }
}
