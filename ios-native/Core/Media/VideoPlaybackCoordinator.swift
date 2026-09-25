import AVFoundation
import Foundation
import OSLog

/// **Every wait in video playback, in one place.**
///
/// Scattered timeouts are how a product ends up with an indicator that appears
/// after 300ms in one row and three seconds in the next. These are one
/// decision, and the tests measure the boundaries from here rather than
/// repeating the numbers. Each default is a judgement, so each is argued:
///
/// - **`feedbackDelay` 0.6s — nothing is shown before this.** Under Nielsen's
///   1s "flow of thought stays uninterrupted" boundary, so the badge still
///   reads as an answer to what just happened; well over the 0.1–0.3s band
///   where an indicator reads as a flash of noise rather than information.
///   Measured against the local test server (`a2-test-media.sh`), because the
///   number wants an anchor and not a feeling: a whole-file range request over
///   loopback round-trips in 0.7–3.4ms, three orders of magnitude under this
///   threshold. So on the media these tests use, *the only waits that reach
///   0.6s are real ones* — which is what stops the badge strobing, rather than
///   a guess about how long a hiccup lasts. On a real network the same
///   threshold is the perception argument above and nothing more; see the
///   report's list of what a simulator cannot settle.
/// - **`confirmationSamples` 3, as well as the 0.6s.** Two conditions rather
///   than one larger number: on a loaded machine a single late timer tick is
///   indistinguishable from a frozen clock, and the honest fix for a load
///   artefact is to require enough samples *and* enough wall clock.
/// - **`automaticRecoveryDelays` [1.5, 4, 9]s, and then no more.** Roughly
///   doubling gaps, three attempts, counted from the moment the stall was
///   confirmed. A rebuilt item is a new set of HTTP requests, so this is the
///   request-storm bound: **three per video, not three per stall**, and with
///   the two-player ceiling at most six anywhere. The count survives the
///   episode that spent it and is returned only by
///   `healthyProgressToRefundBudget` seconds of real playback — so a stream
///   that flaps cannot buy itself more attempts by stalling again, which is
///   exactly what it did while the counter lived in the episode.
/// - **`recoveryOfferDelay` 10s — the person gets a button.** Nielsen again:
///   ten seconds is about the limit for holding attention on a wait nobody has
///   acknowledged. It also sits one second after the last automatic attempt,
///   so the button only ever appears once the machine has run out of ideas.
enum VideoStallPolicy {
    /// How often the playing video's clock is compared with its last reading.
    static let pollInterval: TimeInterval = 0.2
    /// Wall clock a stall must last before anything is shown.
    static let feedbackDelay: TimeInterval = 0.6
    /// …and how many consecutive non-advancing samples it must also have.
    static let confirmationSamples = 3
    /// When automatic recovery is attempted, measured from confirmation.
    static let automaticRecoveryDelays: [TimeInterval] = [1.5, 4, 9]
    /// The bound. Three, and the list above is the whole schedule.
    static var maximumAutomaticRecoveries: Int { automaticRecoveryDelays.count }
    /// When the person is offered a way out, measured from confirmation.
    static let recoveryOfferDelay: TimeInterval = 10
    /// Two clock readings closer than this are "the same reading". One frame at
    /// 15fps is 66ms; 10ms is comfortably under a frame and comfortably over
    /// the noise in `currentTime()`.
    static let progressEpsilon: Double = 0.01
    /// Seconds of real playback that refund the automatic-recovery budget.
    ///
    /// Three, and the number was measured rather than picked. A rebuilt item
    /// against a stream that is still broken buys roughly a second of playback
    /// before it stalls again — so a threshold of one second handed the budget
    /// straight back and the bound never bit. Three seconds is more than any
    /// failed recovery managed, and less than one loop of a four-second feed
    /// clip, so a video that is genuinely working refunds on every lap.
    static let healthyProgressToRefundBudget: Double = 3.0
    /// How far *before* the stall a recovery may land.
    ///
    /// This number is not free: it has to stay below
    /// `healthyProgressToRefundBudget`, and `recoverySeekLandsInsideTheRefundWindow`
    /// pins that. The seek after a rebuild deliberately lands at or before
    /// where the clock stopped, because the bytes after it are the ones that
    /// are missing. Left unbounded — which it was, as
    /// `toleranceBefore: .positiveInfinity` — "at or before" includes the
    /// first keyframe in the file: against the 16s test clip cut at 35%, a
    /// recovery replayed the whole healthy 5.6s, which is more playback than
    /// the refund threshold, so every failed recovery handed the budget back
    /// and the bound never bit. The test that caught it sat at
    /// `phase=playing attempts=1` for sixty seconds.
    ///
    /// 1.5s is under half the refund threshold, so even two recoveries landing
    /// at the far edge cannot add up to a refund.
    static let recoverySeekToleranceBefore: TimeInterval = 1.5

    // MARK: - What counts as playing

    /// How far the clock may run past the bytes that arrived before the
    /// picture cannot be real.
    ///
    /// **Measured on CI, not assumed.** On the iOS 26.2 simulator (run
    /// 35801729274, e203196) a rebuilt item's clock reached 7.00s with
    /// `loadedTimeRanges` ending at 5.73s, and decoded 14 frames in 3.6s where
    /// the clip has fifteen a second. On iOS 27 the same item stops at the
    /// edge of its bytes. A clock ahead of its data is moving without showing
    /// anything new, which is a stall to the person watching, whatever the
    /// player's status says. A quarter second is well past the few frames of
    /// read-ahead a loaded range can lag by.
    static let aheadOfLoadedTolerance: Double = 0.25

    /// How much of a clip's end may be missing from what was loaded when
    /// AVFoundation says it played to the end, and still be a real end.
    static let endCoverageTolerance: Double = 0.5

    /// The clock is running over bytes that never arrived.
    ///
    /// Unknown loaded ranges (zero) decide nothing: a stream that reports none
    /// is judged the way it always was.
    static func isAheadOfLoaded(clock: Double, loadedTo: Double) -> Bool {
        loadedTo > 0 && clock > loadedTo + aheadOfLoadedTolerance
    }

    /// The part of a clock movement that counts as playback towards
    /// `healthyProgressToRefundBudget`: forwards, and only as far as the bytes
    /// that arrived.
    ///
    /// Backwards is a loop or a seek, and replaying is not recovering. Beyond
    /// the loaded edge is the clock running on empty. Both still end a stall —
    /// movement is movement — but neither buys the stream more automatic
    /// rebuilds, which is what kept CI's recovery test from ever reaching the
    /// manual offer.
    static func refundableProgress(from previous: Double, to clock: Double, loadedTo: Double) -> Double {
        guard clock - previous > progressEpsilon, loadedTo > 0 else { return 0 }
        return max(0, min(clock, loadedTo) - previous)
    }

    /// Whether "played to the end" really was the end.
    ///
    /// A clip whose loaded ranges stop short of its duration did not finish;
    /// it ran out of data. Looping it replays the part that did arrive — real
    /// frames, which refunded the recovery budget on every lap — and a person
    /// sees the opening seconds forever with nothing saying the rest is gone.
    /// An unknown duration trusts the notification, as before.
    static func endIsReal(loadedTo: Double, duration: Double) -> Bool {
        guard duration.isFinite, duration > 0 else { return true }
        return loadedTo >= duration - endCoverageTolerance
    }

    /// The far edge of what an item has loaded, in seconds. Zero when unknown.
    static func loadedEnd(of item: AVPlayerItem?) -> Double {
        item?.loadedTimeRanges
            .map { $0.timeRangeValue }
            .map { ($0.start + $0.duration).seconds }
            .filter { $0.isFinite }
            .max() ?? 0
    }
}

/// What a video row is doing, said once so that every caller agrees.
///
/// The point of the enum is question 2 of the acceptance: *feedback about
/// waiting may only be shown when the person expects playback and it genuinely
/// cannot continue.* Before this existed, "not moving" was one undifferentiated
/// thing and the only branch that could react to it was `status == .failed` —
/// which a broken byte stream never reaches, because the item stays
/// `.readyToPlay` while the player sits in `waitingToPlayAtSpecifiedRate`
/// holding its last frame. Zero coverage, no message, no way out.
///
/// Exactly one case — `.stalled` — is allowed to put anything on the glass.
enum VideoPlaybackState: Equatable {
    /// No player: off screen, or under the visibility threshold. The poster.
    case idle
    /// **First load.** A player exists and the decoder has not yet said how
    /// big the picture is. The poster stays up; this is not an error and gets
    /// no spinner, because the poster already says "a video lives here".
    case opening
    /// A picture, and the clock is moving.
    case playing
    /// **Buffering mid-playback.** Chosen, told to play, and not advancing.
    /// `offeringRecovery` is the second stage: automatic attempts are spent
    /// and the person is being shown a button.
    case stalled(offeringRecovery: Bool)
    /// **The person stopped it.** Never an error, whatever the network does.
    case pausedByViewer
    /// **The app left the foreground**, or the audio session was interrupted.
    /// Silence here is the design (see `suspendAll`), not a fault.
    case suspended
    /// On screen and perfectly healthy, but another row has the centre.
    case waitingItsTurn
    /// **The clip ran out** and was not restarted, because this row is not the
    /// chosen one. A clock parked at the duration is the commonest way a
    /// working video looks broken, and it must never be called a stall.
    case ended
    /// **Explicit failure**, with the words to show.
    case failed(String)

    /// The only state that draws anything about waiting.
    var showsWaitingFeedback: Bool {
        if case .stalled = self { return true }
        return false
    }

    /// For the probe line the UI tests read.
    var name: String {
        switch self {
        case .idle: return "idle"
        case .opening: return "opening"
        case .playing: return "playing"
        case .stalled(let offering): return offering ? "stalled-offering" : "stalled"
        case .pausedByViewer: return "pausedByViewer"
        case .suspended: return "suspended"
        case .waitingItsTurn: return "waitingItsTurn"
        case .ended: return "ended"
        case .failed: return "failed"
        }
    }
}

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
        /// AVFoundation's own "this stream is not going to finish" signal.
        var failedToEndObserver: (any NSObjectProtocol)?
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
    /// True from `suspendAll` until something on screen moves again. Only a
    /// label: the quiet-on-return rule is `suspendAll` clearing `playingID`,
    /// and this exists so a silent row can say *why* it is silent instead of
    /// being indistinguishable from a stalled one.
    private(set) var isSuspended = false
    /// Videos the person stopped by hand. Kept apart from every other reason
    /// for silence, because this one may never show a spinner however long it
    /// lasts and however dead the network is.
    private(set) var viewerPaused: Set<String> = []
    /// Videos whose clip ran out and were not restarted.
    private(set) var reachedEnd: Set<String> = []
    /// Videos whose player stopped at an end its bytes never reached.
    ///
    /// AVFoundation parks such a player as `.paused`, and the sampler reads
    /// `.paused` as "nobody asked for playback" and clears the stall. CI run
    /// 35836743915 (iOS 26.2): after the third automatic rebuild the clock ran
    /// from 6.48s to the clip's 16.00s over bytes that ended at 5.53s, the
    /// player paused there, the stall was cleared before the ten seconds that
    /// earn the manual offer — and the row sat on a frozen frame calling
    /// itself `playing`, with nothing said and nothing offered, for as long
    /// as anyone watched. Cleared by a new item, a real end, or the row going.
    private(set) var strandedAtFalseEnd: Set<String> = []

    /// The one video currently showing buffering feedback, or nil.
    ///
    /// Published as a single id rather than a map because only the chosen video
    /// can stall, and because every mutation of an `@Observable` stored
    /// property redraws the rows watching it — the per-sample bookkeeping below
    /// is deliberately `@ObservationIgnored` so that a 5Hz monitor does not
    /// invalidate the feed five times a second.
    private(set) var bufferingID: String?
    /// The video whose automatic attempts are spent and which is offering the
    /// person a button.
    private(set) var recoveryOfferedID: String?

    /// One stall episode.
    ///
    /// **The attempt count is deliberately not in here.** It used to be, and
    /// that made the bound a lie: every automatic rebuild bought a second or
    /// two of playback, which ended the episode and took the counter with it,
    /// so the next stall started again from zero. Measured against
    /// `/a2-cutoff.mp4` the loop ran `stall → rebuild 1 → stall → rebuild 1 →
    /// …` indefinitely, with `attempts` reading 0 the whole time and the
    /// person never offered anything. A budget that resets whenever it is spent
    /// is not a budget. It lives in `recoveryAttempts`, keyed by video, and is
    /// returned only by real playback.
    private struct Stall {
        let began: Date
        var samples: Int
        var confirmed = false
    }

    @ObservationIgnored private var stalls: [String: Stall] = [:]
    /// The previous clock reading per video. Kept outside a stall so the first
    /// sample of an episode already has something to compare against; a record
    /// created with `lastTime == now` would call its own first sample a stall.
    @ObservationIgnored private var lastClock: [String: Double] = [:]
    /// The far edge of what has been downloaded, per video. See `sampleTheClock`.
    @ObservationIgnored private var lastBufferedEnd: [String: Double] = [:]
    /// Media seconds played since the last confirmed stall ended, per video.
    @ObservationIgnored private var healthyProgress: [String: Double] = [:]
    /// Automatic rebuilds spent per video, across stall episodes. Reset only
    /// by `healthyProgressToRefundBudget` seconds of real playback, or by a
    /// person asking again.
    @ObservationIgnored private var recoveryAttempts: [String: Int] = [:]
    @ObservationIgnored private var stallTask: Task<Void, Never>?

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
        // Something moved, so the feed is being looked at again. `suspendAll`
        // deliberately does not resume by itself — this is the "until something
        // moves" half of that sentence, and it only changes the *label*: the
        // decision below is still made from scratch.
        isSuspended = false
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
        // Said out loud, because a row that is silent because the app is in the
        // background must be able to prove that is why — otherwise it looks
        // exactly like a row that is silent because the stream died, and the
        // second one is supposed to show a spinner.
        isSuspended = true
        clearAllStalls()
        lastClock.removeAll()
        lastBufferedEnd.removeAll()
        updateStallMonitor()
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
        isSuspended = false
        viewerPaused.removeAll()
        reachedEnd.removeAll()
        strandedAtFalseEnd.removeAll()
        clearAllStalls()
        lastClock.removeAll()
        lastBufferedEnd.removeAll()
        healthyProgress.removeAll()
        recoveryAttempts.removeAll()
        updateStallMonitor()
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
            video clock: phase=\(self.state(for: playing).name, privacy: .public) \
            t=\(String(format: "%.2f", time), privacy: .public) \
            of=\(String(format: "%.2f", duration), privacy: .public) \
            status=\(status, privacy: .public) waiting=\(reason, privacy: .public) \
            item=\(itemStatus, privacy: .public) \
            buffered=\(buffered, privacy: .public) \
            size=\(Int(size.width))x\(Int(size.height), privacy: .public)
            """)
    }

    // MARK: - Watching one player

    /// Split in two on purpose: **the item is replaceable and the player is
    /// not.**
    ///
    /// Recovering from a broken byte stream means building a new
    /// `AVPlayerItem` and handing it to the same `AVPlayer` — that keeps the
    /// layer attached, keeps the last frame on the glass instead of flashing
    /// the poster, and keeps `isMuted` where it was. Everything observed on the
    /// item has to be re-made when that happens; the boundary time observer is
    /// on the player and must *not* be, because removing and re-adding it is
    /// how the "clock passed 0.3s" flag would get lost mid-clip.
    private func attachObservations(to entry: inout Entry) {
        attachPlayerObservations(to: &entry)
        attachItemObservations(to: &entry)
    }

    private func attachPlayerObservations(to entry: inout Entry) {
        let id = entry.id
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
    }

    private func attachItemObservations(to entry: inout Entry) {
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
        // **AVFoundation saying the stream will not finish.**
        //
        // The only signal the framework volunteers for a connection that died
        // mid-clip. It is *not* `status == .failed` — the item stays
        // `.readyToPlay`, which is exactly why the old failure branch had zero
        // coverage for this. Taken as an instruction to stop waiting out the
        // 0.6s confirmation and treat the stall as confirmed now: the system
        // has already told us there is nothing more coming.
        //
        // Not turned into a `.failed`. A dead stream halfway through a clip is
        // recoverable — the next request usually works — and a failure would
        // throw away the frame that is still on the glass.
        entry.failedToEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated {
                self?.confirmStallNow(
                    id: id,
                    reason: error?.localizedDescription ?? "failedToPlayToEndTime"
                )
            }
        }
    }

    /// Unhooks everything that belongs to the current item, so the item can be
    /// thrown away without leaving observers pointed at it.
    private func detachItemObservations(from entry: inout Entry) {
        entry.statusObservation?.invalidate()
        entry.statusObservation = nil
        entry.sizeObservation?.invalidate()
        entry.sizeObservation = nil
        if let endObserver = entry.endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            entry.endObserver = nil
        }
        if let failedToEndObserver = entry.failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
            entry.failedToEndObserver = nil
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
        // An end the bytes never reached is the stream stopping, not the clip
        // finishing: no loop, no seek to zero. The clock stays where it is,
        // ahead of its data, which the sampler reads as the stall it is.
        if let item = entry.player.currentItem, item.duration.isNumeric {
            let loaded = VideoStallPolicy.loadedEnd(of: item)
            let duration = item.duration.seconds
            if !VideoStallPolicy.endIsReal(loadedTo: loaded, duration: duration) {
                strandedAtFalseEnd.insert(id)
                confirmStallNow(
                    id: id,
                    reason: "reached the end with \(String(format: "%.2f", loaded))s of \(String(format: "%.2f", duration))s loaded"
                )
                return
            }
        }
        strandedAtFalseEnd.remove(id)
        // Recorded before the seek, and cleared below only if this row really
        // starts again. A clock parked at the duration is the commonest way a
        // perfectly healthy video looks broken from the outside, and the stall
        // monitor has to be able to tell the two apart by asking rather than
        // by guessing from the number.
        reachedEnd.insert(id)
        // A clip running out is not progress, and must not refund the
        // automatic-recovery budget.
        lastClock[id] = nil
        entry.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        guard playingID == id, !isInterrupted, !isSuspended, !viewerPaused.contains(id) else {
            log.debug("video: \(id, privacy: .public) reached its end while not the chosen one")
            return
        }
        reachedEnd.remove(id)
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

    // MARK: - Stalling

    /// What this row is doing, in the one vocabulary everything else uses.
    ///
    /// Order matters and is the whole argument: an explicit failure outranks
    /// everything, then the reasons a person would expect silence (they
    /// stopped it; the app is not in the foreground; another row has the
    /// centre; the clip ran out), and only what is left over can be a stall.
    /// Reading it the other way round is how "not moving" became one
    /// undifferentiated thing that nothing could react to.
    func state(for id: String) -> VideoPlaybackState {
        if let message = failures[id] { return .failed(message) }
        if viewerPaused.contains(id) { return .pausedByViewer }
        guard entries.contains(where: { $0.id == id }) else { return .idle }
        // Before anything else about playback: the app is not on screen.
        if isSuspended || isInterrupted { return .suspended }
        if reachedEnd.contains(id) { return .ended }
        guard playingID == id else { return .waitingItsTurn }
        if stalls[id]?.confirmed == true {
            // **A first load that is slow is still a first load.**
            //
            // A video that has never produced a picture is sitting under its
            // own poster, with a play badge on it, and that already says
            // everything a spinner would: a video lives here and it is coming.
            // Putting a second indicator over it buys nothing and costs the
            // one measurement that distinguishes the poster from the picture.
            // Only when the wait has gone on past `recoveryOfferDelay` does
            // this become worth saying out loud — and then what is said is a
            // way out, not a wheel.
            if !hasPicture(for: id) && recoveryOfferedID != id { return .opening }
            return .stalled(offeringRecovery: recoveryOfferedID == id)
        }
        guard hasPicture(for: id) else { return .opening }
        return .playing
    }

    /// True only where §2 allows something to be drawn about waiting.
    func isBuffering(for id: String) -> Bool { state(for: id).showsWaitingFeedback }

    /// True once the automatic attempts are spent and the person should be
    /// given something to press.
    func needsManualRecovery(for id: String) -> Bool { recoveryOfferedID == id }

    /// Test-facing: how many automatic rebuilds this video has been given.
    /// The acceptance criterion is a bound, so it has to be readable.
    func automaticRecoveryAttempts(for id: String) -> Int { recoveryAttempts[id] ?? 0 }

    /// **The person stopped it, or started it again.**
    ///
    /// A first-class state rather than "paused and we forgot why": a video the
    /// person paused must never grow a spinner, however dead the network gets
    /// underneath it, and the only way to guarantee that is for the reason to
    /// survive in the model.
    func setViewerPaused(_ paused: Bool, id: String) {
        if paused {
            viewerPaused.insert(id)
            entries.first(where: { $0.id == id })?.player.pause()
            if playingID == id { playingID = nil }
            clearStall(id: id)
        } else {
            viewerPaused.remove(id)
        }
        reconcile()
    }

    /// The button under a stall that has gone on too long.
    ///
    /// Not `retry(id:)`: there is no failure to clear, the player is fine, and
    /// tearing it down would drop the frame that is still on the glass and put
    /// the poster back over it. This rebuilds the item on the same player and
    /// returns the automatic budget, because a person asking again is new
    /// information.
    func recoverNow(id: String) {
        recoveryAttempts[id] = 0
        healthyProgress[id] = 0
        recoveryOfferedID = nil
        log.info("video: \(id, privacy: .public) manual recovery")
        rebuildItem(id: id, reason: "manual")
    }

    /// Starts the monitor while something is playing and stops it otherwise.
    ///
    /// Only while something is playing, because a timer that never stops is
    /// how an app becomes one that XCUITest can never call idle — a periodic
    /// probe once cost a single test 1070 seconds of waiting. Everything it
    /// touches per tick is `@ObservationIgnored`; the two published values
    /// change on transitions only, which for a healthy feed is never.
    private func updateStallMonitor() {
        if playingID != nil {
            guard stallTask == nil else { return }
            stallTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(VideoStallPolicy.pollInterval))
                    guard let self else { return }
                    self.sampleTheClock()
                }
            }
        } else {
            stallTask?.cancel()
            stallTask = nil
        }
    }

    /// One reading of the playing video's clock, and what follows from it.
    private func sampleTheClock() {
        guard let id = playingID, let entry = entries.first(where: { $0.id == id }) else {
            clearAllStalls()
            return
        }
        // Every reason for legitimate silence, checked before the clock is even
        // read. §2: a normal pause, an off-screen row and a backgrounded app
        // must not be able to produce a single pixel of error.
        guard !isInterrupted, !isSuspended, !viewerPaused.contains(id) else {
            clearStall(id: id)
            return
        }
        // A player that stopped at an end its bytes never reached is paused
        // by AVFoundation, not by anyone: the person still expects a picture,
        // so it goes on counting as stalled until a rebuild or the offer.
        // There is no clock to reason about — it is parked at the duration.
        if strandedAtFalseEnd.contains(id) {
            noteStallSample(id: id)
            return
        }
        // `.paused` means nobody asked for playback. A stall is only a stall
        // when the person expects the picture to move.
        guard entry.player.timeControlStatus != .paused else {
            clearStall(id: id)
            return
        }
        let now = entry.player.currentTime().seconds
        guard now.isFinite else { return }

        let buffered = VideoStallPolicy.loadedEnd(of: entry.player.currentItem)

        // The clip simply being over is the third cause of a frozen clock, and
        // the one that must never be called a stall — when it is over because
        // its bytes ran out, not because they stopped arriving.
        if let item = entry.player.currentItem, item.duration.isNumeric {
            let duration = item.duration.seconds
            if duration > 0, now >= duration - VideoStallPolicy.progressEpsilon,
               VideoStallPolicy.endIsReal(loadedTo: buffered, duration: duration) {
                clearStall(id: id)
                return
            }
        }

        // **Bytes arriving count as progress even when the clock is still.**
        //
        // Without this, every slow first load is a stall: the clock sits at
        // zero until AVFoundation decides it can play through, which on a cold
        // fetch is a second or two of perfectly healthy downloading. The
        // buffered edge is the difference between "nothing is happening" and
        // "something is happening that has not reached the screen yet", and
        // only the first of those is a stall.
        let previousBuffered = lastBufferedEnd[id]

        defer {
            lastClock[id] = now
            lastBufferedEnd[id] = buffered
        }
        // The first reading of an episode only establishes a baseline. A record
        // built with `lastTime == now` would call its own first sample a stall.
        guard let previous = lastClock[id] else { return }

        // A clock ahead of its bytes shows nothing new, whatever it says.
        // Data still arriving is the one excuse, as it is for a still clock.
        if VideoStallPolicy.isAheadOfLoaded(clock: now, loadedTo: buffered) {
            if let previousBuffered, buffered > previousBuffered + VideoStallPolicy.progressEpsilon {
                clearStall(id: id)
            } else {
                noteStallSample(id: id)
            }
            return
        }

        let moved = abs(now - previous)
        if moved > VideoStallPolicy.progressEpsilon {
            noteProgress(
                id: id,
                refundable: VideoStallPolicy.refundableProgress(from: previous, to: now, loadedTo: buffered)
            )
            return
        }
        if let previousBuffered, buffered > previousBuffered + VideoStallPolicy.progressEpsilon {
            // Downloading, just not playing yet. Not a stall, and not progress
            // that refunds anything either — no picture moved.
            clearStall(id: id)
            return
        }
        noteStallSample(id: id)
    }

    /// The clock moved — forwards, or backwards because the clip looped or
    /// someone sought. Movement of any kind ends a stall; only `refundable`
    /// seconds — forwards, over bytes that arrived — count towards the refund.
    private func noteProgress(id: String, refundable seconds: Double) {
        if stalls[id] != nil {
            log.info("video: \(id, privacy: .public) recovered, clock moving again")
            clearStall(id: id)
        }
        // The budget is refunded by playback, not by time. A connection that
        // flaps cannot buy itself more automatic rebuilds by stalling again:
        // the second or two a rebuild yields is well under the threshold, so
        // the count keeps climbing until it is spent and the person is asked.
        guard (recoveryAttempts[id] ?? 0) > 0 else { return }
        let total = (healthyProgress[id] ?? 0) + seconds
        healthyProgress[id] = total
        if total >= VideoStallPolicy.healthyProgressToRefundBudget {
            recoveryAttempts[id] = 0
            healthyProgress[id] = 0
            log.info("video: \(id, privacy: .public) played on, recovery budget refunded")
        }
    }

    private func noteStallSample(id: String) {
        var stall = stalls[id] ?? Stall(began: Date(), samples: 0)
        stall.samples += 1
        let elapsed = Date().timeIntervalSince(stall.began)

        // **Two conditions, not one bigger number.** Enough samples *and*
        // enough wall clock: on a loaded machine one late timer tick reads
        // exactly like a frozen clock, and raising a single threshold to cover
        // that would also raise it for the case it is meant to catch.
        if !stall.confirmed,
           stall.samples >= VideoStallPolicy.confirmationSamples,
           elapsed >= VideoStallPolicy.feedbackDelay {
            stall.confirmed = true
            healthyProgress[id] = 0
            bufferingID = id
            log.info("video: \(id, privacy: .public) stalled — buffering shown after \(String(format: "%.2f", elapsed))s")
        }

        // **Automatic recovery is for a stream that broke after it was
        // working.** A video that has never produced a picture is not helped
        // by us rebuilding its item: AVFoundation is already retrying the
        // request on its own, and tearing that down restarts the same fetch
        // from nothing — measurably slower for the slow-but-fine case, and no
        // better for the hopeless one. A first load that never arrives gets
        // the button at `recoveryOfferDelay` instead, which is also the
        // stronger bound: nought automatic attempts rather than three.
        let spent = recoveryAttempts[id] ?? 0
        if stall.confirmed,
           hasPicture(for: id),
           spent < VideoStallPolicy.maximumAutomaticRecoveries,
           elapsed >= VideoStallPolicy.automaticRecoveryDelays[spent] {
            recoveryAttempts[id] = spent + 1
            healthyProgress[id] = 0
            stalls[id] = stall
            rebuildItem(id: id, reason: "automatic \(spent + 1)")
            return
        }

        if stall.confirmed, elapsed >= VideoStallPolicy.recoveryOfferDelay, recoveryOfferedID != id {
            recoveryOfferedID = id
            log.info("video: \(id, privacy: .public) offering manual recovery")
        }
        stalls[id] = stall
    }

    /// AVFoundation has told us the stream will not finish: stop waiting out
    /// the confirmation delay, there is nothing to wait for.
    private func confirmStallNow(id: String, reason: String) {
        guard playingID == id, entries.contains(where: { $0.id == id }) else { return }
        guard !isInterrupted, !isSuspended, !viewerPaused.contains(id) else { return }
        var stall = stalls[id] ?? Stall(
            began: Date().addingTimeInterval(-VideoStallPolicy.feedbackDelay),
            samples: VideoStallPolicy.confirmationSamples
        )
        stall.samples = max(stall.samples, VideoStallPolicy.confirmationSamples)
        if !stall.confirmed {
            stall.confirmed = true
            bufferingID = id
            healthyProgress[id] = 0
        }
        stalls[id] = stall
        log.error("video: \(id, privacy: .public) stream will not finish — \(reason, privacy: .public)")
    }

    /// **Recovery is a new item on the same player.**
    ///
    /// Not a new `AVPlayer`, and not `teardown` + `player(for:)`. Three things
    /// follow from that and each one is a requirement:
    ///
    ///   - the `AVPlayerLayer` keeps its player, so the last decoded frame
    ///     stays on the glass instead of the poster flashing back over it;
    ///   - `isMuted` is a property of the *player*, so recovering cannot turn
    ///     the sound on — §5D.4's default survives every retry by
    ///     construction, and is restated below so a later refactor cannot
    ///     quietly lose it;
    ///   - the boundary time observer is on the player too, so "the clock
    ///     passed 0.3s" is not forgotten halfway through a clip.
    ///
    /// The seek puts the new item back where the old one stopped, so recovery
    /// does not silently restart the clip from the beginning.
    private func rebuildItem(id: String, reason: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              let url = sources[id] else { return }
        var entry = entries[index]
        // From where the picture really stopped. A clock that ran on past its
        // bytes — or to the end of a clip that never arrived — would resume
        // the new item somewhere with nothing to show.
        var position = entry.player.currentTime()
        let loaded = VideoStallPolicy.loadedEnd(of: entry.player.currentItem)
        if position.isNumeric, loaded > 0, position.seconds > loaded {
            position = CMTime(seconds: loaded, preferredTimescale: 600)
        }
        detachItemObservations(from: &entry)
        strandedAtFalseEnd.remove(id)
        entry.player.replaceCurrentItem(with: AVPlayerItem(url: url))
        entry.player.isMuted = isMuted
        attachItemObservations(to: &entry)
        entries[index] = entry
        if position.isNumeric, position.seconds > 0 {
            // **Land at or before where it stopped, never after — and not
            // arbitrarily far before.**
            //
            // `toleranceAfter: .zero` first: the next keyframe forward is up to
            // a second *further into the clip*, which is exactly the region
            // whose bytes are missing, so a seek allowed to land there would
            // wait for data that is not coming and the recovery would look like
            // another stall. Landing on an earlier keyframe instead means
            // landing inside what has already been downloaded, and the seek
            // completes at once.
            //
            // `toleranceBefore` was `.positiveInfinity`, and that is a second
            // defect hiding inside the first. "Earlier" with no bound includes
            // the start of the file, so a recovery could replay the entire
            // healthy region — 5.6s of the 16s test clip. That is more than
            // `healthyProgressToRefundBudget`, so a recovery that fixed
            // nothing refunded the automatic budget, and three-attempts-then-
            // ask-a-person became a loop with no end.
            entry.player.seek(
                to: position,
                toleranceBefore: CMTime(
                    seconds: VideoStallPolicy.recoverySeekToleranceBefore,
                    preferredTimescale: 600
                ),
                toleranceAfter: .zero
            )
        }
        // §4: recovery resumes under the existing rules, it does not invent
        // its own. If this row lost the centre, went off screen or the app
        // left the foreground while the attempt was in flight, it stays quiet.
        if playingID == id, !isInterrupted, !isSuspended, !viewerPaused.contains(id) {
            entry.player.play()
        }
        lastClock[id] = nil
        lastBufferedEnd[id] = nil
        log.info("video: \(id, privacy: .public) rebuilt item (\(reason, privacy: .public)) at \(String(format: "%.2f", position.seconds))s")
    }

    private func clearStall(id: String) {
        stalls[id] = nil
        if bufferingID == id { bufferingID = nil }
        if recoveryOfferedID == id { recoveryOfferedID = nil }
    }

    private func clearAllStalls() {
        guard !stalls.isEmpty || bufferingID != nil || recoveryOfferedID != nil else { return }
        stalls.removeAll()
        bufferingID = nil
        recoveryOfferedID = nil
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
        reachedEnd.remove(id)
        strandedAtFalseEnd.remove(id)
        viewerPaused.remove(id)
        clearStall(id: id)
        lastClock[id] = nil
        lastBufferedEnd[id] = nil
        healthyProgress[id] = nil
        recoveryAttempts[id] = nil
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
        var entry = entry
        entry.player.pause()
        detachItemObservations(from: &entry)
        if let token = entry.timeObserver {
            entry.player.removeTimeObserver(token)
            entry.timeObserver = nil
        }
        entry.player.replaceCurrentItem(with: nil)
    }

    // MARK: - The decision

    private func reconcile() {
        // Every exit from here can change whether anything is playing, and the
        // monitor's whole cost control is that it only runs while something is.
        defer { updateStallMonitor() }
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

        // **A video the person stopped still wins the centre — it just does not
        // play.** It stays the winner on purpose: dropping it from the running
        // would hand the centre to whatever row is second-closest, so pausing
        // the video in front of you would start the one half off the bottom of
        // the screen. Quiet means quiet.
        guard !viewerPaused.contains(winner) else {
            entry.player.pause()
            if playingID == winner { playingID = nil }
            return
        }

        guard playingID != winner else { return }
        // Whatever the app was doing, it is playing video now: the suspended
        // label cannot outlive the thing it describes. Without this an
        // interruption that ends with `.shouldResume` would resume playback and
        // leave every row still calling itself `.suspended`, which would also
        // switch the stall monitor off for the rest of the session.
        isSuspended = false
        reachedEnd.remove(winner)
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
