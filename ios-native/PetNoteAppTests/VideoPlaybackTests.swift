import AVFoundation
import CoreVideo
import Foundation
import Testing

@testable import PetNote

/// Acceptance 5D.1–5D.8.
///
/// Two halves, kept apart on purpose:
///
///   - **the rules** — the visibility threshold, the ceiling, what happens when
///     something leaves the screen. These need a player object, not a picture.
///   - **real media** — a real H.264 file, written by the test itself, played
///     by a real `AVPlayer`. These are what separate "the coordinator decided
///     to play" from "a picture exists", which is a distinction that has
///     already hidden one defect (`playingID` claimed for a video that never
///     played).
///
/// What none of it proves: that the picture reaches the glass, that scrolling
/// stays smooth, or that memory stays flat. The first needs the UI tests next
/// door; the other two need a device and Instruments.
///
/// Serialized because the audio session is one object shared by the whole
/// process — two tests changing its category at once would fail each other's
/// assertions and teach nothing.
@Suite(.serialized)
@MainActor
struct VideoPlaybackTests {
    /// Local, not Cloudinary. The rule tests used three `res.cloudinary.com`
    /// URLs and every `AVPlayer` they made started a real download: the run log
    /// was thousands of `FigFilePlayer signalled err=-12864` lines, and what
    /// the tests were measuring depended on someone else's CDN.
    private func clip() async throws -> URL { try await TestVideoFixture.clip() }

    // MARK: - The visibility rule

    @Test func belowTheThresholdGetsNoPlayerAtAll() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        // 59% visible — just under.
        coordinator.reportVisibility(id: "a", fraction: 0.59, distanceFromCentre: 0)
        #expect(coordinator.player(for: "a", url: url) == nil)
        #expect(coordinator.livePlayerCount == 0)
        #expect(coordinator.playingID == nil)
    }

    @Test func atTheThresholdGetsOne() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.6, distanceFromCentre: 0)
        #expect(coordinator.player(for: "a", url: url) != nil)
        #expect(coordinator.livePlayerCount == 1)
    }

    /// **Regression.** The first video to appear must actually be told to play.
    ///
    /// The view reports visibility before it asks for a player, so on a first
    /// appearance `reconcile` ran with no players at all. It skipped `play()`,
    /// claimed `playingID` anyway, and every later call returned early on
    /// `winner == playingID`. `playingID` was right and nothing ever played.
    ///
    /// So this asserts the player's own state, not the coordinator's belief.
    @Test func theFirstVideoToAppearIsActuallyToldToPlay() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        // Exactly the order a view uses.
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        let player = coordinator.player(for: "a", url: url)

        #expect(player != nil)
        #expect(coordinator.playingID == "a", "the coordinator believes it is playing")
        #expect(
            coordinator.isActuallyPlaying(id: "a"),
            "and the player agrees — timeControlStatus is not .paused"
        )
    }

    /// `playingID` must not be claimed by a video that has no player, because
    /// the claim is what stops the next attempt.
    @Test func aWinnerWithNoPlayerDoesNotClaimPlayingID() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        // Visible enough to win, but never granted a player.
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        #expect(coordinator.playingID == nil, "nothing is playing until something plays")

        // And the claim is available the moment a player exists.
        _ = coordinator.player(for: "a", url: url)
        #expect(coordinator.playingID == "a")
        #expect(coordinator.isActuallyPlaying(id: "a"))
    }

    @Test func theVideoThatLosesTheCentreIsActuallyPaused() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 10)
        _ = coordinator.player(for: "a", url: url)
        #expect(coordinator.isActuallyPlaying(id: "a"))

        coordinator.reportVisibility(id: "b", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "b", url: url)

        #expect(coordinator.isActuallyPlaying(id: "b"))
        #expect(!coordinator.isActuallyPlaying(id: "a"), "the old one really stopped")
    }

    @Test func suspendingActuallyPausesThePlayerNotJustTheBelief() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "a", url: url)
        #expect(coordinator.isActuallyPlaying(id: "a"))

        coordinator.suspendAll(reason: "test")
        #expect(!coordinator.isActuallyPlaying(id: "a"))
        #expect(coordinator.playingID == nil)
    }

    /// 5D.1: among eligible videos, the one nearest the middle plays — and it
    /// is exactly one.
    @Test func onlyTheMostCentredEligibleVideoPlays() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 300)
        coordinator.reportVisibility(id: "b", fraction: 0.8, distanceFromCentre: 40)
        _ = coordinator.player(for: "a", url: url)
        _ = coordinator.player(for: "b", url: url)

        #expect(coordinator.playingID == "b", "nearest the centre wins, not the most visible")
        #expect(!coordinator.isActuallyPlaying(id: "a"))
    }

    @Test func scrollingChangesWhichOnePlays() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 20)
        _ = coordinator.player(for: "a", url: url)
        #expect(coordinator.playingID == "a")

        // "b" scrolls into the middle while "a" slides up.
        coordinator.reportVisibility(id: "b", fraction: 0.9, distanceFromCentre: 10)
        _ = coordinator.player(for: "b", url: url)
        coordinator.reportVisibility(id: "a", fraction: 0.7, distanceFromCentre: 400)

        #expect(coordinator.playingID == "b")
    }

    /// 5D.2: falling below the threshold pauses; leaving entirely releases.
    @Test func leavingTheScreenTearsThePlayerDown() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "a", url: url)
        #expect(coordinator.livePlayerCount == 1)

        coordinator.reportOffscreen(id: "a")
        #expect(coordinator.livePlayerCount == 0, "the decoder is freed, not just paused")
        #expect(coordinator.playingID == nil)
    }

    // MARK: - The ceiling

    /// 5D.3: the limit is a number in the code, and it holds.
    @Test func neverMoreThanTheCeiling() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        for id in ["a", "b", "c"] {
            coordinator.reportVisibility(id: id, fraction: 0.9, distanceFromCentre: 100)
            _ = coordinator.player(for: id, url: url)
        }
        #expect(VideoPlaybackCoordinator.maximumPlayers == 2)
        #expect(coordinator.livePlayerCount <= VideoPlaybackCoordinator.maximumPlayers)
    }

    /// Scrolling past many videos must not accumulate players.
    ///
    /// **This is not the scroll test.** It never lays anything out and never
    /// reuses a row; it only shows the bookkeeping is not obviously wrong.
    /// `VideoPlaybackUITests.testThirtyVideosInARealList` is the one that
    /// answers the question, and the two are not interchangeable.
    @Test func thirtyCallsToTheCoordinatorDoNotAccumulatePlayers() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        for index in 0..<30 {
            let id = "video-\(index)"
            coordinator.reportVisibility(id: id, fraction: 0.9, distanceFromCentre: 0)
            _ = coordinator.player(for: id, url: url)
            // The previous one scrolls away, as it would in a list.
            if index > 0 { coordinator.reportOffscreen(id: "video-\(index - 1)") }
            #expect(
                coordinator.livePlayerCount <= VideoPlaybackCoordinator.maximumPlayers,
                "after \(index + 1) videos there are \(coordinator.livePlayerCount) players"
            )
        }
    }

    /// 5D.7: back to zero.
    @Test func everythingReturnsToZero() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        for id in ["a", "b"] {
            coordinator.reportVisibility(id: id, fraction: 0.9, distanceFromCentre: 50)
            _ = coordinator.player(for: id, url: url)
        }
        #expect(coordinator.livePlayerCount > 0)

        coordinator.releaseAll(reason: "test")
        #expect(coordinator.livePlayerCount == 0)
        #expect(coordinator.playingID == nil)
    }

    /// 5D.6: backgrounding stops playback and does not silently resume.
    @Test func suspendingStopsPlaybackWithoutDestroyingState() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "a", url: url)
        #expect(coordinator.playingID == "a")

        coordinator.suspendAll(reason: "background")
        #expect(coordinator.playingID == nil, "nothing is playing after backgrounding")
        #expect(coordinator.livePlayerCount == 1, "the player is kept, so returning is instant")
    }

    /// Coming back from the background is quiet until the list moves — and
    /// then it plays again. The second half matters: `playingID` was cleared by
    /// the suspend, and if the pause had left it set, the next reconcile would
    /// have returned early and the video would have stayed dead for good.
    @Test func returningFromTheBackgroundIsQuietUntilSomethingMoves() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "a", url: url)
        coordinator.suspendAll(reason: "scenePhase background")
        #expect(!coordinator.isActuallyPlaying(id: "a"))

        // Foreground alone changes nothing.
        #expect(coordinator.playingID == nil)
        // A scroll does.
        coordinator.reportVisibility(id: "a", fraction: 0.85, distanceFromCentre: 5)
        #expect(coordinator.playingID == "a")
        #expect(coordinator.isActuallyPlaying(id: "a"))
    }

    // MARK: - Real media

    /// The four claims, separated, because the first three can all be true
    /// while there is nothing to look at:
    ///
    ///   1. the coordinator chose this video;
    ///   2. `play()` was really sent (the player's own `timeControlStatus`);
    ///   3. the clock moved (a boundary observer at 0.3s, not a belief);
    ///   4. the decoder knows how big the picture is (`presentationSize`).
    ///
    /// The fourth is the closest this level can get to "there is a picture".
    /// It proves a video track was opened and decoded far enough to have
    /// dimensions. It does **not** prove anything reached the screen — that is
    /// the screenshot test in `VideoPlaybackUITests`.
    @Test func aRealVideoIsChosenPlayedAdvancedAndHasAPicture() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        let player = try #require(coordinator.player(for: "a", url: url))

        // 1 — the decision.
        #expect(coordinator.playingID == "a")
        // 2 — play() was sent.
        #expect(player.timeControlStatus != .paused)

        // 4 — a picture size, which arrives when the track is really open.
        try await waitUntil("the decoder to report a picture size", describe: {
            "size=\(coordinator.presentationSizes["a"] ?? .zero)"
        }) { coordinator.hasPicture(for: "a") }
        #expect(coordinator.presentationSizes["a"] == TestVideoFixture.size)

        // 3 — the clock crossed a real boundary, reported by AVFoundation.
        try await waitUntil("the clock to pass \(VideoPlaybackCoordinator.progressMarks[0])s", describe: {
            "t=\(coordinator.currentTime(of: "a") ?? -1) status=\(player.timeControlStatus.rawValue)"
        }) { coordinator.advanced.contains("a") }
        let time = try #require(coordinator.currentTime(of: "a"))
        #expect(time >= VideoPlaybackCoordinator.progressMarks[0])
        #expect(player.timeControlStatus == .playing, "not merely waiting to play")
    }

    /// Frames, not status flags.
    ///
    /// An `AVPlayerItemVideoOutput` hands over the pixel buffers the decoder
    /// produced. This checks they are real pictures and that they *change*:
    /// the fixture is red for its first second and blue for its third, so a
    /// still frame, a black frame or a frozen first frame all fail here.
    ///
    /// Still not proof that anything was drawn on screen. It is proof that
    /// there was something to draw.
    @Test func theDecoderProducesRealFramesAndTheyChange() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        let player = try #require(coordinator.player(for: "a", url: url))
        let item = try #require(player.currentItem)

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)

        var samples: [(second: Int, colour: Colour)] = []
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, samples.count < 40 {
            let time = player.currentTime()
            if output.hasNewPixelBuffer(forItemTime: time),
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                samples.append((Int(time.seconds), Colour(averageOf: buffer)))
            }
            // Enough to land in more than one colour block without sampling
            // every frame.
            try await Task.sleep(for: .milliseconds(80))
            if samples.contains(where: { $0.second == 0 }),
               samples.contains(where: { $0.second >= 2 }) { break }
        }

        let first = try #require(samples.first(where: { $0.second == 0 }), "no frame from the first second")
        let later = try #require(samples.first(where: { $0.second >= 2 }), "no frame from the third second")

        let expectedFirst = TestVideoFixture.colour(atSecond: 0)
        let expectedLater = TestVideoFixture.colour(atSecond: 2)
        #expect(
            first.colour.isCloseTo(expectedFirst),
            "second 0 should be the red block, measured \(first.colour)"
        )
        #expect(
            later.colour.isCloseTo(expectedLater),
            "second 2 should be the blue block, measured \(later.colour)"
        )
        #expect(!first.colour.isCloseTo(expectedLater), "the picture must actually change")
    }

    // MARK: - Rows being replaced

    /// **A row that has been replaced cannot close the row that replaced it.**
    ///
    /// `onDisappear` is not ordered against the next view's first visibility
    /// report. Measured coming back to the feed from a post: the rebuilt row
    /// reported itself visible, was given a player and played for half a
    /// second, and then the row it replaced ran its `onDisappear`. Keyed by id
    /// alone that tore down a player that was on screen and playing — and
    /// since nothing moves afterwards, no further visibility report ever
    /// arrived and every video in the feed stayed dead until it was scrolled.
    @Test func aDisappearFromAReplacedRowDoesNotCloseTheRowThatReplacedIt() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        let replaced = UUID()
        let live = UUID()

        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0, reporter: replaced)
        _ = coordinator.player(for: "a", url: url)
        // The row is rebuilt; a different view now speaks for the same id.
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0, reporter: live)
        _ = coordinator.player(for: "a", url: url)
        try await waitUntil("playback to advance") { coordinator.advanced.contains("a") }

        // ...and only now does the view it replaced get round to disappearing.
        coordinator.reportOffscreen(id: "a", reporter: replaced, reason: "onDisappear")

        #expect(coordinator.livePlayerCount == 1, "a replaced row tore down the live one")
        #expect(coordinator.playingID == "a")
        #expect(coordinator.isActuallyPlaying(id: "a"))

        // And the row that really is on screen can still close itself, or the
        // fix would just be a leak.
        coordinator.reportOffscreen(id: "a", reporter: live, reason: "onDisappear")
        #expect(coordinator.livePlayerCount == 0)
        #expect(coordinator.playingID == nil)
    }

    // MARK: - 2. Playing all the way to the end

    /// **The clip reaches its own end, and that is not a failure.**
    ///
    /// Kept apart from looping deliberately, because this is the exact place a
    /// previous round drew the wrong conclusion: a row whose picture stopped
    /// changing was reported as broken playback, and what had really happened
    /// was that four seconds of video had finished and the player was holding
    /// its last frame. A screenshot cannot tell "finished" from "stalled" from
    /// "the decoder died" — all three are a still picture — so nothing here
    /// asks it to. The evidence is the clock getting there under its own
    /// power, the item still being `readyToPlay` when it arrives, and
    /// AVFoundation's own end-of-clip notification.
    @Test func aClipPlaysAllTheWayToItsEndAndThatIsNotAFailure() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        let player = try #require(coordinator.player(for: "a", url: url))
        let item = try #require(player.currentItem)

        let finished = Flag()
        let observer = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { _ in finished.raise() }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Under its own power: the furthest point reached, so a loop that
        // wraps while this is waiting cannot make the condition go backwards.
        var furthest = 0.0
        try await waitUntil("the clock to reach the clip's last half second", timeout: 40, describe: {
            "furthest=\(furthest) t=\(coordinator.currentTime(of: "a") ?? -1) "
                + "status=\(player.timeControlStatus.rawValue) item=\(item.status.rawValue)"
        }) {
            furthest = max(furthest, coordinator.currentTime(of: "a") ?? 0)
            return furthest >= TestVideoFixture.duration - 0.5
        }

        try await waitUntil("the end-of-clip notification to arrive", timeout: 20, describe: {
            "furthest=\(furthest)"
        }) { finished.isRaised }

        // Finished, not broken — the two readings a still picture allows.
        #expect(item.status == .readyToPlay, "the item did not survive to its own end")
        #expect(coordinator.failure(for: "a") == nil, "reaching the end was recorded as a failure")
        #expect(coordinator.livePlayerCount == 1, "the player was torn down when the clip ended")
    }

    // MARK: - 3. The seam, end back to beginning

    /// **The join itself: the last frame is followed by the first one, playing.**
    ///
    /// Separate from the test above because "it got to the end" and "it carried
    /// on from the start" fail for different reasons and one can hold without
    /// the other. Before the loop existed, the clock stopped at 4.00,
    /// `timeControlStatus` went to `paused`, and the last decoded frame stayed
    /// on the glass indefinitely: a row with no moving picture and no control
    /// to restart it, which is not "finished", it is stuck. Clips in this feed
    /// are seconds long, so that state is where a row would spend most of its
    /// life.
    @Test func theSeamFromTheEndBackToTheBeginningKeepsPlaying() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        let player = try #require(coordinator.player(for: "a", url: url))
        let item = try #require(player.currentItem)

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)

        // All the way to the last second...
        try await waitUntil("the clip to reach its final second", timeout: 30, describe: {
            "t=\(coordinator.currentTime(of: "a") ?? -1)"
        }) { (coordinator.currentTime(of: "a") ?? 0) >= TestVideoFixture.duration - 0.5 }

        // ...and round again. A clock that is merely still would sit at 4.00
        // forever, which is exactly what it did before.
        try await waitUntil("the clock to wrap back to the start", timeout: 15, describe: {
            "t=\(coordinator.currentTime(of: "a") ?? -1) status=\(player.timeControlStatus.rawValue)"
        }) { (coordinator.currentTime(of: "a") ?? .greatestFiniteMagnitude) < 1.0 }

        #expect(player.timeControlStatus == .playing, "it wrapped but stopped playing")
        #expect(coordinator.playingID == "a")

        // And the picture really is the first block again, not a still frame
        // left over from the end.
        var replayed: Colour?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, replayed == nil {
            let now = player.currentTime()
            if now.seconds < 1.0,
               output.hasNewPixelBuffer(forItemTime: now),
               let buffer = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) {
                replayed = Colour(averageOf: buffer)
            }
            try await Task.sleep(for: .milliseconds(60))
        }
        let frame = try #require(replayed, "no frame decoded after the clip wrapped")
        #expect(
            frame.isCloseTo(TestVideoFixture.colour(atSecond: 0)),
            "after wrapping, the first second should be the red block again, measured \(frame)"
        )

        // Last: wrapped *and still running*. A `seek(to: .zero)` with no
        // `play()` after it also puts the clock under 1.0 and shows the red
        // block — and is not looping, it is a tidier way of being stuck,
        // holding the first frame forever instead of the last. Only the clock
        // moving on past the seam tells the two apart.
        try await waitUntil("the clock to carry on past the seam", timeout: 20, describe: {
            "t=\(coordinator.currentTime(of: "a") ?? -1) status=\(player.timeControlStatus.rawValue)"
        }) { (coordinator.currentTime(of: "a") ?? 0) > 1.2 }
    }

    /// **Looping is not a property of the first video.**
    ///
    /// The end-of-clip observer is attached to one player's one item, so "the
    /// first row loops" says nothing whatever about the second: scrolling
    /// tears players down and builds new ones, and an observer that only ever
    /// reached the first item would leave every later row frozen on its last
    /// frame. That is the same symptom one row further down — and the suite
    /// had no test that would have noticed.
    @Test func everyVideoThatWinsTheCentreLoopsNotJustTheFirst() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()

        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "a", url: url)
        try await waitUntil("the first video to take the screen") { coordinator.playingID == "a" }
        try await goRoundOnce(coordinator, id: "a")

        // The list moves: "b" is nearest the middle now and "a" is gone
        // entirely, which is what a row does when it is scrolled past.
        coordinator.reportVisibility(id: "b", fraction: 0.95, distanceFromCentre: 0)
        _ = coordinator.player(for: "b", url: url)
        coordinator.reportOffscreen(id: "a", reason: "scrolled past")
        try await waitUntil("the second video to take the screen", describe: {
            "playing=\(coordinator.playingID ?? "none") live=\(coordinator.livePlayerIDs)"
        }) { coordinator.playingID == "b" }

        try await goRoundOnce(coordinator, id: "b")
        #expect(coordinator.playingID == "b")
        #expect(coordinator.isActuallyPlaying(id: "b"))
    }

    /// Plays `id` to its end, over the seam, and out the other side — saying
    /// what it last saw rather than failing with a bare timeout.
    private func goRoundOnce(_ coordinator: VideoPlaybackCoordinator, id: String) async throws {
        var furthest = 0.0
        try await waitUntil("\(id) to reach its last half second", timeout: 40, describe: {
            "furthest=\(furthest) t=\(coordinator.currentTime(of: id) ?? -1) "
                + "playing=\(coordinator.playingID ?? "none")"
        }) {
            furthest = max(furthest, coordinator.currentTime(of: id) ?? 0)
            return furthest >= TestVideoFixture.duration - 0.5
        }
        try await waitUntil("\(id) to wrap back to the start", timeout: 20, describe: {
            "t=\(coordinator.currentTime(of: id) ?? -1)"
        }) { (coordinator.currentTime(of: id) ?? .greatestFiniteMagnitude) < 1.0 }
        try await waitUntil("\(id) to carry on past the seam", timeout: 20, describe: {
            "t=\(coordinator.currentTime(of: id) ?? -1) playing=\(coordinator.playingID ?? "none")"
        }) { (coordinator.currentTime(of: id) ?? 0) > 1.2 }
        #expect(coordinator.isActuallyPlaying(id: id), "\(id) wrapped and then stopped")
    }

    /// Looping belongs to the chosen video only.
    ///
    /// The end of a clip must not be a way to take the screen back. A row that
    /// has lost the centre is paused, and if its clip happened to run out at
    /// the moment it lost it, the naive fix — "on end, play again" — would
    /// restart it behind the row that legitimately won. The notification is
    /// posted here by hand, which is the same thing AVFoundation does and the
    /// only way to put a losing row at its end on purpose.
    @Test func aVideoThatIsNoLongerTheChosenOneDoesNotRestartItself() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        let first = try #require(coordinator.player(for: "a", url: url))
        let firstItem = try #require(first.currentItem)
        try await waitUntil("the first video to be playing") { coordinator.advanced.contains("a") }

        // The list moves: "b" is now nearest the middle.
        coordinator.reportVisibility(id: "b", fraction: 0.9, distanceFromCentre: 0)
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 400)
        _ = coordinator.player(for: "b", url: url)
        try await waitUntil("the second video to take over") { coordinator.playingID == "b" }
        #expect(!coordinator.isActuallyPlaying(id: "a"), "the one that lost the centre is paused")

        NotificationCenter.default.post(
            name: AVPlayerItem.didPlayToEndTimeNotification, object: firstItem
        )
        try await Task.sleep(for: .milliseconds(400))

        #expect(coordinator.playingID == "b", "a clip running out stole the screen back")
        #expect(!coordinator.isActuallyPlaying(id: "a"), "a row that is not chosen started playing again")
    }

    /// Backgrounding wins over the end of a clip.
    ///
    /// `suspendAll` is what §5D.6 rests on, and it would be worth very little
    /// if a clip that ran out a moment later could undo it silently.
    @Test func aClipRunningOutWhileSuspendedDoesNotStartPlaybackAgain() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        let player = try #require(coordinator.player(for: "a", url: url))
        let item = try #require(player.currentItem)
        try await waitUntil("playback to advance") { coordinator.advanced.contains("a") }

        coordinator.suspendAll(reason: "test background")
        NotificationCenter.default.post(
            name: AVPlayerItem.didPlayToEndTimeNotification, object: item
        )
        try await Task.sleep(for: .milliseconds(400))

        #expect(coordinator.playingID == nil)
        #expect(!coordinator.isActuallyPlaying(id: "a"), "the app is in the background and a video is playing")
    }

    // MARK: - 4. Leaving the feed and coming back

    /// **Coming back has to restart the decision, not merely allow playback.**
    ///
    /// Opening a post releases every player *and* empties what the coordinator
    /// knows about the screen — `SignedInView` calls `releaseAll` on the way
    /// out and again on the way back. Everything after that depends on rows
    /// speaking up again: with an empty visibility map nothing is eligible, so
    /// nothing plays, and a row that has not moved produces no `onChange`, so
    /// on its own nothing ever would. (`VideoPlayerView.onAppear` is what now
    /// guarantees the rebuilt rows speak.)
    ///
    /// "It plays again" is the weaker claim and would pass on a coordinator
    /// that simply resumed whatever it had been doing. The claim made here is
    /// that the *choice* is made afresh: after coming back, the video nearest
    /// the middle is a different one, and it is the one that plays.
    @Test func comingBackFromAPostRestartsTheDecisionAndNotJustPlayback() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        let firstVisit = UUID()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0, reporter: firstVisit)
        _ = coordinator.player(for: "a", url: url)
        try await waitUntil("the feed to be playing before we leave") { coordinator.advanced.contains("a") }

        // Out to the post and back, both calls, in the order they really happen.
        coordinator.releaseAll(reason: "navigated away")
        #expect(coordinator.livePlayerCount == 0, "a player survived navigating away")
        #expect(coordinator.playingID == nil)
        coordinator.releaseAll(reason: "returned to feed")

        // The rebuilt rows report themselves. "b" is the one in the middle now.
        let secondVisit = UUID()
        let neighbour = UUID()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 300, reporter: secondVisit)
        coordinator.reportVisibility(id: "b", fraction: 0.9, distanceFromCentre: 10, reporter: neighbour)
        _ = coordinator.player(for: "a", url: url)
        _ = coordinator.player(for: "b", url: url)

        try await waitUntil("the decision to be taken again", timeout: 20, describe: {
            "playing=\(coordinator.playingID ?? "none") live=\(coordinator.livePlayerIDs)"
        }) { coordinator.playingID == "b" }
        #expect(coordinator.isActuallyPlaying(id: "b"))
        #expect(
            !coordinator.isActuallyPlaying(id: "a"),
            "the video that was playing before took the screen back instead of the decision being made again"
        )

        // And it is still free to move afterwards, so nothing has latched.
        coordinator.reportVisibility(id: "a", fraction: 0.95, distanceFromCentre: 5, reporter: secondVisit)
        coordinator.reportVisibility(id: "b", fraction: 0.7, distanceFromCentre: 400, reporter: neighbour)
        try await waitUntil("a later scroll to change the choice", timeout: 20, describe: {
            "playing=\(coordinator.playingID ?? "none")"
        }) { coordinator.playingID == "a" }
        #expect(!coordinator.isActuallyPlaying(id: "b"))
    }

    // MARK: - 5. Failure and retry (5D.8)

    @Test func aMissingFileBecomesARetryableFailure() async throws {
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "broken", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "broken", url: TestVideoFixture.missingFileURL())

        try await waitUntil("the failure to surface", describe: {
            "failures=\(coordinator.failures)"
        }) { coordinator.failure(for: "broken") != nil }

        #expect(coordinator.failure(for: "broken") == "Video failed to load. Tap to retry.")
        #expect(coordinator.livePlayerCount == 0, "a broken video must not keep a decoder")
        #expect(coordinator.playingID == nil)
    }

    /// The other kind of broken: a file that exists and is not a movie. An
    /// existence check would call this one fine.
    @Test func bytesThatAreNotAMovieAlsoFail() async throws {
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "junk", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "junk", url: try TestVideoFixture.garbageFileURL())

        try await waitUntil("the failure to surface") { coordinator.failure(for: "junk") != nil }
        #expect(coordinator.livePlayerCount == 0)
    }

    /// **Regression.** A broken video used to be handed a new player on every
    /// scroll event, because the failure lived in the view and the view asks
    /// for a player whenever its visibility changes. Two slots, one of them
    /// permanently wasted on a 404.
    @Test func aFailedVideoStopsTakingPlayerSlots() async throws {
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "broken", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "broken", url: TestVideoFixture.missingFileURL())
        try await waitUntil("the failure to surface") { coordinator.failure(for: "broken") != nil }

        // Ten scroll events over the broken row.
        for step in 0..<10 {
            coordinator.reportVisibility(id: "broken", fraction: 0.9, distanceFromCentre: CGFloat(step))
            #expect(coordinator.player(for: "broken", url: TestVideoFixture.missingFileURL()) == nil)
        }
        #expect(coordinator.livePlayerCount == 0)
    }

    /// And it must not block the working video next to it: a failed video that
    /// still won the centre would leave the feed silent and still.
    @Test func aFailedVideoDoesNotBlockTheOneBesideIt() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        // Broken one is dead centre; the good one is further away.
        coordinator.reportVisibility(id: "broken", fraction: 0.95, distanceFromCentre: 0)
        _ = coordinator.player(for: "broken", url: TestVideoFixture.missingFileURL())
        coordinator.reportVisibility(id: "good", fraction: 0.8, distanceFromCentre: 120)
        _ = coordinator.player(for: "good", url: url)

        try await waitUntil("the broken one to fail") { coordinator.failure(for: "broken") != nil }
        try await waitUntil("the good one to take over", describe: {
            "playing=\(coordinator.playingID ?? "none")"
        }) { coordinator.playingID == "good" }
        #expect(coordinator.isActuallyPlaying(id: "good"))
    }

    /// Retry has to rebuild, not increment.
    ///
    /// The old one bumped a counter that nothing read, and the row then sat on
    /// its poster until it was scrolled. Here the file genuinely appears
    /// between the failure and the retry — which is what "the network came
    /// back" looks like from the client — and the video has to end up playing.
    @Test func retryRebuildsThePlayerAndRecovers() async throws {
        let path = TestVideoFixture.temporaryURL(named: "a2-appears-later")
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "late", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "late", url: path)
        try await waitUntil("the first failure") { coordinator.failure(for: "late") != nil }

        try await TestVideoFixture.writeClip(to: path)
        coordinator.retry(id: "late")

        #expect(coordinator.failure(for: "late") == nil, "the failure is cleared by the tap itself")
        #expect(coordinator.livePlayerCount == 1, "and a new player exists without waiting for a scroll")
        try await waitUntil("the retried video to show a picture", describe: {
            "failure=\(coordinator.failure(for: "late") ?? "none") size=\(coordinator.presentationSizes["late"] ?? .zero)"
        }) { coordinator.hasPicture(for: "late") }
        #expect(coordinator.playingID == "late")
    }

    // MARK: - Resources (5D.7, as far as a simulator can go)

    /// Not "the count went to zero" — the object is gone.
    ///
    /// The count was the old evidence and it was not evidence: the view held
    /// its own reference to every player it had ever been given, so a torn-down
    /// player stayed alive inside a row that was still on screen while
    /// `livePlayerCount` read zero.
    @Test func tearingDownDeallocatesThePlayerItself() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        weak var released: AVPlayer?
        weak var releasedItem: AVPlayerItem?

        autoreleasepool {
            coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
            let player = coordinator.player(for: "a", url: url)
            released = player
            releasedItem = player?.currentItem
        }
        #expect(released != nil)

        coordinator.reportOffscreen(id: "a")
        try await waitUntil("the player to deallocate") { released == nil }
        try await waitUntil("the item to deallocate") { releasedItem == nil }
        #expect(coordinator.livePlayerCount == 0)
    }

    /// The same, after real playback — which is when the observations exist.
    ///
    /// A boundary time observer that is still registered when its player
    /// deallocates is not a leak, it is an AVFoundation assertion failure that
    /// takes the process down. So this test passing *is* the evidence that the
    /// token was removed; there is nothing to assert about it afterwards.
    @Test func tearingDownAfterPlaybackReleasesTheObserversToo() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        weak var released: AVPlayer?

        autoreleasepool {
            coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
            released = coordinator.player(for: "a", url: url)
        }
        try await waitUntil("playback to advance") { coordinator.advanced.contains("a") }

        coordinator.reportOffscreen(id: "a")
        try await waitUntil("the played player to deallocate") { released == nil }
        #expect(coordinator.presentationSizes["a"] == nil, "and its picture state went with it")
        #expect(!coordinator.advanced.contains("a"))
    }

    @Test func releaseAllDeallocatesEveryPlayer() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        weak var first: AVPlayer?
        weak var second: AVPlayer?

        autoreleasepool {
            coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 10)
            first = coordinator.player(for: "a", url: url)
            coordinator.reportVisibility(id: "b", fraction: 0.9, distanceFromCentre: 200)
            second = coordinator.player(for: "b", url: url)
        }
        #expect(coordinator.livePlayerCount == 2)

        coordinator.releaseAll(reason: "test")
        try await waitUntil("both players to deallocate") { first == nil && second == nil }
    }

    // MARK: - Audio (5D.4)

    /// **Muted by default — on the player, while it is playing, and in the session.**
    ///
    /// Three different things, and only the first is cheap to check. The
    /// coordinator's `isMuted` is a belief; `AVPlayer.isMuted` is what the
    /// audio unit is actually told; the session category is what decides
    /// whether this app is allowed to interrupt anything at all. The old test
    /// read the first two at the moment the player was built, which a player
    /// that unmuted itself on its first `play()` would pass — so this one
    /// waits until a clip is genuinely running and reads them then.
    @Test func mutedByDefault() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        #expect(coordinator.isMuted)
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        let player = try #require(coordinator.player(for: "a", url: url))
        #expect(player.isMuted, "the player was built with sound on")

        try await waitUntil("the clip to be genuinely playing", describe: {
            "status=\(player.timeControlStatus.rawValue) t=\(coordinator.currentTime(of: "a") ?? -1)"
        }) { coordinator.advanced.contains("a") && player.timeControlStatus == .playing }

        // The state that matters: silent at the moment sound could come out.
        #expect(player.isMuted, "the player unmuted itself once it started")
        #expect(coordinator.isMuted)

        // And a session that plays alongside other audio rather than taking it
        // over. Muting the player alone does not achieve this — a muted
        // AVPlayer still activates the session, and the default category stops
        // whatever the person was listening to.
        try await waitUntil("the session to be ambient", describe: {
            "category=\(AVAudioSession.sharedInstance().category.rawValue)"
        }) { AVAudioSession.sharedInstance().category == .ambient }

        // A video that scrolls in later inherits the silence rather than
        // starting from the framework's default.
        coordinator.reportVisibility(id: "b", fraction: 0.7, distanceFromCentre: 300)
        let second = try #require(coordinator.player(for: "b", url: url))
        #expect(second.isMuted, "a video that arrived later came in with sound")
    }

    /// **Muting the player is not enough**, and this is the test that says so.
    ///
    /// A muted `AVPlayer` still activates the process audio session when it
    /// starts, and the default category is `.soloAmbient`, which stops whatever
    /// the person was listening to. The category is the only thing that
    /// prevents it, and nothing used to set it until someone tapped unmute.
    ///
    /// What this proves: the category is `.ambient` before the first frame.
    /// What it cannot prove on a simulator: that Music really keeps playing.
    /// That needs a device with something playing, and is marked unverified.
    @Test func theSessionIsAmbientBeforeTheFirstFrameIsShown() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "a", url: url)

        try await waitUntil("the session category to become ambient", describe: {
            "category=\(AVAudioSession.sharedInstance().category.rawValue)"
        }) { AVAudioSession.sharedInstance().category == .ambient }
    }

    @Test func unmutingClaimsThePlaybackCategory() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "a", url: url)
        coordinator.toggleMute()
        #expect(!coordinator.isMuted)

        try await waitUntil("the session category to become playback", describe: {
            "category=\(AVAudioSession.sharedInstance().category.rawValue)"
        }) { AVAudioSession.sharedInstance().category == .playback }

        // Put it back, so the next test starts where it expects to.
        coordinator.toggleMute()
        try await waitUntil("the session category to go back to ambient") {
            AVAudioSession.sharedInstance().category == .ambient
        }
    }

    @Test func unmutingAppliesToEveryPlayer() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        for id in ["a", "b"] {
            coordinator.reportVisibility(id: id, fraction: 0.9, distanceFromCentre: 50)
            _ = coordinator.player(for: id, url: url)
        }
        coordinator.toggleMute()
        #expect(!coordinator.isMuted)
        // A second video scrolling in after unmuting inherits the choice.
        coordinator.reportVisibility(id: "c", fraction: 0.95, distanceFromCentre: 5)
        coordinator.reportOffscreen(id: "a")
        let third = coordinator.player(for: "c", url: url)
        #expect(third?.isMuted == false)

        coordinator.toggleMute()
        try await waitUntil("the session category to go back to ambient") {
            AVAudioSession.sharedInstance().category == .ambient
        }
    }

    // MARK: - Interruptions (5D.4, the half nobody had written)

    @Test func anInterruptionStopsPlayback() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "a", url: url)
        #expect(coordinator.isActuallyPlaying(id: "a"))

        coordinator.handleInterruption(type: .began, options: [])
        #expect(coordinator.isInterrupted)
        #expect(!coordinator.isActuallyPlaying(id: "a"))
        #expect(coordinator.playingID == nil)
    }

    /// Scrolling during a phone call must not start a video behind it.
    @Test func scrollingDuringAnInterruptionStaysQuiet() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "a", url: url)
        coordinator.handleInterruption(type: .began, options: [])

        coordinator.reportVisibility(id: "a", fraction: 0.95, distanceFromCentre: 2)
        #expect(coordinator.playingID == nil)
        #expect(!coordinator.isActuallyPlaying(id: "a"))
    }

    /// **The defect this whole section exists for.** The system pauses the
    /// player during an interruption without telling the coordinator, so
    /// `playingID` stayed set; the next reconcile saw `winner == playingID`
    /// and returned early, and the video never played again for the rest of
    /// the session. Ending the interruption has to put it back.
    @Test func whenTheSystemSaysResumeItPlaysAgain() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "a", url: url)
        coordinator.handleInterruption(type: .began, options: [])
        #expect(!coordinator.isActuallyPlaying(id: "a"))

        coordinator.handleInterruption(type: .ended, options: .shouldResume)
        #expect(!coordinator.isInterrupted)
        #expect(coordinator.playingID == "a")
        #expect(coordinator.isActuallyPlaying(id: "a"))
    }

    /// And when it says otherwise, it stays quiet — but is not stuck: the next
    /// scroll starts it, which is the difference between "paused" and "dead".
    @Test func whenTheSystemDoesNotSayResumeItStaysQuietButNotStuck() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "a", url: url)
        coordinator.handleInterruption(type: .began, options: [])
        coordinator.handleInterruption(type: .ended, options: [])

        #expect(coordinator.playingID == nil, "silence until something asks")
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 1)
        #expect(coordinator.playingID == "a", "and not stuck")
    }

    /// The handler above is only worth anything if it is actually connected to
    /// the notification the system posts.
    @Test func theInterruptionNotificationIsReallyWiredUp() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "a", url: url)

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ]
        )
        try await waitUntil("the coordinator to notice the interruption", timeout: 5) {
            coordinator.isInterrupted
        }
        #expect(!coordinator.isActuallyPlaying(id: "a"))

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ]
        )
        try await waitUntil("playback to come back", timeout: 5) { coordinator.playingID == "a" }
    }
}

// MARK: - A yes/no a notification can raise

/// Raised from a notification block, read from the test.
///
/// A plain `var` will not do: the block runs on the main *queue*, which Swift
/// concurrency has no way to know is the main *actor*, and the compiler is
/// right to refuse. Locked rather than actor-isolated so the read side stays a
/// plain expression inside `waitUntil`.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func raise() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    var isRaised: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

// MARK: - Reading a frame

/// The average colour of a decoded frame, used to tell one second of the
/// fixture from another.
struct Colour: CustomStringConvertible {
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat

    init(averageOf buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            r = 0; g = 0; b = 0
            return
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var totals = (b: 0, g: 0, r: 0)
        var counted = 0
        // Every eighth pixel: enough for a flat colour block, cheap enough to
        // do while a video is playing.
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let pixel = y * rowBytes + x * 4
                totals.b += Int(bytes[pixel])
                totals.g += Int(bytes[pixel + 1])
                totals.r += Int(bytes[pixel + 2])
                counted += 1
            }
        }
        let divisor = CGFloat(max(counted, 1)) * 255
        r = CGFloat(totals.r) / divisor
        g = CGFloat(totals.g) / divisor
        b = CGFloat(totals.b) / divisor
    }

    /// Generous: H.264 stores 4:2:0 YUV, and a 20px white bar crosses every
    /// frame on purpose, so the average never lands exactly on the source
    /// colour. The blocks are far enough apart that this still tells them
    /// apart.
    func isCloseTo(_ other: (r: CGFloat, g: CGFloat, b: CGFloat), tolerance: CGFloat = 0.22) -> Bool {
        abs(r - other.r) < tolerance && abs(g - other.g) < tolerance && abs(b - other.b) < tolerance
    }

    var description: String {
        String(format: "(r %.2f g %.2f b %.2f)", r, g, b)
    }
}
