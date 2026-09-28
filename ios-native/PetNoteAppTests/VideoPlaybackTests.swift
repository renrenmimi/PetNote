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

    /// The dependency the stream-break tests need, checked where it is required.
    ///
    /// Not `.enabled(if:)` — that is the mechanism being guarded against. This
    /// one runs everywhere and only has an opinion where the environment says
    /// the server is mandatory.
    /// **The cross-talk, reproduced, and then shown not to happen.**
    ///
    /// The root cause claimed for `automaticRecoveryIsBoundedAndThenOffersAWayOut`
    /// was that the server's switches were one dict for the whole process. Three
    /// passing runs do not establish that — they are consistent with the cause
    /// being something else that happened to stop. This is the causal part: the
    /// shared namespace is made to cross-talk on demand, and the per-session one
    /// is put through the identical interleaving and does not.
    ///
    /// Bytes rather than playback, because the question is about server state
    /// and an `AVPlayer` in the middle would only add ways to be wrong.
    @Test(.enabled(if: MediaServer.isAnswering))
    func sharedStateCrossTalksAndSeparateSessionsDoNot() async throws {
        // **Ask for the last kilobyte, not for the whole file.**
        //
        // The cut response declares the whole length and then stops sending
        // part-way — that is how it simulates a stream dying mid-transfer, and
        // `URLSession` correctly reports the short read as `-1005 "The network
        // connection was lost"`. So measuring the body size with URLSession
        // cannot work against the very file this test is about.
        //
        // The last kilobyte is past the cut by a wide margin: the fixture puts
        // `moov` at the front, so the tail is media data, and the cut falls at
        // 35% of it. A cut stream cannot serve it; a mended one serves it
        // whole.
        //
        // **Where "the last kilobyte" starts is asked, never assumed.** This
        // used to be the literal `bytes=60239-61262`, which is the tail of the
        // `a2-long.mp4` rendered on one Mac (61,263 bytes). CI renders its own
        // with `a2-make-test-media.swift` on a different OS and encoder and got
        // 60,164 bytes, so the literal range started 75 bytes past the end of
        // the file. The fixture answered that with an empty body whether the
        // stream was cut or mended (`206-index 0 bytes` and `206 0 bytes` in
        // run 35755470453's server log), both readings came out `false`, and
        // the test reported cross-talk that had nothing to do with sessions.
        // So the length comes from the fixture's own `Content-Range` in answer
        // to `bytes=0-0`, and the tail is computed from it.
        //
        // **The cut case does not fail, it goes silent — so the timeout is the
        // measurement.** That is usually a smell and here it is the fixture's
        // designed behaviour: a range entirely past the cut gets honest headers
        // (`206`, the requested `Content-Range`, `Content-Length: 1024`) and
        // then nothing, with the socket held open. There is no error to catch;
        // silence is the whole signal. Everything *else* — a 404, a 416, a
        // body of the wrong size, a connection that drops — is neither
        // "served" nor "silent", and is recorded as a failure of the fixture
        // rather than being counted as a cut.
        //
        // Five seconds because the mended case is a 1 KB range off a loopback
        // server and answers in milliseconds — a hundredfold margin — while
        // fifteen made each cut probe cost fifteen seconds for no extra
        // certainty.
        //
        // Verified against the running fixture before being relied on:
        //
        //   bytes=0-0, cut or mended: 206, Content-Range bytes 0-0/<length>
        //   tail, mended: 206, 1024 bytes, byte-identical to the file's last
        //                 1024 bytes
        //   tail, cut:    206 and the same headers, then no body until the
        //                 client gives up
        //   a range starting past the end: 416 (it used to be an empty 206)
        //   absent path:  404
        //
        // **This checks the fixture, not the app.** That a cut stream stops
        // serving says nothing about whether playback notices, recovers, or
        // tells anyone — `automaticRecoveryIsBoundedAndThenOffersAWayOut` and
        // its siblings are where that is asserted.
        func servesPastTheCut(_ url: URL) async throws -> Bool {
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }

            var lengthProbe = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
            lengthProbe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            lengthProbe.timeoutInterval = 5
            let (_, lengthResponse) = try await session.data(for: lengthProbe)
            let lengthAnswer = try #require(lengthResponse as? HTTPURLResponse)
            let contentRange = lengthAnswer.value(forHTTPHeaderField: "Content-Range") ?? ""
            try #require(
                lengthAnswer.statusCode == 206,
                "bytes=0-0 of \(url) answered \(lengthAnswer.statusCode), so there is no length to take the tail of"
            )
            let length = try #require(
                contentRange.split(separator: "/").last.flatMap { Int($0) },
                "bytes=0-0 of \(url) came back without a usable Content-Range: '\(contentRange)'"
            )
            try #require(length > 1024, "\(url) is \(length) bytes, too short to have a tail past the cut")

            var tail = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
            tail.setValue("bytes=\(length - 1024)-\(length - 1)", forHTTPHeaderField: "Range")
            tail.timeoutInterval = 5
            do {
                let (data, response) = try await session.data(for: tail)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                try #require(
                    status == 206 && data.count == 1024,
                    "the tail of \(url) answered \(status) with \(data.count) bytes — neither served nor silent"
                )
                return true
            } catch let error as URLError where error.code == .timedOut {
                return false
            }
        }

        // --- the old shape: one namespace, two actors, interleaved on purpose
        _ = await MediaServer.reach("/a2-cut")
        let sharedWhileCut = try await servesPastTheCut(MediaServer.url("/a2-cutoff.mp4"))
        _ = await MediaServer.reach("/a2-mend")          // "another test" mends
        let sharedAfterSomeoneElseMended = try await servesPastTheCut(MediaServer.url("/a2-cutoff.mp4"))

        print("MEASURED shared namespace: servesPastTheCut \(sharedWhileCut) "
              + "then after another actor mended \(sharedAfterSomeoneElseMended)")
        #expect(
            sharedWhileCut == false && sharedAfterSomeoneElseMended == true,
            """
            The shared namespace did not cross-talk, so this test is not \
            reproducing what it claims to reproduce and the comparison below \
            proves nothing.
            """
        )

        // --- the new shape: the identical interleaving, separate sessions
        let mine = MediaServer.session()
        let theirs = MediaServer.session() + "-other"
        _ = await MediaServer.reach("/a2-cut", session: mine)
        let mineWhileCut = try await servesPastTheCut(MediaServer.url("/a2-cutoff.mp4", session: mine))
        _ = await MediaServer.reach("/a2-mend", session: theirs)
        let mineAfterTheirsMended = try await servesPastTheCut(
            MediaServer.url("/a2-cutoff.mp4", session: mine)
        )
        let theirsServes = try await servesPastTheCut(MediaServer.url("/a2-cutoff.mp4", session: theirs))

        print("MEASURED sessions: mine \(mineWhileCut) -> \(mineAfterTheirsMended), "
              + "theirs \(theirsServes)")
        #expect(
            mineAfterTheirsMended == mineWhileCut,
            """
            another session's mend changed what this session is served: \
            \(mineWhileCut) became \(mineAfterTheirsMended)
            """
        )
        #expect(
            theirsServes,
            """
            the other session's mend did not take effect in its own namespace, \
            so the two sessions are not independent — they are both broken
            """
        )
    }

    @Test func theMediaServerIsUpWhereItIsRequired() {
        guard MediaServer.isRequired else { return }
        #expect(
            MediaServer.isAnswering,
            """
            PETNOTE_REQUIRE_MEDIA_SERVER=1 but nothing is answering on \
            \(MediaServer.host). Every stream-break test is `.enabled(if:)` on \
            that, so they would all be skipped and the run would be green \
            without having exercised any of them.
            """
        )
    }

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
        let wrappedAt = Date()
        let clockAtTheWrap = coordinator.currentTime(of: "a") ?? -1
        // **Read, not asserted.** This reading is taken at the one instant the
        // loop is mid-seek: the clock has just been put back under 1.0 by
        // `seek(to: .zero)` and the `play()` issued in the same call is what
        // happens next. What `timeControlStatus` says at that instant differs
        // by OS and is not something the loop promises. Measured: on iOS 27
        // (this Mac), 378 samples four milliseconds apart across the seam never
        // once read `.paused`; on iOS 26.2 (CI run 35755470453) the first
        // reading under 1.0 was `.paused` — and in that same run a red frame
        // was decoded after the wrap and the clock went on past 1.2 about 1.2s
        // after the loop, which is continuous playback. Nothing in the app
        // restarts a player after the loop has run, so a clock that carries on
        // is proof that the loop's own `play()` took. That is asserted below,
        // where the answer no longer depends on which instant was sampled.
        let statusAtTheWrap = player.timeControlStatus
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
        print(
            "MEASURED seam: at the wrap t=\(String(format: "%.3f", clockAtTheWrap)) "
                + "status=\(statusAtTheWrap.rawValue); past 1.2 after "
                + "\(String(format: "%.2f", Date().timeIntervalSince(wrappedAt)))s"
        )
        // And playing *now*, on the far side of the seam: the claim the old
        // reading at the wrap was standing in for.
        #expect(player.timeControlStatus == .playing, "it carried on past the seam and then stopped playing")
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

    // MARK: - 6. A stream that breaks (5D.8, the half that had no coverage)

    /// **The defect, reproduced before it is fixed.**
    ///
    /// Measured against `/a2-cutoff.mp4`, which delivers the index and the
    /// first third of the media data at a little over real time and then stops
    /// sending without hanging up. The player timeline from that run, host-side
    /// and before any of this existed:
    ///
    ///     1.1s t=0.10  item=ready control=playing  buffered=0.0-1.0  frames=2
    ///     5.6s t=4.64  item=ready control=playing  buffered=0.0-5.0  frames=17
    ///     6.4s t=4.90  item=ready control=waiting  buffered=0.0-5.0  frames=18
    ///    13.9s t=4.90  item=ready control=waiting  buffered=0.0-5.0  frames=18
    ///     END item=ready error=none duration=16.0
    ///
    /// Eleven of the sixteen seconds never play, the item is `.readyToPlay`
    /// throughout and `error` is nil — so `markFailed`, which only fires on
    /// `status == .failed`, has *nothing to fire on*. The row held its last
    /// frame with no indication and no way out.
    ///
    /// Four claims are kept apart here, because three of them stay true while
    /// the screen is frozen: the bytes arrived over HTTP, the item opened, the
    /// clock advanced, and the picture changed. Only the last two stop.
    @Test(.enabled(if: MediaServer.isAnswering))
    func aStreamThatDiesMidPlaybackIsNoticedEvenThoughNothingFails() async throws {
        let mediaSession = MediaServer.session()
        await MediaServer.reach("/a2-cut", session: mediaSession)
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "cut", fraction: 0.9, distanceFromCentre: 0)
        let player = try #require(coordinator.player(for: "cut", url: MediaServer.url("/a2-cutoff.mp4", session: mediaSession)))
        let watcher = FrameWatcher()

        // 1 — HTTP worked: the index arrived, so this is a stream that breaks
        //     and not a file that never opened.
        try await waitUntil("the item to open", timeout: 20) {
            player.currentItem?.status == .readyToPlay
        }
        let duration = try #require(player.currentItem?.duration.seconds)
        #expect(duration > 15, "the whole index arrived, so the clip knows it is 16s long")

        // 2 — the item is ready, and 3/4 — it really plays and really draws.
        try await waitUntil("playback to pass 1.5s with the picture moving", timeout: 25, describe: {
            "t=\(coordinator.currentTime(of: "cut") ?? -1) frames=\(watcher.newFrames)"
        }) {
            watcher.look(at: player)
            return (coordinator.currentTime(of: "cut") ?? 0) > 1.5 && watcher.newFrames > 4
        }
        let framesWhileHealthy = watcher.newFrames

        // Now the bytes run out.
        try await waitUntil("the stall to be noticed", timeout: 30, describe: {
            "phase=\(coordinator.state(for: "cut").name) t=\(coordinator.currentTime(of: "cut") ?? -1)"
        }) {
            watcher.look(at: player)
            return coordinator.isBuffering(for: "cut")
        }

        let frozenAt = try #require(coordinator.currentTime(of: "cut"))
        let framesAtFreeze = watcher.newFrames
        #expect(frozenAt < duration - 1, "it stopped in the middle, not at the end — t=\(frozenAt) of \(duration)")
        #expect(framesAtFreeze > framesWhileHealthy, "the picture was moving before the break")

        // 3 and 4 have stopped; 1 and 2 have not. That gap is the whole defect.
        try await Task.sleep(for: .seconds(1))
        watcher.look(at: player)
        // Not advancing — rather than "unchanged". An automatic recovery may
        // already have rebuilt the item and seeked back to the nearest earlier
        // keyframe, so the clock is allowed to go *backwards* here. What it may
        // not do is go on.
        #expect(
            (coordinator.currentTime(of: "cut") ?? -1) <= frozenAt + 0.05,
            "the clock went on past where the bytes stopped"
        )
        #expect(watcher.newFrames == framesAtFreeze, "and no new frame was decoded")
        #expect(coordinator.failure(for: "cut") == nil, "a broken stream is not a load failure")
        #expect(
            player.currentItem?.status != .failed,
            "the item never reports .failed — which is why a check on status alone had zero coverage here"
        )
        #expect(coordinator.state(for: "cut") == .stalled(offeringRecovery: false))
    }

    /// **Nothing is shown before the threshold, and it is shown just after.**
    ///
    /// The boundary is read from `VideoStallPolicy` rather than repeated, so a
    /// change to the policy moves the test with it instead of leaving a stale
    /// number to argue with.
    @Test(.enabled(if: MediaServer.isAnswering))
    func briefJitterShowsNothingAndARealStallShowsSomething() async throws {
        let mediaSession = MediaServer.session()
        await MediaServer.reach("/a2-cut", session: mediaSession)
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "cut", fraction: 0.9, distanceFromCentre: 0)
        let player = try #require(coordinator.player(for: "cut", url: MediaServer.url("/a2-cutoff.mp4", session: mediaSession)))

        // **Somebody has to be asking for the pictures.** See `FrameWatcher`.
        let watcher = FrameWatcher()
        try await waitUntil("playback to start moving", timeout: 25) {
            watcher.look(at: player)
            return (coordinator.currentTime(of: "cut") ?? 0) > 0.5
        }

        // Sample fast and keep the whole sequence: a single reading cannot tell
        // "it has not changed" from "it has not changed yet".
        var lastMoving = Date()
        var shownAt: Date?
        var previous = coordinator.currentTime(of: "cut") ?? 0
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, shownAt == nil {
            try await Task.sleep(for: .milliseconds(40))
            watcher.look(at: player)
            let now = coordinator.currentTime(of: "cut") ?? 0
            if abs(now - previous) > 0.01 { lastMoving = Date() }
            previous = now
            if coordinator.isBuffering(for: "cut") { shownAt = Date() }
        }

        let shown = try #require(shownAt, "the stall was never shown at all")
        let waited = shown.timeIntervalSince(lastMoving)
        print("MEASURED: buffering shown \(String(format: "%.2f", waited))s after the clock stopped")
        #expect(
            waited >= VideoStallPolicy.feedbackDelay,
            "shown after only \(waited)s — a hiccup shorter than the threshold would flicker"
        )
        // One poll late at worst, plus slack for a loaded machine. The upper
        // bound matters as much as the lower one: a threshold nobody ever
        // reaches is the same as no feedback at all.
        #expect(
            waited < VideoStallPolicy.feedbackDelay + VideoStallPolicy.pollInterval * 6,
            "took \(waited)s to say anything"
        )
    }

    /// **The network comes back, and playback resumes under the existing rules
    /// — without turning the sound on.**
    @Test(.enabled(if: MediaServer.isAnswering))
    func whenTheStreamComesBackItPlaysOnAndStaysMuted() async throws {
        let mediaSession = MediaServer.session()
        await MediaServer.reach("/a2-cut", session: mediaSession)
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "cut", fraction: 0.9, distanceFromCentre: 0)
        let player = try #require(coordinator.player(for: "cut", url: MediaServer.url("/a2-cutoff.mp4", session: mediaSession)))
        let watcher = FrameWatcher()

        try await waitUntil("the stall", timeout: 30, describe: {
            "phase=\(coordinator.state(for: "cut").name)"
        }) {
            watcher.look(at: player)
            return coordinator.isBuffering(for: "cut")
        }
        let frozenAt = try #require(coordinator.currentTime(of: "cut"))
        let framesAtFreeze = watcher.newFrames

        // The network comes back. Nothing else is touched: no retry is tapped,
        // no row is scrolled.
        await MediaServer.reach("/a2-mend", session: mediaSession)

        try await waitUntil("playback to pass where it stopped", timeout: 40, describe: {
            "phase=\(coordinator.state(for: "cut").name) t=\(coordinator.currentTime(of: "cut") ?? -1) frames=\(watcher.newFrames)"
        }) {
            watcher.look(at: player)
            return (coordinator.currentTime(of: "cut") ?? 0) > frozenAt + 0.5
        }

        #expect(watcher.newFrames > framesAtFreeze, "the picture is moving again, not just the clock")
        #expect(!coordinator.isBuffering(for: "cut"), "and the feedback went away")
        #expect(coordinator.playingID == "cut")

        // §5D.4. The whole recovery path rebuilds an item on the same player,
        // so the mute flag is never in a position to be lost — and this is
        // what keeps that true.
        #expect(coordinator.isMuted, "recovering must not unmute the feed")
        #expect(player.isMuted, "and the player itself is still silent")
        await MediaServer.reach("/a2-cut", session: mediaSession)
    }

    /// The two numbers that have to be read together.
    ///
    /// A recovery seeks back before the stall so it lands inside bytes that
    /// already arrived. Whatever it replays counts as playback, and enough
    /// playback refunds the automatic-recovery budget. So if a recovery can
    /// replay more than the refund threshold, every failed recovery buys
    /// itself another one and "three attempts, then ask a person" never
    /// terminates.
    ///
    /// Not hypothetical: `toleranceBefore` was `.positiveInfinity`, a recovery
    /// replayed the whole healthy 5.6s of the 16s test clip, and
    /// `automaticRecoveryIsBoundedAndThenOffersAWayOut` sat at
    /// `phase=playing attempts=1` until its sixty-second deadline.
    ///
    /// Pinned as arithmetic rather than left to the integration test, because
    /// that one takes a minute to fail and then says "timed out" instead of
    /// naming the two constants that stopped agreeing.
    @Test func recoverySeekLandsInsideTheRefundWindow() {
        #expect(
            VideoStallPolicy.recoverySeekToleranceBefore
                < VideoStallPolicy.healthyProgressToRefundBudget,
            """
            A recovery may replay up to \(VideoStallPolicy.recoverySeekToleranceBefore)s, \
            and \(VideoStallPolicy.healthyProgressToRefundBudget)s of playback refunds the \
            budget, so a failed recovery can pay for the next one.
            """
        )
    }


    /// **The automatic attempts are bounded, and then the person gets a
    /// button.**
    ///
    /// The bound is the request-storm guarantee: a dead stream in the middle of
    /// the screen may cost at most `maximumAutomaticRecoveries` rebuilds, not
    /// one per poll for as long as someone leaves the app open.
    @Test(.enabled(if: MediaServer.isAnswering))
    func automaticRecoveryIsBoundedAndThenOffersAWayOut() async throws {
        let mediaSession = MediaServer.session()
        await MediaServer.reach("/a2-cut", session: mediaSession)
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "cut", fraction: 0.9, distanceFromCentre: 0)
        let player = try #require(coordinator.player(for: "cut", url: MediaServer.url("/a2-cutoff.mp4", session: mediaSession)))
        // **Somebody has to be asking for the pictures.** See `FrameWatcher`.
        let watcher = FrameWatcher()

        // One line per change of phase, budget or item, so a failure says what
        // the player did rather than only where it ended up. The far edge of
        // `loadedTimeRanges` is in it because it is the one number that tells
        // a player waiting for bytes (the edge sits where the cut is) from a
        // player nobody is watching (the edge is the whole clip, and its clock
        // runs to the end with nothing to show). CI run 35755470453 failed
        // here with `phase=stalled attempts=3` after the budget had been
        // refunded twice — once while a rebuilt item's clock ran from ~5s to
        // the clip's end on bytes the server never sent — and this is what
        // would have said which of the two it was.
        var timeline: [String] = []
        var lastKey = ""
        let started = Date()
        func note() {
            let item = player.currentItem.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue) % 10_000) } ?? "-"
            let phase = coordinator.state(for: "cut").name
            let attempts = coordinator.automaticRecoveryAttempts(for: "cut")
            let key = "\(phase)/\(attempts)/\(item)"
            guard key != lastKey else { return }
            lastKey = key
            let edge = (player.currentItem?.loadedTimeRanges ?? [])
                .map { ($0.timeRangeValue.start + $0.timeRangeValue.duration).seconds }
                .max() ?? -1
            timeline.append(String(
                format: "w=%.1f t=%.2f %@ attempts=%d item=%@ loadedTo=%.2f frames=%d",
                Date().timeIntervalSince(started), coordinator.currentTime(of: "cut") ?? -1,
                phase, attempts, item, edge, watcher.newFrames
            ))
        }

        // Sixty seconds, against a designed worst case of about forty: the
        // first stall comes after the healthy ~5s of the clip at the fixture's
        // drip rate (~7s of wall clock), then the three automatic attempts at
        // 1.5, 4 and 9s into their episodes, each followed by a replay of at
        // most `recoverySeekToleranceBefore` plus a fresh 0.6s confirmation,
        // then `recoveryOfferDelay` (10s) into the last episode. Measured on
        // this Mac: 35s from the player being made to the offer.
        do {
            try await waitUntil("the recovery offer", timeout: 60, describe: {
                "phase=\(coordinator.state(for: "cut").name) attempts=\(coordinator.automaticRecoveryAttempts(for: "cut")) "
                    + "timeline: \(timeline.joined(separator: " | "))"
            }) {
                watcher.look(at: player)
                note()
                return coordinator.needsManualRecovery(for: "cut")
            }
        } catch {
            for line in timeline { print("MEASURED recovery timeline: \(line)") }
            throw error
        }
        for line in timeline { print("MEASURED recovery timeline: \(line)") }

        #expect(coordinator.state(for: "cut") == .stalled(offeringRecovery: true))
        let spent = coordinator.automaticRecoveryAttempts(for: "cut")
        print("MEASURED automatic rebuilds before the offer appeared: \(spent)")
        #expect(spent >= 1, "nothing was tried automatically before asking a person")
        #expect(
            spent <= VideoStallPolicy.maximumAutomaticRecoveries,
            "the bound was exceeded: \(spent) rebuilds"
        )

        // And it stops there. Left alone for several more poll intervals, the
        // count must not creep.
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            watcher.look(at: player)
        }
        let after = coordinator.automaticRecoveryAttempts(for: "cut")
        print("MEASURED automatic rebuilds four seconds later: \(after)")
        #expect(
            after <= VideoStallPolicy.maximumAutomaticRecoveries,
            "the budget refilled while the stream was still dead: \(after) rebuilds"
        )
    }

    /// **A server that connects and then says nothing.**
    ///
    /// The failure with no error anywhere: the socket is open, the response
    /// headers are valid, and no byte of media ever arrives. Nothing below
    /// AVFoundation reports a problem, so this is indistinguishable from a slow
    /// load right up until it is not.
    ///
    /// It stays `.opening` — the poster and its play badge are already on
    /// screen and are the honest thing to show — and it is never called a
    /// failure. What it gets is the way out.
    @Test(.enabled(if: MediaServer.isAnswering))
    func aServerThatSendsNothingIsStillOpeningAndThenOffersAWayOut() async throws {
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "void", fraction: 0.9, distanceFromCentre: 0)
        _ = try #require(coordinator.player(for: "void", url: MediaServer.url("/a2-blackhole.mp4")))

        // Well past the point where a stall is confirmed, this is still just a
        // video that is opening: no picture, so no spinner over the poster.
        try await Task.sleep(for: .seconds(VideoStallPolicy.feedbackDelay + 1.5))
        #expect(!coordinator.hasPicture(for: "void"))
        #expect(coordinator.state(for: "void") == .opening, "a slow first load is not an error")
        #expect(
            coordinator.automaticRecoveryAttempts(for: "void") == 0,
            "a video that has never opened is left to AVFoundation's own retry"
        )

        try await waitUntil("the way out", timeout: 40, describe: {
            "phase=\(coordinator.state(for: "void").name)"
        }) { coordinator.needsManualRecovery(for: "void") }
        #expect(coordinator.state(for: "void") == .stalled(offeringRecovery: true))
        #expect(coordinator.failure(for: "void") == nil, "it has not failed; it has not arrived")
    }

    /// **An error response is a failure, and must not be dressed up as one.**
    ///
    /// The other end of the same axis: a 500 is unambiguous, AVFoundation says
    /// `.failed`, and the row should get the existing full retry rather than a
    /// spinner that will never stop.
    @Test(.enabled(if: MediaServer.isAnswering))
    func anErrorResponseIsAFailureAndNotAStall() async throws {
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "five", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "five", url: MediaServer.url("/a2-error500.mp4"))

        try await waitUntil("the failure", timeout: 30, describe: {
            "phase=\(coordinator.state(for: "five").name)"
        }) { coordinator.failure(for: "five") != nil }

        #expect(coordinator.state(for: "five") == .failed("Video failed to load. Tap to retry."))
        #expect(!coordinator.isBuffering(for: "five"), "a definite failure must not show as buffering")
        #expect(coordinator.livePlayerCount == 0, "and it does not keep a decoder")
    }

    // MARK: - 7. The five silences that are not stalls

    /// Every reason a video can be still without anything being wrong, and the
    /// one reason that is. One test, because the claim is about the *set*:
    /// exactly one of these may draw anything.
    @Test(.enabled(if: MediaServer.isAnswering))
    func onlyOneOfTheSixStatesMayShowBufferingFeedback() async throws {
        let mediaSession = MediaServer.session()
        let url = try await clip()

        // 1 — first load. A player, no picture yet.
        let opening = VideoPlaybackCoordinator()
        opening.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = opening.player(for: "a", url: MediaServer.url("/a2-blackhole.mp4", session: mediaSession))
        #expect(opening.state(for: "a") == .opening)

        // 2 — the person stopped it. Pointed at a stream that is dead on
        //     purpose: however long it stays dead, a paused video is not a
        //     stalled one.
        await MediaServer.reach("/a2-cut", session: mediaSession)
        let paused = VideoPlaybackCoordinator()
        paused.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = paused.player(for: "a", url: MediaServer.url("/a2-cutoff.mp4", session: mediaSession))
        paused.setViewerPaused(true, id: "a")
        try await Task.sleep(for: .seconds(VideoStallPolicy.feedbackDelay + 1))
        #expect(paused.state(for: "a") == .pausedByViewer)
        #expect(!paused.isBuffering(for: "a"), "a video the person stopped never reports trouble")
        #expect(!paused.isActuallyPlaying(id: "a"))
        // And starting it again puts it back under the ordinary rules.
        paused.setViewerPaused(false, id: "a")
        #expect(paused.playingID == "a")

        // 3 — the app went to the background.
        let backgrounded = VideoPlaybackCoordinator()
        backgrounded.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = backgrounded.player(for: "a", url: MediaServer.url("/a2-cutoff.mp4", session: mediaSession))
        backgrounded.suspendAll(reason: "test")
        try await Task.sleep(for: .seconds(VideoStallPolicy.feedbackDelay + 1))
        #expect(backgrounded.state(for: "a") == .suspended)
        #expect(!backgrounded.isBuffering(for: "a"), "a backgrounded app never reports trouble")

        // 4 — on screen, healthy, and simply not the chosen one.
        let second = VideoPlaybackCoordinator()
        second.reportVisibility(id: "near", fraction: 0.95, distanceFromCentre: 0)
        _ = second.player(for: "near", url: url)
        second.reportVisibility(id: "far", fraction: 0.8, distanceFromCentre: 300)
        _ = second.player(for: "far", url: url)
        #expect(second.playingID == "near")
        #expect(second.state(for: "far") == .waitingItsTurn)
        #expect(!second.isBuffering(for: "far"))

        // 5 — off screen entirely.
        second.reportOffscreen(id: "far")
        #expect(second.state(for: "far") == .idle)
        #expect(!second.isBuffering(for: "far"))

        // 6 — an explicit failure is its own thing, and is not buffering.
        let broken = VideoPlaybackCoordinator()
        broken.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = broken.player(for: "a", url: TestVideoFixture.missingFileURL())
        try await waitUntil("the failure") { broken.failure(for: "a") != nil }
        #expect(!broken.isBuffering(for: "a"))
    }

    /// **A clip that ran out is not a clip that stopped.**
    ///
    /// The third cause of a frozen clock, and the one that looks most like the
    /// other two from outside: nothing downloaded, downloaded but not decoding,
    /// and *the clip is simply over*. `t` alone matches all three.
    ///
    /// The clips in this feed are four seconds long, so a row crosses this seam
    /// every four seconds for as long as anyone looks at it. A stall detector
    /// that cannot tell the seam from a break would put a spinner on every
    /// healthy video in the feed, four seconds after it started.
    @Test func playingThroughTheEndAndLoopingIsNeverReportedAsAStall() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        let player = try #require(coordinator.player(for: "a", url: url))
        try await waitUntil("a picture") { coordinator.hasPicture(for: "a") }

        // Long enough to cross the end at least once, sampled densely enough
        // that a spinner lasting a single poll would still be caught.
        var everBuffered: [String] = []
        var wrapped = false
        var previous = coordinator.currentTime(of: "a") ?? 0
        let deadline = Date().addingTimeInterval(TestVideoFixture.duration + 4)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(80))
            let now = coordinator.currentTime(of: "a") ?? 0
            if now + 1 < previous { wrapped = true }
            previous = now
            if coordinator.isBuffering(for: "a") {
                everBuffered.append(String(format: "t=%.2f", now))
            }
        }

        #expect(wrapped, "the clip never reached its end, so the seam was not exercised")
        #expect(
            everBuffered.isEmpty,
            "a healthy looping clip was reported as stalled at \(everBuffered)"
        )
        #expect(coordinator.playingID == "a")
        #expect(player.timeControlStatus == .playing)
    }

    /// And the state itself is reachable: a clip that runs out while it is not
    /// the chosen one is parked, and says `ended` rather than `stalled`.
    @Test func aClipThatRanOutWhileNotChosenReportsEndedRatherThanStalled() async throws {
        let url = try await clip()
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        let player = try #require(coordinator.player(for: "a", url: url))
        try await waitUntil("a picture") { coordinator.hasPicture(for: "a") }

        // It loses the centre, and then runs out where it stands. The winner is
        // whichever eligible video is *closest to the middle* — not whichever
        // has the larger visible fraction — so "a" has to be moved away for "b"
        // to take over. Two rows both reporting distance 0 is a tie the
        // coordinator is entitled to break either way.
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 400)
        coordinator.reportVisibility(id: "b", fraction: 0.95, distanceFromCentre: 0)
        _ = coordinator.player(for: "b", url: url)
        #expect(coordinator.playingID == "b")

        await player.seek(to: CMTime(seconds: TestVideoFixture.duration - 0.2, preferredTimescale: 600))
        player.play()
        try await waitUntil("the clip to run out", timeout: 15, describe: {
            "phase=\(coordinator.state(for: "a").name)"
        }) { coordinator.state(for: "a") == .ended }
        #expect(!coordinator.isBuffering(for: "a"))
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

// MARK: - The controllable media server

/// The same deterministic server the UI tests use, reached from the unit tests.
///
/// Why these tests need a server at all, when everything else here plays a
/// local file: a file is either there or it is not. Every failure this section
/// is about happens *while bytes are arriving* — half of them delivered and
/// then nothing, a socket that opens and stays silent, a 500 — and none of
/// those shapes can be made out of a `file://` URL. The server can also be
/// told to mend itself, which is the only way "it recovers when the network
/// comes back" can be a test rather than a hope.
enum MediaServer {
    /// `PETNOTE_MEDIA_SERVER` (passed as `TEST_RUNNER_PETNOTE_MEDIA_SERVER` to
    /// `xcodebuild`) points these tests at a second fixture server without
    /// touching the shared one on 8123 — which is how a fixture rendered on a
    /// different machine, with a different length, can be reproduced here.
    static let host = ProcessInfo.processInfo.environment["PETNOTE_MEDIA_SERVER"]
        ?? "http://127.0.0.1:8123"

    static func url(_ path: String) -> URL {
        // Force-unwrapped against a literal: if this is nil the test file does
        // not compile a meaningful thing anyway.
        URL(string: host + path)!
    }

    /// A namespace of one test's own on the server.
    ///
    /// The server's switches used to be one dict for the whole process. Every
    /// test that wanted a broken stream called `/a2-cut` first, so ordering
    /// alone looked sufficient — and
    /// `automaticRecoveryIsBoundedAndThenOffersAWayOut` still failed with
    /// `phase=playing attempts=0`, which is what a stream that never broke
    /// looks like.
    ///
    /// Defaulting to `#function` means the token is the test's own name: it
    /// cannot collide, and it appears in the server's `SWITCH session=...`
    /// log, so a later failure can be read back to "did this test's own cut
    /// arrive, and what did its session look like afterwards".
    ///
    /// It also gives the test its own URL, which rules out a second candidate
    /// that could not otherwise be told apart: an asset cached under one
    /// test's URL answering another's request.
    /// One per test-host process, so two runs cannot share a namespace.
    ///
    /// `#function` alone was not enough and the gap is not theoretical:
    /// `-test-iterations` runs the same test repeatedly in one process, and a
    /// second `xcodebuild` against the same server is an ordinary thing to do
    /// while investigating. Both would have reused one token.
    nonisolated static let runID: String = String(UUID().uuidString.prefix(8))

    private nonisolated static let iterationLock = NSLock()
    nonisolated(unsafe) private static var iterations: [String: Int] = [:]

    /// A namespace of one test *run* — process, test, and which time round.
    ///
    /// The token is `<runID>-<test>-<n>` and the same string is used for the
    /// control URL, the media URL, the server's `SWITCH session=…` log line
    /// and the entry it cleans up, so one identifier follows the whole thing
    /// rather than four that have to be correlated by timestamp.
    static func session(_ name: String = #function) -> String {
        let base = String(name.prefix(while: { $0 != "(" }))
        iterationLock.lock()
        defer { iterationLock.unlock() }
        let n = (iterations[base] ?? 0) + 1
        iterations[base] = n
        return "\(runID)-\(base)-\(n)"
    }

    static func url(_ path: String, session: String) -> URL {
        URL(string: "\(host)\(path)?s=\(session)")!
    }

    /// Whether this environment is one where the media server is **required**
    /// rather than nice to have.
    ///
    /// The distinction exists because both policies are right, in different
    /// places. On a laptop, a developer running the unit suite without having
    /// started a local HTTP server should get the rest of the suite and a note,
    /// not a wall of red about a dependency they did not ask for. In CI the
    /// same silence is a hole: the stream-break tests appeared **zero times**
    /// in the `ios-native` log for every run up to `c4d9089`, and the job was
    /// green, because `.enabled(if:)` disables quietly and a disabled test
    /// looks exactly like a test that has nothing to say.
    ///
    /// So CI sets `PETNOTE_REQUIRE_MEDIA_SERVER=1` (as
    /// `TEST_RUNNER_PETNOTE_REQUIRE_MEDIA_SERVER`, or it never arrives), and
    /// `theMediaServerIsUpWhereItIsRequired` turns the silence into a failure.
    /// The workflow separately greps the log for the three test names, because
    /// one guard that has to be remembered is not the same as two that
    /// disagree when something is wrong.
    nonisolated static let isRequired: Bool =
        ProcessInfo.processInfo.environment["PETNOTE_REQUIRE_MEDIA_SERVER"] == "1"

    /// Synchronous on purpose. `.enabled(if:)` is evaluated while tests are
    /// being collected, which is not an async context; and a suite that fails
    /// red because nobody started a server is the fastest way to teach everyone
    /// to ignore it.
    ///
    /// **Asked more than once, and for longer where it is required.** One
    /// three-second probe failed on CI (run 35836744692) against a server the
    /// workflow had seen answer; four failed on another (35850459362), and the
    /// server's own log shows why: all four requests reached it together,
    /// sixteen seconds after the first was sent, when each had already timed
    /// out. The simulator's loopback was not up yet. A failed probe fails
    /// nothing — it quietly disables the stream-break tests — so where the
    /// server is required the probe keeps asking for about a minute. Where it
    /// is not, two tries: a Mac with no server running should skip quickly.
    nonisolated static let isAnswering: Bool = {
        func probe() -> Bool {
            var request = URLRequest(url: URL(string: host + "/a2-long.mp4")!)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 3
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let done = DispatchSemaphore(value: 0)
            var ok = false
            URLSession.shared.dataTask(with: request) { _, response, _ in
                ok = (response as? HTTPURLResponse)?.statusCode == 200
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 6)
            return ok
        }
        var ok = false
        let attempts = isRequired ? 12 : 2
        for attempt in 1...attempts {
            ok = probe()
            if ok { break }
            if attempt < attempts { Thread.sleep(forTimeInterval: 2) }
        }
        if !ok {
            print("""
                SKIPPING the stream-break tests: nothing on \(host), or no \
                a2-long.mp4 there. Start it with ios-native/scripts/a2-test-media.sh
                """)
        }
        return ok
    }()

    /// Flips a switch on the server and **waits for the answer**.
    ///
    /// Awaited rather than fired and forgotten: a test that mends the stream
    /// and immediately asserts recovery is racing the server, and the version
    /// of that race that passes on a quiet machine is the one that fails in a
    /// full run.
    @discardableResult
    static func reach(_ path: String, session: String) async -> Bool {
        await reach("\(path)?s=\(session)")
    }

    static func reach(_ path: String) async -> Bool {
        var request = URLRequest(url: url(path))
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 5
        return (try? await URLSession.shared.data(for: request)) != nil
    }
}

// MARK: - Did the picture actually change?

/// Counts decoded frames, across an item being replaced underneath it.
///
/// Four things get conflated whenever a video "does not work", and three of
/// them can be true while the screen is frozen: the bytes arrived, the item
/// opened, the clock advanced, and **a new picture was decoded**. Only this
/// last one is what a person sees, and `playingID` cannot speak to it.
///
/// Re-attaching per item matters: recovering from a stall hands the player a
/// new `AVPlayerItem`, and an output added to the old one simply stops
/// producing buffers — which would read exactly like "the video never came
/// back" when in fact it had.
///
/// **And a consumer is not optional in a stall test.** Measured, and it cost
/// two red tests before it was understood: an `AVPlayer` with nothing pulling
/// frames out of it — no layer, no output — does not decode, so it has no
/// reason to wait for bytes it cannot use. Pointed at a stream that dies at
/// 4.9s of 16, such a player reports the whole clip as loaded
/// (`loadedTimeRanges` 0–16 on about a third of its bytes), runs its clock all
/// the way to 16.0 and posts `didPlayToEndTime`, without a single stall.
///
/// **The consumer belongs to the player, as the app's does — not to each
/// item.** This used to rely on the per-item output alone, and an output can
/// only be attached to a rebuilt item *after* the coordinator has handed it to
/// the player, on this watcher's next poll. What CI run 35755470453 showed on
/// iOS 26.2: the item from the first automatic rebuild ran its clock from ~5s
/// to the clip's end and looped, on bytes the server log shows were never sent
/// — the signature of a player nobody is watching — and the playback it
/// "made" refunded the recovery budget, so the bound never bit inside the
/// deadline. *Why* that item had no effective consumer was not reproduced
/// here: on iOS 27 an output attached 300ms or even 1.5s late still makes the
/// item wait for its bytes. But the app never has the gap at all:
/// `VideoPlayerView` gives the *player* an `AVPlayerLayer`, and `rebuildItem`
/// swaps the item underneath a layer that is already there. So this does the
/// same. Measured on this Mac, a detached `AVPlayerLayer` with no output at all
/// is sufficient demand: the item stops at the cut (`loadedTimeRanges` ending
/// at 5.0), and every rebuilt item after it does too. The outputs are still
/// attached per item, but only to count frames.
///
/// Holding the watched item, rather than keying outputs by `ObjectIdentifier`,
/// is so an item freed by a rebuild cannot hand its address — and with it, a
/// stale output attached to a dead item — to a later one. Not hypothetical:
/// in the first local run of `automaticRecoveryIsBoundedAndThenOffersAWayOut`
/// with its timeline, the item from the third rebuild came back at the
/// original item's address, which the old dictionary would have answered with
/// the original's output and never given the new item one.
@MainActor
final class FrameWatcher {
    private var layer: AVPlayerLayer?
    private var watchedItem: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private(set) var newFrames = 0
    private(set) var colours: [Colour] = []

    func look(at player: AVPlayer) {
        if layer?.player !== player {
            layer = AVPlayerLayer(player: player)
        }
        guard let item = player.currentItem else { return }
        guard item === watchedItem, let output else {
            let fresh = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(fresh)
            watchedItem = item
            output = fresh
            return   // nothing is decoded into it yet
        }
        let time = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return }
        newFrames += 1
        colours.append(Colour(averageOf: buffer))
    }
}
