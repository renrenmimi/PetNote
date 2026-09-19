import AVFoundation
import Foundation
import OSLog

/// Decides which video may play, and owns every player that exists.
///
/// Centralised rather than per-view because the two things the spec asks for
/// are both global properties: **at most N players alive at once**, and **only
/// the most visible one plays**. A view that judges its own visibility cannot
/// know it is the most visible, and a view that makes its own player cannot
/// know how many exist.
///
/// The rule, written down because §5D.1 requires it to be a rule and not a
/// feeling:
///
///   A video is eligible when **at least 60% of its height is on screen**.
///   Among eligible videos, the one whose centre is **closest to the middle of
///   the viewport** plays. Everything else is paused. A video that falls below
///   the threshold is paused immediately; a video that leaves entirely has its
///   player torn down.
@MainActor
@Observable
final class VideoPlaybackCoordinator {
    /// How much of a video must be on screen before it is allowed to play.
    static let visibilityThreshold: CGFloat = 0.6
    /// Hard ceiling on live `AVPlayer` instances. Two, not one: the next video
    /// can be prepared while the current one is still playing, which is what
    /// stops a scroll landing on a black frame.
    static let maximumPlayers = 2

    private let log = Logger(subsystem: "dev.local.petnote.native", category: "media")

    /// Players by video id, most recently used last.
    private var players: [(id: String, player: AVPlayer)] = []
    /// Visible fraction and centre distance, reported by each video view.
    private var visibility: [String: (fraction: CGFloat, distanceFromCentre: CGFloat)] = [:]

    private(set) var playingID: String?
    /// Muted by default and only changed by an explicit tap: §5D.4 says video
    /// must not interrupt whatever the person is already listening to.
    private(set) var isMuted = true

    /// Test-facing: how many players exist right now. The acceptance criterion
    /// is a number, so it has to be readable.
    var livePlayerCount: Int { players.count }
    var livePlayerIDs: [String] { players.map(\.id) }

    // MARK: - Visibility

    func reportVisibility(id: String, fraction: CGFloat, distanceFromCentre: CGFloat) {
        visibility[id] = (fraction, distanceFromCentre)
        reconcile()
    }

    func reportOffscreen(id: String) {
        visibility[id] = nil
        // Gone, not merely hidden: release the decoder rather than holding a
        // paused player for a row that is far away.
        teardown(id: id)
        reconcile()
    }

    /// Everything stops: leaving the screen, or the app going to the background.
    func suspendAll(reason: String) {
        for entry in players { entry.player.pause() }
        playingID = nil
        log.info("video: suspended all (\(reason, privacy: .public))")
    }

    func releaseAll(reason: String) {
        for entry in players {
            entry.player.pause()
            entry.player.replaceCurrentItem(with: nil)
        }
        players.removeAll()
        visibility.removeAll()
        playingID = nil
        log.info("video: released all (\(reason, privacy: .public))")
    }

    func toggleMute() {
        isMuted.toggle()
        for entry in players { entry.player.isMuted = isMuted }
        // Unmuting is the only thing that may take over the audio session, and
        // only then.
        configureAudioSession(forPlaybackWithSound: !isMuted)
    }

    // MARK: - Players

    /// The player for a video, creating it if this video is allowed one.
    ///
    /// Returns nil when the ceiling is reached and this video is not a
    /// candidate — the view then shows its poster frame, which is the correct
    /// thing to show for a video that is not playing anyway.
    func player(for id: String, url: URL) -> AVPlayer? {
        if let existing = players.first(where: { $0.id == id }) {
            touch(id: id)
            return existing.player
        }
        guard shouldHaveAPlayer(id: id) else { return nil }

        if players.count >= Self.maximumPlayers, let victim = leastRecentlyUsedIdleID() {
            teardown(id: victim)
        }
        guard players.count < Self.maximumPlayers else { return nil }

        let player = AVPlayer(url: url)
        player.isMuted = isMuted
        // Nothing sensible to do with a stalled network stream except wait; the
        // default behaviour of playing whatever has buffered is right here.
        player.automaticallyWaitsToMinimizeStalling = true
        players.append((id, player))
        log.info("video: created player for \(id, privacy: .public) (\(self.players.count) live)")
        return player
    }

    private func shouldHaveAPlayer(id: String) -> Bool {
        guard let mine = visibility[id] else { return false }
        return mine.fraction >= Self.visibilityThreshold
    }

    private func leastRecentlyUsedIdleID() -> String? {
        players.first(where: { $0.id != playingID })?.id
    }

    private func touch(id: String) {
        guard let index = players.firstIndex(where: { $0.id == id }) else { return }
        let entry = players.remove(at: index)
        players.append(entry)
    }

    private func teardown(id: String) {
        guard let index = players.firstIndex(where: { $0.id == id }) else { return }
        let entry = players.remove(at: index)
        entry.player.pause()
        // replaceCurrentItem(with: nil) is what actually frees the decoder;
        // dropping the reference alone leaves it alive until the next GC-ish
        // moment, which is how "players never go back to zero" happens.
        entry.player.replaceCurrentItem(with: nil)
        if playingID == id { playingID = nil }
        log.info("video: tore down \(id, privacy: .public) (\(self.players.count) live)")
    }

    // MARK: - The decision

    private func reconcile() {
        // Eligible = enough of it is on screen. Winner = closest to centre.
        let eligible = visibility
            .filter { $0.value.fraction >= Self.visibilityThreshold }
            .sorted { $0.value.distanceFromCentre < $1.value.distanceFromCentre }
        let winner = eligible.first?.key

        guard winner != playingID else { return }

        for entry in players where entry.id != winner {
            entry.player.pause()
        }
        if let winner, let entry = players.first(where: { $0.id == winner }) {
            entry.player.play()
            touch(id: winner)
        }
        playingID = winner
        log.info("video: playing \(winner ?? "none", privacy: .public)")
    }

    private func configureAudioSession(forPlaybackWithSound withSound: Bool) {
        do {
            let session = AVAudioSession.sharedInstance()
            if withSound {
                // Only now does this app claim the audio session.
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
            } else {
                // .ambient plays alongside whatever else is playing and obeys
                // the ring/silent switch — the right category for muted,
                // incidental video in a feed.
                try session.setCategory(.ambient, mode: .moviePlayback)
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        } catch {
            log.error("audio session: \(error.localizedDescription, privacy: .public)")
        }
    }
}
