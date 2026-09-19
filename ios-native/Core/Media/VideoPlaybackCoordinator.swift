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
    private var clockTask: Task<Void, Never>?

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
        // The player now exists, so the decision that could not be acted on a
        // moment ago can be. Without this the first video in a feed waits for
        // the next scroll event before it starts.
        reconcile()
        return player
    }

    /// Whether a given video is actually playing, as the player itself reports
    /// it — not as the coordinator believes. Test-facing: `playingID` is a
    /// belief, and the defect this exists to catch was a belief that never
    /// became a `play()` call.
    func isActuallyPlaying(id: String) -> Bool {
        guard let entry = players.first(where: { $0.id == id }) else { return false }
        return entry.player.timeControlStatus != .paused
    }

    /// The player's current playback position, for proving time advances.
    func currentTime(of id: String) -> Double? {
        guard let entry = players.first(where: { $0.id == id }) else { return nil }
        return entry.player.currentTime().seconds
    }

    /// Logs the playing video's clock once a second while something is playing.
    ///
    /// The log, not the interface: publishing a continuously-changing value
    /// into the view tree keeps the app from ever being idle, and XCUITest
    /// waits for idle before every single query. Proving playback advances is
    /// worth a log line; it is not worth making the app untestable.
    func startPlaybackClockLogging() {
        guard clockTask == nil else { return }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await self.logClock()
            }
        }
    }

    private func logClock() {
        guard let playing = playingID,
              let entry = players.first(where: { $0.id == playing }) else { return }
        let time = entry.player.currentTime().seconds
        // Status and the waiting reason too: a clock stuck at zero is either
        // "still buffering" or "asked to play and never will", and the number
        // alone cannot tell those apart.
        let status: String
        switch entry.player.timeControlStatus {
        case .paused: status = "paused"
        case .waitingToPlayAtSpecifiedRate: status = "waiting"
        case .playing: status = "playing"
        @unknown default: status = "unknown"
        }
        let reason = entry.player.reasonForWaitingToPlay?.rawValue ?? "-"
        let itemStatus = entry.player.currentItem.map { item -> String in
            switch item.status {
            case .unknown: return "unknown"
            case .readyToPlay: return "ready"
            case .failed: return "failed(\(item.error?.localizedDescription ?? "?"))"
            @unknown default: return "?"
            }
        } ?? "noitem"
        log.info("""
            video clock: t=\(String(format: "%.2f", time), privacy: .public) \
            status=\(status, privacy: .public) waiting=\(reason, privacy: .public) \
            item=\(itemStatus, privacy: .public)
            """)
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

        for entry in players where entry.id != winner {
            entry.player.pause()
        }

        guard let winner else {
            playingID = nil
            return
        }

        // **`playingID` is only claimed once `play()` has actually been sent.**
        //
        // It used to be set whether or not a player existed — and on the first
        // appearance of a video it does not, because the view reports its
        // visibility before asking for one. The play() call was skipped, the id
        // was claimed anyway, and every later reconcile returned early on
        // `winner == playingID`. Nothing ever played. Claiming the id here, and
        // only here, makes that unrepresentable: no player, no claim, and the
        // next call tries again.
        guard let entry = players.first(where: { $0.id == winner }) else {
            if playingID != nil { playingID = nil }
            log.debug("video: \(winner, privacy: .public) wins but has no player yet")
            return
        }

        guard playingID != winner else { return }
        entry.player.play()
        touch(id: winner)
        playingID = winner
        log.info("video: playing \(winner, privacy: .public)")
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
