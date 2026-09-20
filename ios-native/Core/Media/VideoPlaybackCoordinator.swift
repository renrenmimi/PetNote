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
///
/// Everything a view needs to *draw* a video is published from here as well —
/// the player itself, whether its picture size is known yet, whether it failed,
/// and whether its clock has moved. The view used to keep its own `@State`
/// copies of those, and that is how a torn-down player stayed alive inside a
/// row that was still on screen: `livePlayerCount` went back to zero while the
/// object did not go anywhere. One owner, one lifetime.
@MainActor
@Observable
final class VideoPlaybackCoordinator {
    /// How much of a video must be on screen before it is allowed to play.
    static let visibilityThreshold: CGFloat = 0.6
    /// Hard ceiling on live `AVPlayer` instances. Two, not one: the next video
    /// can be prepared while the current one is still playing, which is what
    /// stops a scroll landing on a black frame.
    static let maximumPlayers = 2
    /// Where the "the clock really moved" flags are raised. Boundary observers,
    /// not a timer: they fire twice and then never again, so nothing here makes
    /// the app continuously busy. (A periodic probe once cost a single UI test
    /// 1070 seconds of waiting for an app that could never be idle.)
    static let progressMarks: [Double] = [0.3, 0.9]

    private let log = Logger(subsystem: "dev.local.petnote.native", category: "media")

    /// One live player and everything attached to it. Attached, because the
    /// attachments are what leak: a KVO observation and a time observer both
    /// outlive the player unless they are removed on the way out, and a time
    /// observer that outlives its player is a crash, not a leak.
    private struct Entry {
        let id: String
        let player: AVPlayer
        var statusObservation: NSKeyValueObservation?
        var sizeObservation: NSKeyValueObservation?
        var timeObserver: Any?
        /// Kept for the same reason as the others: a notification observer
        /// outlives the object it was made for unless it is removed.
        var endObserver: (any NSObjectProtocol)?
    }

    /// Players by video id, most recently used last.
    private var entries: [Entry] = []
    /// Visible fraction and centre distance, reported by each video view.
    private var visibility: [String: (fraction: CGFloat, distanceFromCentre: CGFloat)] = [:]
    /// Which view instance most recently spoke for each id.
    ///
    /// Needed because `onDisappear` is not ordered against the next view's
    /// first visibility report. Coming back to the feed from a post, the
    /// rebuilt row reported itself visible, was given a player and started
    /// playing — and *then*, half a second later, the row it replaced ran its
    /// `onDisappear` and tore that player down. Nothing moves after that, so
    /// no further visibility report ever arrives and the feed sits there with
    /// every video dead. An id alone cannot tell those two views apart.
    private var reporters: [String: UUID] = [:]
    /// The URL each id was last asked to play, so a retry can rebuild without
    /// the view having to hand it back.
    private var sources: [String: URL] = [:]

    private(set) var playingID: String?
    /// Muted by default and only changed by an explicit tap: §5D.4 says video
    /// must not interrupt whatever the person is already listening to.
    private(set) var isMuted = true

    /// Videos whose item reported `.failed`, with the message to show.
    ///
    /// Held here rather than in the view for two reasons found by testing: a
    /// view that owns its own failure flag still hands out a fresh player on
    /// the next scroll event, so a broken video took a slot from a working one
    /// over and over; and the failure disappeared whenever the row was
    /// recycled, which made the retry button flicker in and out of existence.
    private(set) var failures: [String: String] = [:]
    /// The picture size the decoder reports, once it knows it. Zero-sized or
    /// missing means *there is nothing to show yet* — which is the difference
    /// between "buffering" and "playing", and the reason the poster stays up
    /// instead of a black rectangle.
    private(set) var presentationSizes: [String: CGSize] = [:]
    /// Ids whose playback clock has actually crossed `progressMarks`.
    private(set) var advanced: Set<String> = []
    /// True between an audio interruption beginning and ending.
    private(set) var isInterrupted = false

    private var clockTask: Task<Void, Never>?
    /// Kept so it can be unhooked: a block-based observer lives in the
    /// notification centre until it is removed, whatever happens to us.
    @ObservationIgnored
    private nonisolated(unsafe) var interruptionObserver: (any NSObjectProtocol)?
    /// Set once, so the session is not reconfigured on every player.
    private var audioSessionConfigured = false

    init() {
        observeAudioInterruptions()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    /// Test-facing: how many players exist right now. The acceptance criterion
    /// is a number, so it has to be readable.
    var livePlayerCount: Int { entries.count }
    var livePlayerIDs: [String] { entries.map(\.id) }

    // MARK: - Visibility

    /// `reporter` identifies the view instance speaking. Optional so the rule
    /// tests, which have no views, can go on calling this with three arguments.
    func reportVisibility(
        id: String,
        fraction: CGFloat,
        distanceFromCentre: CGFloat,
        reporter: UUID? = nil
    ) {
        if let reporter { reporters[id] = reporter }
        visibility[id] = (fraction, distanceFromCentre)
        reconcile()
    }

    func reportOffscreen(id: String, reporter: UUID? = nil, reason: String = "unsaid") {
        // A view that has already been replaced may not close the row that
        // replaced it. See `reporters`.
        if let reporter, let current = reporters[id], current != reporter {
            log.debug("video: stale offscreen for \(id, privacy: .public) ignored (\(reason, privacy: .public))")
            return
        }
        log.debug("video: offscreen \(id, privacy: .public) (\(reason, privacy: .public))")
        reporters[id] = nil
        visibility[id] = nil
        // Gone, not merely hidden: release the decoder rather than holding a
        // paused player for a row that is far away.
        teardown(id: id)
        reconcile()
    }

    /// **Pause everything, keep every player.** Used when the feed is still
    /// the screen but must go quiet — the app leaving the foreground, and an
    /// audio interruption.
    ///
    /// Pause and not release, and the difference is decided by one question:
    /// *is the same video about to be wanted again?* Backgrounding says yes —
    /// the rows have not moved, the person is coming back to the same place,
    /// and rebuilding a decoder there would put a poster back over a picture
    /// that was already on the glass. The cost of keeping them is bounded by
    /// the ceiling of two, and a paused `AVPlayer` in a suspended process is
    /// not decoding anything; iOS reclaims the hardware decoder itself if
    /// another app needs it, and `AVPlayer` reopens it on the way back.
    ///
    /// The other half of the rule, written down because it is a choice and not
    /// an accident: **coming back to the foreground does not resume.**
    /// `playingID` is cleared here, so the next visibility report decides
    /// afresh. Returning to a feed that starts moving and making noise on its
    /// own is worse than returning to a still one, and the first scroll starts
    /// it again.
    func suspendAll(reason: String) {
        for entry in entries { entry.player.pause() }
        playingID = nil
        log.info("video: suspended all (\(reason, privacy: .public))")
    }

    /// **Release everything, and forget what was on screen.** Used when the
    /// feed stops being the screen at all — opening a post, switching account.
    ///
    /// The opposite answer to `suspendAll`, from the same question: nothing
    /// here is about to be wanted again. The post that was opened has its own
    /// media to decode, and holding two paused feed players while it does that
    /// is spending the ceiling on rows nobody is looking at. The audio session
    /// goes back for the same reason — this screen is not even visible, so
    /// keeping it active would hold another app's music down for no one.
    ///
    /// **This also clears `visibility` and `reporters`, and that has a
    /// consequence worth stating.** The decision is made entirely from those
    /// maps, so afterwards *nothing* is eligible and nothing will play until
    /// rows report themselves again. Coming back from a post used to land
    /// exactly there: the rows were rebuilt but their geometry was unchanged,
    /// so `onChange` had nothing to fire on, and the feed sat silent until it
    /// was scrolled. `VideoPlayerView.onAppear` is what now guarantees the
    /// rebuilt rows speak up, and
    /// `comingBackFromAPostRestartsTheDecisionAndNotJustPlayback` is what
    /// keeps it true.
    func releaseAll(reason: String) {
        for entry in entries { release(entry) }
        entries.removeAll()
        visibility.removeAll()
        reporters.removeAll()
        presentationSizes.removeAll()
        advanced.removeAll()
        playingID = nil
        // Hand the audio session back. Nothing of ours is playing any more, so
        // holding it active would keep another app's music paused for as long
        // as this screen is not even on.
        releaseAudioSession()
        log.info("video: released all (\(reason, privacy: .public))")
    }

    func toggleMute() {
        isMuted.toggle()
        for entry in entries { entry.player.isMuted = isMuted }
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
        sources[id] = url
        // A video that has already failed does not get another player until
        // someone asks for one by tapping retry. Without this the view's next
        // visibility report — a scroll of one pixel is enough — built a new
        // player for a URL known to 404, which then occupied one of the two
        // slots and pushed a working video out of them.
        guard failures[id] == nil else { return nil }

        if let existing = entries.first(where: { $0.id == id }) {
            touch(id: id)
            return existing.player
        }
        guard shouldHaveAPlayer(id: id) else { return nil }

        if entries.count >= Self.maximumPlayers, let victim = leastRecentlyUsedIdleID() {
            teardown(id: victim)
        }
        guard entries.count < Self.maximumPlayers else { return nil }

        // Before the first player exists, and not once per player: a muted
        // AVPlayer still activates the process's audio session when it starts,
        // and the default category (.soloAmbient) stops whatever the person was
        // listening to. Muting the player does not prevent that; the category
        // does. §5D.4 asks that entering the feed not interrupt music, and this
        // line is the whole of the mechanism.
        if !audioSessionConfigured {
            configureAudioSession(forPlaybackWithSound: !isMuted)
            audioSessionConfigured = true
        }

        let player = AVPlayer(url: url)
        player.isMuted = isMuted
        // Nothing sensible to do with a stalled network stream except wait; the
        // default behaviour of playing whatever has buffered is right here.
        player.automaticallyWaitsToMinimizeStalling = true
        var entry = Entry(id: id, player: player)
        attachObservations(to: &entry)
        entries.append(entry)
        log.info("video: created player for \(id, privacy: .public) (\(self.entries.count) live)")
        // The player now exists, so the decision that could not be acted on a
        // moment ago can be. Without this the first video in a feed waits for
        // the next scroll event before it starts.
        reconcile()
        return player
    }

    /// The player this video already has, or nil. Never creates one — safe to
    /// read while a view is drawing itself, which is the whole point: the view
    /// draws what exists instead of remembering what it was once given.
    func activePlayer(for id: String) -> AVPlayer? {
        entries.first(where: { $0.id == id })?.player
    }

    func failure(for id: String) -> String? { failures[id] }

    /// True once the decoder has told us how big the picture is. Until then
    /// there is nothing to draw and the poster stays up.
    func hasPicture(for id: String) -> Bool {
        guard let size = presentationSizes[id] else { return false }
        return size.width > 0 && size.height > 0
    }

    /// Forget a failure and build the video again from scratch.
    ///
    /// The old retry bumped a counter in the view. Nothing read the counter, no
    /// player was rebuilt, and — because the view only asks for a player when
    /// its visibility *changes* — the row sat on its poster until it was
    /// scrolled. Doing the rebuild here means the tap is the event.
    func retry(id: String) {
        failures[id] = nil
        presentationSizes[id] = nil
        advanced.remove(id)
        teardown(id: id)
        if let url = sources[id] {
            _ = player(for: id, url: url)
        }
        reconcile()
        log.info("video: retrying \(id, privacy: .public)")
    }

    /// Whether a given video is actually playing, as the player itself reports
    /// it — not as the coordinator believes. Test-facing: `playingID` is a
    /// belief, and the defect this exists to catch was a belief that never
    /// became a `play()` call.
    func isActuallyPlaying(id: String) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        return entry.player.timeControlStatus != .paused
    }

    /// The player's current playback position, for proving time advances.
    func currentTime(of id: String) -> Double? {
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
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
              let entry = entries.first(where: { $0.id == playing }) else { return }
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
        let size = presentationSizes[playing] ?? .zero
        // Buffered and duration too. "The clock is not moving" has three very
        // different causes — nothing downloaded, downloaded but not decoding,
        // and *the clip is simply over* — and t alone matches all three.
        let buffered = entry.player.currentItem?.loadedTimeRanges
            .map { $0.timeRangeValue }
            .map { String(format: "%.1f-%.1f", $0.start.seconds, ($0.start + $0.duration).seconds) }
            .joined(separator: ",") ?? "-"
        let duration = entry.player.currentItem?.duration.seconds ?? .nan
        log.info("""
            video clock: t=\(String(format: "%.2f", time), privacy: .public) \
            of=\(String(format: "%.2f", duration), privacy: .public) \
            status=\(status, privacy: .public) waiting=\(reason, privacy: .public) \
            item=\(itemStatus, privacy: .public) \
            buffered=\(buffered, privacy: .public) \
            size=\(Int(size.width))x\(Int(size.height), privacy: .public)
            """)
    }

    // MARK: - Watching one player

    private func attachObservations(to entry: inout Entry) {
        guard let item = entry.player.currentItem else { return }
        let id = entry.id

        // AVPlayer reports a load failure on its *item*, asynchronously, and
        // never throws. Without watching for it the interface has no way to
        // know: the previous version's failure branch was unreachable code.
        entry.statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let reason = item.error?.localizedDescription ?? "unknown"
            Task { @MainActor [weak self] in
                self?.markFailed(id: id, reason: reason)
            }
        }
        // The picture size arrives when the decoder has actually opened the
        // video track. "Playing" can be true before this; a picture cannot.
        entry.sizeObservation = item.observe(\.presentationSize, options: [.new, .initial]) { [weak self] item, _ in
            let size = item.presentationSize
            guard size.width > 0, size.height > 0 else { return }
            Task { @MainActor [weak self] in
                self?.markPicture(id: id, size: size)
            }
        }
        // Two boundary marks, then silence. This is the only thing that can say
        // "the clock moved" without asking every frame.
        let times = Self.progressMarks.map {
            NSValue(time: CMTime(seconds: $0, preferredTimescale: 600))
        }
        entry.timeObserver = entry.player.addBoundaryTimeObserver(
            forTimes: times, queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.markAdvanced(id: id)
            }
        }
        // **A feed video that reaches its end goes back to the beginning.**
        //
        // Without this, an `AVPlayer` pauses on the last frame it decoded and
        // stays there: the picture stops changing and never starts again,
        // there is no play control over a row that already has a picture, and
        // scrolling away and back tears the player down rather than replaying
        // it. From the outside that is indistinguishable from a decoder that
        // died — which is exactly how it was reported. Clips in this feed are
        // seconds long, so "played once, then frozen" is the state a row
        // spends almost all of its time in.
        //
        // Registered against this item specifically: a notification for
        // another row's item must not restart this one.
        entry.endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartFromTheBeginning(id: id) }
        }
    }

    /// Back to zero, and playing again only if this is still the chosen video.
    ///
    /// The seek happens either way, so a row that is paused at its end is left
    /// showing its first frame rather than its last — that is the frame its
    /// poster stands in for, and the one it should show if it is asked to play
    /// again. The `play()` is conditional: a video that lost the centre, an
    /// app in the background and a phone call in progress all leave
    /// `playingID` pointing somewhere else or nowhere, and none of them may be
    /// overridden by a clip happening to run out at that moment.
    private func restartFromTheBeginning(id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entry.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        guard playingID == id, !isInterrupted else {
            log.debug("video: \(id, privacy: .public) reached its end while not the chosen one")
            return
        }
        entry.player.play()
        log.info("video: \(id, privacy: .public) looped")
    }

    private func markFailed(id: String, reason: String) {
        guard failures[id] == nil else { return }
        // Our own words, not the framework's: this is shown to a person.
        failures[id] = "Video failed to load. Tap to retry."
        log.error("video: \(id, privacy: .public) failed — \(reason, privacy: .public)")
        // Free the slot and let the next-best video have the screen.
        teardown(id: id)
        reconcile()
    }

    private func markPicture(id: String, size: CGSize) {
        guard presentationSizes[id] != size else { return }
        presentationSizes[id] = size
        log.info("video: \(id, privacy: .public) picture \(Int(size.width))x\(Int(size.height))")
    }

    private func markAdvanced(id: String) {
        guard !advanced.contains(id) else { return }
        advanced.insert(id)
        log.info("video: \(id, privacy: .public) clock passed \(Self.progressMarks[0])s")
    }

    // MARK: - Lifetime

    private func shouldHaveAPlayer(id: String) -> Bool {
        guard let mine = visibility[id] else { return false }
        return mine.fraction >= Self.visibilityThreshold
    }

    private func leastRecentlyUsedIdleID() -> String? {
        entries.first(where: { $0.id != playingID })?.id
    }

    private func touch(id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        entries.append(entry)
    }

    private func teardown(id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        release(entry)
        presentationSizes[id] = nil
        advanced.remove(id)
        if playingID == id { playingID = nil }
        log.info("video: tore down \(id, privacy: .public) (\(self.entries.count) live)")
    }

    /// Stop, unhook, and drop the item.
    ///
    /// Order matters: a time observer still registered when its player
    /// deallocates is an assertion failure inside AVFoundation, not a quiet
    /// leak. `replaceCurrentItem(with: nil)` is what actually frees the
    /// decoder; dropping the reference alone leaves it alive until something
    /// else drains, which is how "the count is zero but the memory is not"
    /// happens.
    private func release(_ entry: Entry) {
        entry.player.pause()
        entry.statusObservation?.invalidate()
        entry.sizeObservation?.invalidate()
        if let token = entry.timeObserver {
            entry.player.removeTimeObserver(token)
        }
        if let endObserver = entry.endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        entry.player.replaceCurrentItem(with: nil)
    }

    // MARK: - The decision

    private func reconcile() {
        // Nothing plays during a phone call, however much the list scrolls.
        guard !isInterrupted else {
            for entry in entries { entry.player.pause() }
            playingID = nil
            return
        }

        // Eligible = enough of it is on screen, and not known broken. A failed
        // video sitting in the middle of the screen must not win, or it would
        // hold the winner's slot while being unable to play and the working
        // video below it would stay still.
        let eligible = visibility
            .filter { $0.value.fraction >= Self.visibilityThreshold && failures[$0.key] == nil }
            .sorted { $0.value.distanceFromCentre < $1.value.distanceFromCentre }
        let winner = eligible.first?.key

        for entry in entries where entry.id != winner {
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
        guard let entry = entries.first(where: { $0.id == winner }) else {
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

    // MARK: - Audio

    /// Off the main thread, deliberately.
    ///
    /// `setActive` talks to the media server and can block; the test run
    /// reported it as a main-thread hang warning, and a hang while someone is
    /// scrolling is exactly the kind of thing that gets blamed on the video
    /// decoder. Nothing here needs to be synchronous — the player's own
    /// category is read when playback starts, which is after this returns.
    private func configureAudioSession(forPlaybackWithSound withSound: Bool) {
        let log = self.log
        Task.detached(priority: .userInitiated) {
            do {
                let session = AVAudioSession.sharedInstance()
                if withSound {
                    // Only now does this app claim the audio session.
                    try session.setCategory(.playback, mode: .moviePlayback)
                    try session.setActive(true)
                } else {
                    // .ambient plays alongside whatever else is playing and
                    // obeys the ring/silent switch — the right category for
                    // muted, incidental video in a feed.
                    try session.setCategory(.ambient, mode: .moviePlayback)
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                }
            } catch {
                log.error("audio session: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Category left alone on purpose: an unmute is a choice, and coming back
    /// to the feed should not silently undo it.
    private func releaseAudioSession() {
        let log = self.log
        Task.detached(priority: .utility) {
            do {
                try AVAudioSession.sharedInstance()
                    .setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                log.debug("audio session release: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Phone calls, Siri, an alarm. Nothing here resumed before: an
    /// interruption paused the player through the system and the coordinator
    /// went on believing it was playing, so the next scroll found
    /// `playingID == winner` and returned early — the video stayed dead for the
    /// rest of the session.
    private func observeAudioInterruptions() {
        // `addObserver` and not `NotificationCenter.notifications(named:)`:
        // the async sequence only subscribes when its task first runs, which
        // is at the next suspension point. An interruption in that window is
        // simply missed — a test that posted one immediately after building
        // the coordinator caught exactly that. Registration has to be
        // finished by the time `init` returns.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                self?.handleInterruption(
                    type: type,
                    options: AVAudioSession.InterruptionOptions(rawValue: options)
                )
            }
        }
    }

    /// Internal rather than private so the two halves of an interruption can be
    /// tested without a phone call.
    func handleInterruption(type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            isInterrupted = true
            suspendAll(reason: "audio interruption")
        case .ended:
            isInterrupted = false
            // `.shouldResume` is the system saying the interruption is over and
            // we may take the session back. Without it — a call that is still
            // on, another app that kept the session — we stay quiet, and the
            // next scroll starts playback the ordinary way.
            guard options.contains(.shouldResume) else {
                log.info("video: interruption ended, system says do not resume")
                return
            }
            if !isMuted { configureAudioSession(forPlaybackWithSound: true) }
            reconcile()
            log.info("video: interruption ended, resumed \(self.playingID ?? "nothing", privacy: .public)")
        @unknown default:
            isInterrupted = false
        }
    }
}
