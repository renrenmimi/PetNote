import XCTest

/// Video in the real interface, scrolled by real gestures.
///
/// A unit test that calls `reportVisibility` thirty times is not a list that
/// scrolls past thirty videos: it never lays anything out, never reuses a row,
/// and never asks AVPlayer for a frame. This drives the actual feed.
///
/// **The media is local and deterministic.** Playback is pointed at
/// `http://127.0.0.1:8123/a2-clip.mp4`, a four-second clip written by
/// `scratchpad/make-media.swift`: red for its first second, green for its
/// second, blue for its third, with a white bar that moves every frame. The
/// poster is solid yellow, a colour the clip never contains. That is what
/// makes "there is a picture, and it is the video and not the poster" a thing
/// a screenshot can settle. The seeded Cloudinary clips would make the same
/// test depend on someone else's CDN, and on a frame whose colour nobody
/// knows.
///
/// Four claims are kept apart on purpose, because the first three can all hold
/// while the screen shows nothing:
///
///   1. **chosen** — the coordinator picked this video (`playing=true`);
///   2. **played** — `play()` really went out (`state` leaves `poster`);
///   3. **advancing** — the clock crossed a boundary (`advanced=true`);
///   4. **drawn** — the pixels on screen are the clip's (the screenshot).
///
/// What this still cannot show: smoothness, whether decoding keeps up, or
/// memory. Those need a device and Instruments.
final class VideoPlaybackUITests: XCTestCase {
    private static let mediaHost = "http://127.0.0.1:8123"
    /// The generated clip's length. Named so the wrap test says why it waits.
    private let clipDuration: TimeInterval = 4
    /// Solid yellow, the poster. Measured off the generated file rather than
    /// assumed: the JPEG round trip moves it slightly.
    private static let posterColour = Sample(r: 0.99, g: 0.85, b: 0.14)
    private static let clipColours = [
        Sample(r: 1, g: 0.15, b: 0.15),     // second 0
        Sample(r: 0.15, g: 0.85, b: 0.2),   // second 1
        Sample(r: 0.2, g: 0.3, b: 1),       // second 2
        Sample(r: 0.9, g: 0.2, b: 0.9),     // second 3
    ]

    /// Skips rather than fails when the media server is not running.
    ///
    /// The alternative is a suite that goes red for a reason that has nothing
    /// to do with the app, which is the fastest way to teach everyone to
    /// ignore it. The message says exactly what to start.
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard Self.mediaServerIsAnswering() else {
            throw XCTSkip("""
                No deterministic media server on \(Self.mediaHost). These tests                 need media whose colours are known in advance; start it with

                    ios-native/scripts/a2-test-media.sh

                and run them again.
                """)
        }
    }

    private static func mediaServerIsAnswering() -> Bool {
        guard let url = URL(string: mediaHost + "/a2-poster.jpg") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 4
        let answered = XCTestExpectation(description: "media server")
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            answered.fulfill()
        }.resume()
        _ = XCTWaiter.wait(for: [answered], timeout: 6)
        return ok
    }

    // MARK: - Driving the app

    private func launch(
        videoPath: String = "/a2-clip.mp4",
        everythingIsVideo: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-petnote-start-signed-out",
            "-petnote-video-probe",
            "-petnoteVideoURLOverride", Self.mediaHost + videoPath,
            "-petnoteVideoPosterOverride", Self.mediaHost + "/a2-poster.jpg",
        ]
        if everythingIsVideo { app.launchArguments.append("-petnote-all-media-is-video") }
        app.launch()
        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 15))
        let email = app.textFields["login.email"]
        email.tap(); email.typeText("accept-a@example.com")
        let password = app.secureTextFields["login.password"]
        password.tap(); password.typeText("Passw0rd!x")
        app.buttons["login.submit"].tap()
        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 40))
        waitForQuietUI(app)
        return app
    }

    private func list(_ app: XCUIApplication) -> XCUIElement {
        app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
    }

    /// The coordinator's own state, published into the navigation bar.
    ///
    /// Scoped to the navigation bar and taken as `firstMatch`: an unscoped
    /// `app.staticTexts[...]` walks the whole tree, and a feed with 210 rows in
    /// it once turned a one-minute run into twenty-two minutes.
    private func probe(_ app: XCUIApplication) -> String {
        let element = app.navigationBars.staticTexts.matching(identifier: "video.probe").firstMatch
        return element.exists ? element.label : ""
    }

    /// Every video row currently on screen, with what it says about itself.
    private func surfaces(_ app: XCUIApplication) -> [(element: XCUIElement, state: String)] {
        app.otherElements.matching(identifier: "video.surface").allElementsBoundByIndex
            .filter { $0.exists }
            .map { ($0, $0.value as? String ?? "") }
    }

    /// `rebuilds=N` out of the probe string, or nil if it is not there.
    ///
    /// nil rather than 0 on purpose: "the field is missing" and "no recovery
    /// has happened" are different, and treating the first as the second would
    /// let this comparison pass by accident on a build whose probe never
    /// reported the number.
    static func rebuilds(in state: String) -> Int? {
        guard let range = state.range(of: "rebuilds=") else { return nil }
        let tail = state[range.upperBound...].prefix { $0.isNumber }
        return Int(tail)
    }

    private func playingSurface(_ app: XCUIApplication) -> (element: XCUIElement, state: String)? {
        surfaces(app).first { $0.state.contains("playing=true") }
    }

    /// Waits for the feed to have rows at all.
    ///
    /// Swiping an empty list does nothing and looks exactly like "the video
    /// never played": the first run of this suite scrolled eight times while
    /// the first page was still arriving from the emulator, found no video,
    /// and reported a playback defect that did not exist. The media server's
    /// log settled it — the app had not asked for a single byte.
    private func waitForFeedRows(_ app: XCUIApplication, timeout: TimeInterval = 90) {
        XCTAssertTrue(
            list(app).cells.firstMatch.waitForExistence(timeout: timeout),
            "the feed never showed a row, so nothing below this measures video"
        )
    }

    /// Scrolls slowly until some row reports itself as playing.
    @discardableResult
    private func scrollToAPlayingVideo(_ app: XCUIApplication, swipes: Int = 12) -> String {
        waitForFeedRows(app)
        for _ in 0..<swipes {
            if let found = playingSurface(app) { return found.state }
            list(app).swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.8)
        }
        return playingSurface(app)?.state ?? ""
    }

    private func waitForState(
        _ app: XCUIApplication,
        contains needle: String,
        timeout: TimeInterval = 15
    ) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            last = playingSurface(app)?.state ?? last
            if last.contains(needle) { return last }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return last
    }

    // MARK: - 1–4, separated

    func testAVideoIsChosenPlayedAdvancingAndActuallyDrawn() throws {
        let app = launch()
        let state = scrollToAPlayingVideo(app)
        XCTAssertFalse(state.isEmpty, "no video row ever reported itself playing")

        // 1 and 2: chosen, and past the poster.
        print("MEASURED first playing state: \(state)")
        XCTAssertTrue(state.contains("playing=true"), state)
        let withPicture = waitForState(app, contains: "state=picture")
        XCTAssertTrue(withPicture.contains("state=picture"), "never got past opening: \(withPicture)")
        XCTAssertTrue(
            withPicture.contains("size=320x240"),
            "the decoder reported a different picture size than the file has: \(withPicture)"
        )

        // 3: the clock crossed a real boundary. Not "t did not change" —
        // "waiting to buffer" and "broken" look identical from a fixed sleep,
        // so this waits on the player's own boundary observer instead.
        let advanced = waitForState(app, contains: "advanced=true")
        XCTAssertTrue(advanced.contains("advanced=true"), "the clock never moved: \(advanced)")
        print("MEASURED advanced state: \(advanced)")

        // 4: what is on the glass.
        let surface = try XCTUnwrap(playingSurface(app)?.element)
        let firstShot = try XCTUnwrap(Self.centreColour(of: surface, in: app), "no screenshot")
        print("MEASURED colour while playing: \(firstShot)")
        XCTAssertFalse(
            firstShot.isNear(Self.posterColour),
            "the poster is still what is on screen, not the video: \(firstShot)"
        )
        XCTAssertTrue(
            Self.clipColours.contains { firstShot.isNear($0) },
            "what is drawn is not any frame of the clip: \(firstShot)"
        )

        // And it is moving: the clip changes colour every second.
        var changed: Sample?
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.4)
            guard let now = Self.centreColour(of: surface, in: app) else { continue }
            if !now.isNear(firstShot, tolerance: 0.18) { changed = now; break }
        }
        let second = try XCTUnwrap(changed, "the picture never changed — a frozen first frame counts as broken")
        print("MEASURED colour a moment later: \(second)")
        XCTAssertTrue(
            Self.clipColours.contains { second.isNear($0) },
            "the second picture is not a frame of the clip either: \(second)"
        )
    }

    // (The poster's own colour is checked in
    // `testWhileAVideoIsOpeningThePosterIsStillWhatIsOnScreen` below, which is
    // a better place for it: the row that is opening is the one in the middle
    // of the screen, so it can be photographed without hunting for a row that
    // happens to be both idle and fully visible.)

    /// **The seam, on the glass.**
    ///
    /// The unit tests prove the clock wraps and that the decoder hands back
    /// the first block again. Neither of them looks at the screen, and the
    /// defect this is about was a screen one: the clip is four seconds long,
    /// so before looping existed a row spent almost its whole life holding
    /// its last frame, and "the picture never changes" was reported as a dead
    /// decoder. It was a finished clip.
    ///
    /// The claim here is narrow and is the one a person would make: watch one
    /// row for longer than the clip lasts, and the picture goes round. Not
    /// "it changed" — a clip playing once changes too — but that after
    /// reaching the last block it is back at the first.
    func testTheGlassKeepsChangingPastTheEndOfTheClip() throws {
        let app = launch()
        XCTAssertTrue(scrollToAPlayingVideo(app).contains("playing=true"))
        XCTAssertTrue(waitForState(app, contains: "state=picture").contains("state=picture"))
        let surface = try XCTUnwrap(playingSurface(app)?.element)

        // Which block each sample landed in, in order. Values, not elements:
        // reading `.frame` or `.label` from a held element on a second pass
        // is the stale-snapshot trap this project has hit five times.
        var blocks: [Int] = []
        var samples: [String] = []
        let started = Date()
        // Two conditions, not a fixed count: a loaded machine takes longer
        // per screenshot, and the claim is about the clip's four seconds
        // rather than about how many photographs fit into them.
        let ceiling = started.addingTimeInterval(45)
        while Date() < ceiling {
            if let colour = Self.centreColour(of: surface, in: app) {
                if let index = Self.clipColours.firstIndex(where: { colour.isNear($0) }) {
                    samples.append("\(index)")
                    if blocks.last != index { blocks.append(index) }
                } else {
                    samples.append("?")
                }
            }
            // Wrapped: it reached the back half of the clip and then came
            // round to the first block again.
            if let wrap = blocks.firstIndex(where: { $0 >= 2 }),
               blocks.dropFirst(wrap).contains(0),
               Date().timeIntervalSince(started) >= clipDuration {
                break
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        print("MEASURED block sequence on the glass: \(samples.joined(separator: " "))")
        print("MEASURED transitions: \(blocks)")
        XCTAssertGreaterThanOrEqual(
            blocks.count, 3,
            "the picture barely changed in \(Int(Date().timeIntervalSince(started)))s: \(samples.joined(separator: " "))"
        )
        let reachedTheEnd = try XCTUnwrap(
            blocks.firstIndex(where: { $0 >= 2 }),
            "the clip never reached its second half: \(blocks)"
        )
        XCTAssertTrue(
            blocks.dropFirst(reachedTheEnd).contains(0),
            "after the last block the picture never came back to the first — it played once and "
                + "stopped, which is the frozen-last-frame case, not looping: \(blocks)"
        )
    }

    // MARK: - Sound

    /// Muted to begin with, and the control says both what it is and what it
    /// will do.
    ///
    /// **What this cannot show:** whether another app's music actually keeps
    /// playing. That is an audio-session fact, the simulator shares no session
    /// with anything, and it stays on the device list.
    func testVideoStartsMutedAndTheControlTogglesBothWays() throws {
        let app = launch()
        XCTAssertTrue(scrollToAPlayingVideo(app).contains("playing=true"))

        let mute = app.buttons["video.mute"].firstMatch
        XCTAssertTrue(mute.waitForExistence(timeout: 15), "a playing video offered no sound control")
        // The label is the state: muted video offers "Unmute".
        XCTAssertEqual(mute.label, "Unmute video", "the video did not start muted")

        mute.tap()

        // **Where the tap went, before what it did.**
        //
        // Measured: it opened the post. The app's own log, at the moment of
        // the tap, reads `video: released all (navigated away)` — which is
        // `SignedInView` reacting to navigation, not the coordinator being
        // muted. `PostCard` puts an `.onTapGesture` around `MediaView`, and
        // that ancestor swallows the tap meant for the button inside it;
        // this is the same defect `PostCard`'s own comment records for the
        // like button ("the like button could not be activated at all"),
        // still present for the sound control.
        //
        // Checked first because the other assertion cannot tell the two
        // apart: the detail screen draws the same row with the same
        // `video.mute` identifier, so the button is still found afterwards
        // and still reads "Unmute video" — which looks like "the toggle did
        // nothing" and is really "you are on a different screen".
        XCTAssertTrue(
            app.navigationBars["PetNote"].exists,
            "tapping the sound control opened the post instead of unmuting — the tap is being "
                + "swallowed by the gesture PostCard puts around MediaView"
        )
        XCTAssertTrue(
            Self.waitForLabel(mute, toBe: "Mute video"),
            "unmuting did not take — the control still reads \(mute.label)"
        )
        // And unmuting does not stop the video, which is what a reconfigured
        // audio session in the middle of playback could easily do.
        let stillPlaying = waitForState(app, contains: "playing=true")
        XCTAssertTrue(stillPlaying.contains("playing=true"), "unmuting stopped playback: \(stillPlaying)")

        mute.tap()
        XCTAssertTrue(
            Self.waitForLabel(mute, toBe: "Unmute video"),
            "re-muting did not take — the control still reads \(mute.label)"
        )
        let afterRemute = waitForState(app, contains: "playing=true")
        XCTAssertTrue(afterRemute.contains("playing=true"), "re-muting stopped playback: \(afterRemute)")
    }

    private static func waitForLabel(
        _ element: XCUIElement, toBe expected: String, timeout: TimeInterval = 10
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label == expected { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    // MARK: - Leaving, coming back

    /// **The seeded feed on purpose, and a bigger budget for arriving.**
    ///
    /// This one wants the videos *sparse*. The seed puts them at posts 2, 26,
    /// 63, 117, 170 and 203, so four fast swipes land somewhere with no video
    /// in it at all and `playing` becomes `none` — which is the thing being
    /// asserted, unambiguously.
    ///
    /// Making every row a video was tried here and measured *worse*: the fling
    /// can then settle on another video, and a run recorded
    /// `players=1 playing=post-000` both before **and** after four synthesized
    /// swipes. That reads like "the feed is stuck" and really means "there was
    /// another video right there". The only genuine flake was *arriving* at a
    /// video at all, so only the arrival budget changed.
    func testScrollingAwayStopsPlaybackAndReleasesThePlayer() {
        let app = launch()
        let state = scrollToAPlayingVideo(app, swipes: 20)
        XCTAssertFalse(state.isEmpty, "nothing was playing to begin with")
        let before = probe(app)
        print("MEASURED probe while playing: \(before)")

        for _ in 0..<4 { list(app).swipeUp(velocity: .fast) }
        Thread.sleep(forTimeInterval: 3)
        let after = probe(app)
        print("MEASURED probe after scrolling past: \(after)")

        XCTAssertLessThanOrEqual(
            Self.players(in: after) ?? 99, 2,
            "more players alive than the ceiling allows: \(after)"
        )
        XCTAssertNotEqual(
            Self.value(named: "playing", in: after),
            Self.value(named: "playing", in: before),
            "the row we scrolled away from is still the one playing: \(after)"
        )
    }

    /// Backgrounding stops playback; returning does not start it again by
    /// itself, and a scroll does. The rule is written down in
    /// `VideoPlayerView`; this is the rule actually happening.
    ///
    /// **Every row is a video here**, and that is a fixture fix rather than a
    /// weaker claim. The seed has six videos among 210 posts, so "scroll a
    /// little and see whether video comes back" was really "scroll a little
    /// and hope another one of six rows is nearby": the run that caught this
    /// swiped five times, left the only video on screen behind, found no video
    /// row at all, and reported the stuck case. Nothing was stuck — there was
    /// nothing to play. With every row a video, one swipe is guaranteed to put
    /// one in the middle, and a silent feed afterwards means what the test
    /// says it means.
    func testBackgroundingStopsPlaybackAndReturningIsQuietUntilAScroll() {
        let app = launch(everythingIsVideo: true)
        XCTAssertFalse(scrollToAPlayingVideo(app).isEmpty)

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        waitForQuietUI(app)

        let afterReturn = probe(app)
        print("MEASURED probe after returning: \(afterReturn)")
        XCTAssertTrue(
            afterReturn.contains("playing=none") || afterReturn.isEmpty,
            "video resumed on its own after the app came back: \(afterReturn)"
        )

        list(app).swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 1.5)
        let afterScroll = scrollToAPlayingVideo(app, swipes: 4)
        print("MEASURED state after a scroll: \(afterScroll)")
        XCTAssertTrue(
            afterScroll.contains("playing=true"),
            "and then it would not start again, which is the stuck case: \(afterScroll)"
        )
    }

    // MARK: - Broken media, and getting out of it

    /// The whole failure loop, in the real interface: a 404 becomes a retry
    /// button, the asset comes back, the tap rebuilds the player, and a
    /// picture appears.
    ///
    /// `/a2-flaky.mp4` answers 404 until the test fetches `/a2-heal`, so
    /// "the network came back" happens exactly when this test says it does.
    func testABrokenVideoOffersRetryAndTheRetryRecovers() throws {
        Self.reachMediaServer(path: "/a2-break")
        let app = launch(videoPath: "/a2-flaky.mp4")

        waitForFeedRows(app)
        var retry = app.buttons["video.retry"].firstMatch
        for _ in 0..<12 where !retry.exists {
            list(app).swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.8)
            retry = app.buttons["video.retry"].firstMatch
        }
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "a 404 video never offered a retry")

        // The asset appears.
        Self.reachMediaServer(path: "/a2-heal")
        retry.tap()

        let recovered = waitForState(app, contains: "state=picture", timeout: 20)
        print("MEASURED state after retry: \(recovered)")
        XCTAssertTrue(
            recovered.contains("state=picture"),
            "retry did not rebuild anything: \(recovered)"
        )
        XCTAssertFalse(app.buttons["video.retry"].firstMatch.exists)

        // And it *plays*. A picture size only says the decoder opened the
        // track; clearing the error and showing a still frame would satisfy
        // everything above it. The boundary observer is reset by `retry`, so
        // this flag can only be true because the clock moved again after the
        // tap.
        let movingAgain = waitForState(app, contains: "advanced=true", timeout: 20)
        print("MEASURED state once the retried video is running: \(movingAgain)")
        XCTAssertTrue(
            movingAgain.contains("advanced=true"),
            "the retry cleared the error but nothing ever played: \(movingAgain)"
        )
        Self.reachMediaServer(path: "/a2-break")
    }

    // MARK: - A stream that breaks while it is playing

    /// **The defect, in the real interface.**
    ///
    /// `/a2-cutoff.mp4` delivers the index and the first third of the media
    /// data at a little over real time and then stops sending — without
    /// closing the socket, which is what keeps it a *stall* rather than a load
    /// error. The row therefore plays for a few seconds and then freezes on
    /// the frame it last decoded, with `AVPlayerItem` still `.readyToPlay`.
    /// Before this work that produced nothing at all: no message, no control,
    /// and a `state=picture playing=true` reading that a test would call
    /// healthy.
    ///
    /// Three separate claims, in order, because each can hold while the next
    /// fails: the row *was* playing, the picture then *stopped changing*, and
    /// the interface *says so and offers a way out*.
    func testAStreamThatBreaksMidPlaybackSaysSoAndOffersAWayOut() throws {
        Self.reachMediaServer(path: "/a2-cut")
        let app = launch(videoPath: "/a2-cutoff.mp4")

        // 1 — it really played.
        let playing = scrollToAPlayingVideo(app)
        XCTAssertTrue(playing.contains("playing=true"), "nothing ever played: \(playing)")
        let moving = waitForState(app, contains: "advanced=true", timeout: 30)
        XCTAssertTrue(moving.contains("advanced=true"), "the clock never moved: \(moving)")

        // 2 — and then the bytes ran out. Read from the row's own state rather
        //     than inferred from a frozen screenshot: "it looks the same" and
        //     "it is stalled" are different claims and this test needs both.
        let stalled = waitForState(app, contains: "phase=stalled", timeout: 40)
        XCTAssertTrue(
            stalled.contains("phase=stalled"),
            "the stream broke and the row never noticed: \(stalled)"
        )
        XCTAssertTrue(
            stalled.contains("state=picture"),
            "the frame it had decoded should still be on the glass: \(stalled)"
        )

        // 3 — the picture really is frozen. Two samples far enough apart that a
        //     playing clip would be a different colour in the second one: the
        //     fixture changes colour every second.
        // 4 — and the person is given something to press. This is the whole
        //     point: the old behaviour was a frozen frame with no control on it
        //     at all, which cannot be escaped without scrolling away.
        let recover = app.buttons["video.stalled.retry"].firstMatch
        XCTAssertTrue(
            recover.waitForExistence(timeout: 30),
            "a stream that has been dead for \(VideoStallUI.recoveryOfferDelay)s offered nothing to press"
        )

        // 3 — the picture really is frozen, asked **after** the button arrived.
        //
        // It used to be asked right after the row first said `phase=stalled`,
        // and it failed there for a reason that is not a frozen picture: an
        // automatic recovery seeks back up to
        // `VideoStallPolicy.recoverySeekToleranceBefore` seconds and replays
        // them, so the glass legitimately changes colour while the row is
        // still stalled. Guarding on the rebuild count was not enough either —
        // a rebuild that landed just *before* the first sample replays across
        // both of them without the count moving, which is what
        // `across rebuilds=1` in the failure output meant.
        //
        // Once the button is up, the automatic budget is spent by definition:
        // that is what `recoveryOfferDelay` and the bound together mean. So
        // nothing can rebuild, nothing can seek, and a picture that changes
        // now is a picture that changed on its own.
        if let surface = playingSurface(app),
           let first = Self.centreColour(of: surface.element, in: app) {
            let spent = Self.rebuilds(in: surface.state) ?? -1
            Thread.sleep(forTimeInterval: 1.4)
            if let second = Self.centreColour(of: surface.element, in: app) {
                print("MEASURED frozen frame after the offer: \(first) then \(second) "
                      + "(rebuilds spent=\(spent))")
                XCTAssertTrue(
                    first.isNear(second, tolerance: 0.15),
                    "the picture changed after automatic recovery was spent: \(first) then \(second)"
                )
            }
        }

        // Still the feed. A recovery control that navigated somewhere would
        // satisfy every reading above and be a worse bug than the one it fixes.
        XCTAssertTrue(app.navigationBars["PetNote"].exists, "the stall took the feed away")

        // 5 — the network comes back and the tap gets playback going again.
        Self.reachMediaServer(path: "/a2-mend")
        recover.tap()
        let recovered = waitForState(app, contains: "phase=playing", timeout: 40)
        print("MEASURED state after recovery: \(recovered)")
        XCTAssertTrue(
            recovered.contains("phase=playing"),
            "the way out did not lead anywhere: \(recovered)"
        )
        XCTAssertFalse(
            app.buttons["video.stalled.retry"].firstMatch.exists,
            "the recovery control outstayed the problem"
        )

        // §5D.4 survives the whole round trip: recovery rebuilds an item on the
        // same player, so the mute flag is never in a position to be lost — and
        // the speaker is the only thing that can prove it from out here.
        let mute = app.buttons["video.mute"].firstMatch
        if mute.waitForExistence(timeout: 10) {
            XCTAssertEqual(
                mute.label, "Unmute video",
                "recovering from a stall turned the sound on"
            )
        }
        Self.reachMediaServer(path: "/a2-cut")
    }

    /// **A video the person is not being shown must never complain.**
    ///
    /// Same dead stream, but the app goes to the background. Coming back is
    /// deliberately quiet (§5D.6), so the row is silent — and a silent row that
    /// has been told to be silent may not grow a spinner or a retry button,
    /// however dead the network underneath it is.
    func testABackgroundedAppNeverShowsAStalledVideoAnyTrouble() {
        Self.reachMediaServer(path: "/a2-cut")
        let app = launch(videoPath: "/a2-cutoff.mp4")
        let playing = scrollToAPlayingVideo(app)
        XCTAssertTrue(playing.contains("playing=true"), "nothing ever played: \(playing)")

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(app.navigationBars["PetNote"].waitForExistence(timeout: 20))

        // Long past every threshold, and nothing may have appeared.
        Thread.sleep(forTimeInterval: VideoStallUI.recoveryOfferDelay + 3)
        let readings = surfaces(app).map(\.state)
        print("MEASURED states after returning from the background: \(readings)")
        XCTAssertFalse(
            readings.contains(where: { $0.contains("phase=stalled") }),
            "a backgrounded app reported a stall: \(readings)"
        )
        XCTAssertFalse(
            app.buttons["video.stalled.retry"].firstMatch.exists,
            "a video nobody asked to play offered a recovery button"
        )
        Self.reachMediaServer(path: "/a2-cut")
    }

    // MARK: - Thirty videos, in a real list

    /// The ceiling and the accumulation question, asked of the real list.
    ///
    /// Every row is a video here (see `MediaView.everythingIsVideo`), because
    /// the seed puts six videos in 210 posts and reaching thirty of them would
    /// mean paging through most of the feed. That makes this a harder scroll
    /// than a real feed, not an easier one.
    ///
    /// An earlier version of this test flung the list, saw zero players the
    /// whole way, and passed — a flung list never lets a row settle above the
    /// visibility threshold, so nothing was created and nothing was tested. It
    /// now refuses to pass unless it actually saw thirty different videos take
    /// the screen.
    func testThirtyVideosInARealListNeverExceedTheCeiling() {
        let app = launch(everythingIsVideo: true)
        waitForFeedRows(app)

        var distinctPlayed = Set<String>()
        var peak = 0
        var readings: [String] = []

        for step in 0..<60 {
            let reading = probe(app)
            if !reading.isEmpty {
                readings.append(reading)
                peak = max(peak, Self.players(in: reading) ?? 0)
                if let id = Self.value(named: "playing", in: reading), id != "none" {
                    distinctPlayed.insert(id)
                }
            }
            if distinctPlayed.count >= 30 && step > 5 { break }
            list(app).swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.6)
        }

        print("MEASURED distinct videos that played during the scroll: \(distinctPlayed.count)")
        print("MEASURED peak live players: \(peak)")
        print("MEASURED last readings: \(readings.suffix(4).joined(separator: " | "))")

        XCTAssertGreaterThanOrEqual(
            distinctPlayed.count, 30,
            "only \(distinctPlayed.count) videos ever played, so thirty was never exercised"
        )
        XCTAssertLessThanOrEqual(peak, 2, "player count exceeded the ceiling during a real scroll")

        // Still on the feed, and it never left.
        //
        // This test was cited as the evidence that scrolling past videos does
        // not trigger navigation, and it asserted nothing of the kind — the
        // name and the two-minute runtime made it look like it did. Every
        // reading above is taken on the feed, so a stray push would have made
        // the probe unreadable rather than made this fail; the check has to be
        // explicit.
        XCTAssertTrue(
            app.navigationBars["PetNote"].exists,
            "scrolling navigated away from the feed"
        )
        XCTAssertFalse(
            app.navigationBars["Post"].exists,
            "a scroll opened a post"
        )
        XCTAssertFalse(
            app.textFields["composer.field"].exists,
            "a scroll landed on the detail screen"
        )
        XCTAssertLessThanOrEqual(
            Self.players(in: probe(app)) ?? 99, 2,
            "players left over after the scroll settled"
        )
    }

    /// Flinging must not spin up decoders either.
    ///
    /// Readings are taken after the scroll settles rather than mid-gesture:
    /// querying the accessibility tree while a list is still decelerating
    /// fails with "Error getting main window", which is a measurement problem
    /// and would otherwise be reported as a defect.
    func testFlingingPastVideosStaysWithinTheCeiling() {
        let app = launch(everythingIsVideo: true)
        waitForFeedRows(app)

        var peak = 0
        var readings: [String] = []
        for _ in 0..<6 {
            list(app).swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.8)
            let reading = probe(app)
            guard !reading.isEmpty else { continue }
            readings.append(reading)
            peak = max(peak, Self.players(in: reading) ?? 0)
        }
        print("MEASURED peak players while flinging: \(peak)")
        print("MEASURED readings: \(readings.prefix(4).joined(separator: " | "))")
        XCTAssertFalse(readings.isEmpty, "the probe was never readable")
        XCTAssertLessThanOrEqual(peak, 2)

        // A fast fling is the likeliest way to land a stray tap on a card, and
        // this test's name only ever promised the ceiling. Say the other half
        // out loud instead of leaving it to the reader: an accidental push
        // would make the probe unreadable, which fails above as "never
        // readable" — a confusing way to learn that navigation broke.
        XCTAssertTrue(app.navigationBars["PetNote"].exists,
                      "flinging navigated away from the feed")
        XCTAssertFalse(app.navigationBars["Post"].exists,
                       "a fling opened a post")
    }

    // MARK: - Detail, and back

    /// Opening a post and coming back must leave a feed that still plays.
    ///
    /// Navigating away releases every player (`SignedInView` calls
    /// `releaseAll`), so coming back is a rebuild, not a resume — and a
    /// rebuild is exactly where "playingID is claimed but nothing plays" used
    /// to strand the feed permanently.
    func testOpeningAPostAndComingBackLeavesTheFeedPlayingAgain() throws {
        let app = launch()
        XCTAssertTrue(scrollToAPlayingVideo(app).contains("playing=true"))
        let before = waitForState(app, contains: "advanced=true")
        XCTAssertTrue(before.contains("advanced=true"), before)

        // The id the coordinator is playing before we leave. Compared later,
        // because "a video plays again" and "the choice is being made again"
        // are different claims and only the second one is the requirement.
        let playingBefore = Self.value(named: "playing", in: probe(app))
        print("MEASURED playing before leaving: \(playingBefore ?? "none")")

        // Tapping the video row opens the post — `element.tap()`, which only
        // became possible once the row stopped being drawn by AVKit. See
        // `testTheVideoRowReportsTheRectangleItActuallyDrew`.
        let target = try XCTUnwrap(playingSurface(app)?.element)
        XCTAssertTrue(target.isHittable, "the video row is not tappable: frame \(target.frame)")
        target.tap()
        // The detail screen's own bar, by name. `app.navigationBars.buttons`
        // spans every bar in the tree and index 0 is whichever one it lists
        // first — the feed's bar is still underneath, and asking it whether a
        // button exists answers a question about the wrong screen. The same
        // query in SessionFlow picked the sign-out control and ended the
        // session mid-measurement.
        XCTAssertTrue(
            app.navigationBars["Post"].waitForExistence(timeout: 20),
            "the post never opened"
        )
        Thread.sleep(forTimeInterval: 2)
        // Scoped to the post's own bar, which is what the comment above says
        // and what the code did not do. `app.navigationBars.buttons` spans
        // every bar in the tree — the feed's is still mounted underneath —
        // and index 0 is whichever one the traversal lists first. The same
        // unscoped query in `SessionFlow` picked the sign-out control and
        // ended the session in the middle of a measurement.
        app.navigationBars["Post"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["PetNote"].waitForExistence(timeout: 20))

        let after = waitForState(app, contains: "advanced=true", timeout: 25)
        print("MEASURED state after returning from the post: \(after)")
        XCTAssertTrue(
            after.contains("state=picture") && after.contains("advanced=true"),
            "the feed came back stuck: \(after)"
        )
        let surface = try XCTUnwrap(playingSurface(app)?.element)
        let colour = try XCTUnwrap(Self.centreColour(of: surface, in: app))
        print("MEASURED colour after returning: \(colour)")
        XCTAssertTrue(
            Self.clipColours.contains { colour.isNear($0) },
            "nothing was drawn after coming back: \(colour)"
        )

        // **And the decision is working, not just playback.**
        //
        // A coordinator that came back playing the video it left on would pass
        // everything above and still be stuck in the way that matters: the
        // rule is "the eligible video nearest the middle plays", and a rule
        // that stopped being applied looks exactly like a rule that keeps
        // choosing the same answer. So scroll, and require the answer to
        // change to a different video.
        // Read through the navigation-bar probe rather than the rows: it is one
        // scoped query, where walking `video.surface` across a 210-row feed is
        // the unscoped kind that once turned a one-minute run into
        // twenty-two.
        //
        // **Thirty swipes, because the seed puts its videos at posts 2, 26,
        // 63, 117, 170 and 203.** The first version budgeted eight, never got
        // within twenty rows of the second video, and reported "the decision
        // is not being made any more" about a feed that had nothing else to
        // choose. The budget is a fixture fact, not a weaker claim — the
        // assertion below is still that a *different* video takes the screen.
        let resumed = Self.value(named: "playing", in: probe(app))
        print("MEASURED playing after returning: \(resumed ?? "none")")
        var moved: String?
        for _ in 0..<30 {
            list(app).swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.6)
            let now = Self.value(named: "playing", in: probe(app))
            if let now, now != "none", now != resumed { moved = now; break }
        }
        let chosenAfterScrolling = try XCTUnwrap(
            moved,
            "after coming back from the post, scrolling never handed the screen to a different "
                + "video — the decision is not being made any more. Still on: \(resumed ?? "none")"
        )
        print("MEASURED playing after scrolling on: \(chosenAfterScrolling)")
        let state = waitForState(app, contains: "advanced=true", timeout: 25)
        XCTAssertTrue(
            state.contains("advanced=true"),
            "the newly chosen video was picked but its clock never moved: \(state)"
        )
    }

    /// **The row's accessibility rectangle is the rectangle it drew.**
    ///
    /// It was not. SwiftUI's `VideoPlayer` is an `AVPlayerViewController`, and
    /// it published the aspect-*fill* rectangle of the clip rather than the
    /// one on screen: a 320x240 clip in a 402pt-wide row was reported 670pt
    /// wide starting at x = -134, hanging off both edges of a 402pt screen and
    /// below its bottom. The picture was drawn correctly and a finger landed
    /// on it, so it was invisible to everything except two things that matter
    /// — VoiceOver's focus rectangle for the row, and XCUITest, which calls an
    /// element shaped like that unhittable and refuses to tap it.
    ///
    /// The fix is `.contentShape(.accessibility, Rectangle())` on the row's
    /// surface in `VideoPlayerView`. Two better-looking theories were measured
    /// and thrown away first — it is not AVKit (the number was unchanged after
    /// this view stopped using `VideoPlayer` at all) and it is not the poster
    /// overflowing `scaledToFill` (unchanged after `.clipped()`). Measured
    /// before: (-134.0, 393.0, 670.0, 502.7). After: (0.0, 453.3, 402.0,
    /// 502.7), in a 402x874 window.
    func testTheVideoRowReportsTheRectangleItActuallyDrew() throws {
        let app = launch()
        XCTAssertTrue(scrollToAPlayingVideo(app).contains("playing=true"))
        XCTAssertTrue(waitForState(app, contains: "state=picture").contains("state=picture"))

        let surface = try XCTUnwrap(playingSurface(app)?.element)
        let frame = surface.frame
        let window = app.windows.firstMatch.frame
        print("MEASURED video.surface frame \(frame) in window \(window)")

        // Horizontal containment is the whole of the old defect: the reported
        // width was 1.67x the screen's, centred, so it overhung by 134pt each
        // side. One point of slack for rounding, no more.
        XCTAssertGreaterThanOrEqual(
            frame.minX, window.minX - 1,
            "the row claims to start off the left edge of the screen: \(frame)"
        )
        XCTAssertLessThanOrEqual(
            frame.maxX, window.maxX + 1,
            "the row claims to extend past the right edge of the screen: \(frame)"
        )
        XCTAssertLessThanOrEqual(
            frame.width, window.width + 1,
            "the row is reported wider than the screen: \(frame)"
        )
        // And it is a real target, which is what both VoiceOver and a tap need.
        XCTAssertTrue(surface.isHittable, "the video row is still not hittable: \(frame)")
        XCTAssertTrue(
            frame.height > 40,
            "the row reported a frame too short to be the media area: \(frame)"
        )
    }

    // MARK: - Buffering

    /// The condition the test below once failed on, made on purpose rather
    /// than waited for: a video still opening, parked with only part of it on
    /// screen. On CI the row stopped at 78%, and every later run stopped at
    /// 80% or more, so the path that accepts a lower stop had never run.
    ///
    /// The row is dragged — slowly, held, no fling — until 65–79% of it is in
    /// the window, cut at the bottom where it enters. What is recorded, not
    /// assumed: how much is on screen, whether the tab bar covers the middle
    /// square that is photographed, and the colour found there.
    func testThePosterIsReadWithTheVideoPartlyOffScreen() throws {
        let app = launch(videoPath: "/a2-slow.mp4")
        waitForFeedRows(app)
        let window = app.windows.firstMatch.frame

        // A video row just entering from the bottom — under half of it in
        // view, so no player has been given to it yet. Small held drags, not
        // swipes: a swipe coasts, and the first attempt overshot to 81%, where
        // the clip had already opened.
        func entering() -> XCUIElement? {
            surfaces(app).map(\.element).first { element in
                let frame = element.frame
                guard frame.height > 100, frame.minY < window.maxY, frame.maxY > window.maxY else { return false }
                return window.intersection(frame).height / frame.height < 0.5
            }
        }
        var target: XCUIElement?
        for _ in 0..<40 {
            target = entering()
            if target != nil { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        let row = try XCTUnwrap(target, "no video row came in from the bottom")

        // Park it with 65–79% on screen, in two steps. The slow clip keeps a
        // player without a picture for only a few seconds (1.5 s per request,
        // scripts/a2-media-server.py), and a player is given only at 60%
        // visibility (VideoPlaybackCoordinator.visibilityThreshold). So: first
        // to 40–58%, where nothing has started; then one short drag from
        // standing still to about 72%, which starts the opening, and look at
        // once. Measured before: parking in several drags took so long the
        // clip was already playing.
        func shownFraction() -> CGFloat {
            let frame = row.frame
            return frame.height > 0 ? window.intersection(frame).height / frame.height : 0
        }
        func drag(by distance: CGFloat, hold: TimeInterval) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                        withVelocity: .slow, thenHoldForDuration: hold)
        }
        var drags: [String] = [String(format: "%.0f%%", shownFraction() * 100)]
        for _ in 0..<5 where !(0.40...0.58).contains(shownFraction()) {
            drag(by: (0.5 - shownFraction()) * row.frame.height, hold: 0.3)
            drags.append(String(format: "%.0f%%", shownFraction() * 100))
        }
        guard (0.40...0.58).contains(shownFraction()) else {
            throw XCTSkip("could not stand the row at 40–58% first (\(drags.joined(separator: " → "))); nothing measured")
        }
        let staged = row.value as? String ?? ""
        drag(by: (0.72 - shownFraction()) * row.frame.height, hold: 0.5)
        let frame = row.frame
        var shown = shownFraction()
        drags.append(String(format: "%.0f%%", shown * 100))
        print("MEASURED partly-off-screen parking: \(drags.joined(separator: " → ")); before the last drag: \(staged)")
        guard (0.65...0.79).contains(shown) else {
            throw XCTSkip("the last drag ended at \(Int(shown * 100))%, outside 65–79%; nothing measured")
        }

        // What the photograph's middle square has over it.
        let middle = CGRect(x: frame.minX + frame.width * 0.3, y: frame.minY + frame.height * 0.3,
                            width: frame.width * 0.4, height: frame.height * 0.4)
        let tabBar = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame : .zero
        let covered = middle.intersection(tabBar).height
        print(String(format: "MEASURED middle square y=%.0f…%.0f, tab bar y=%.0f…, covered %.0fpt",
                     middle.minY, middle.maxY, tabBar.minY, max(0, covered)))

        // Opening, photographed while still opening.
        var colour: Sample?
        var states: [String] = []
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let state = row.value as? String ?? ""
            if states.last != state { states.append(state) }
            if state.contains("state=opening"),
               let sample = Self.centreColourOnScreen(of: row, in: app),
               (row.value as? String ?? "").contains("state=opening") {
                colour = sample
                break
            }
            if state.contains("state=picture") { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        print("MEASURED partly-off-screen states: \(states.joined(separator: " | "))")
        let sample = try XCTUnwrap(colour, "never photographed the row while opening; states: \(states.joined(separator: " | "))")
        print("MEASURED partly-off-screen colour: \(sample)")
        XCTAssertTrue(sample.isNear(Self.posterColour, tolerance: 0.3),
                      "a video still opening, \(Int(shown * 100))% on screen, drew something other than its poster: \(sample)")
    }

    /// While a video is opening, the poster stays up.
    ///
    /// `/a2-slow.mp4` makes the server wait before answering, so the state
    /// between "a player exists" and "there is a picture" lasts long enough to
    /// photograph. The claim is that this window shows the poster rather than
    /// a black rectangle — which is what a bare `VideoPlayer` draws before its
    /// first frame, and what the old view showed.
    func testWhileAVideoIsOpeningThePosterIsStillWhatIsOnScreen() throws {
        let app = launch(videoPath: "/a2-slow.mp4")
        waitForFeedRows(app)

        var openingColour: Sample?
        var sawOpening = false
        // What each glimpse of `opening` was, and why it did not count. The
        // run that failed (acc3, 2026-09-23) swiped twelve times and said only
        // "no screenshot"; whether the window was too short or the row was
        // never far enough on screen to photograph were indistinguishable.
        var glimpses: [String] = []
        let started = Date()
        outer: for swipe in 0..<12 {
            for _ in 0..<12 {
                let now = surfaces(app)
                if let opening = now.first(where: { $0.state.contains("state=opening") }) {
                    sawOpening = true
                    let frame = opening.element.frame
                    let window = app.windows.firstMatch.frame
                    let shown = frame.height > 0 ? window.intersection(frame).height / frame.height : 0
                    glimpses.append(String(
                        format: "t=%.1fs swipe=%d onScreen=%.0f%% h=%.0f",
                        Date().timeIntervalSince(started), swipe, shown * 100, frame.height
                    ))
                    // The sample only counts if the state is still `opening`
                    // *after* the photograph is taken.
                    //
                    // Detecting the state and photographing it are two
                    // moments. Requiring only that the picture exists was not
                    // enough: run on its own the window was wide and this
                    // passed, run in the full suite the asset was warm and the
                    // photograph came back as the clip's first frame — a red
                    // that says nothing about the poster, from a moment when
                    // the state had already moved on.
                    if let colour = Self.centreColourOnScreen(of: opening.element, in: app),
                       surfaces(app).contains(where: {
                           $0.state.contains("state=opening")
                       }) {
                        openingColour = colour
                        break outer
                    }
                }
                if now.contains(where: { $0.state.contains("state=picture") }) { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            list(app).swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.5)
        }

        print("MEASURED opening glimpses: \(glimpses.isEmpty ? "none" : glimpses.joined(separator: " | "))")
        XCTAssertTrue(sawOpening, "never caught a video between having a player and having a picture")
        let colour = try XCTUnwrap(
            openingColour,
            "no screenshot of the opening state; glimpses: \(glimpses.joined(separator: " | "))"
        )
        print("MEASURED colour while opening: \(colour)")
        XCTAssertTrue(
            colour.isNear(Self.posterColour, tolerance: 0.3),
            "a video that is still opening drew something other than its poster: \(colour)"
        )
        XCTAssertGreaterThan(colour.r + colour.g + colour.b, 0.5, "it drew black")

        // And it does get there.
        let eventually = waitForState(app, contains: "state=picture", timeout: 30)
        XCTAssertTrue(eventually.contains("state=picture"), "the slow video never opened: \(eventually)")
    }

    // MARK: - Reading the screen

    /// The colour of the middle of what an element actually drew.
    ///
    /// The **middle**, and that is the whole trick. Two measurements were
    /// thrown away before this one:
    ///
    ///   - averaging the entire element mixed the picture with the letterbox.
    ///     A 4:3 clip inside a 4:5 row is 40% black bars, so a blue frame
    ///     measured as dark navy and matched nothing;
    ///   - screenshotting a row that was in the hierarchy but below the fold
    ///     returned a black image, which looked exactly like "it drew black"
    ///     and was really "it drew nothing anyone could see".
    ///
    /// So: only rows that are actually on screen, and only the central 40%,
    /// which the picture always covers under aspect-fit.
    /// The middle of `element`, read from a photograph of the whole screen.
    ///
    /// The same square `centreColour` samples — 30% to 70% of the element
    /// each way — but it only needs *that square* on screen, not 80% of the
    /// row. Written for the opening test, whose glimpses of `opening` all came
    /// right after the second swipe with the row 78–85% on screen: a stop at
    /// 78% refused the photograph although the middle was in full view, and
    /// that alone decided whether the test passed (measured 2026-09-23, six
    /// iterations, the fourth failing at 78%).
    private static func centreColourOnScreen(of element: XCUIElement, in app: XCUIApplication) -> Sample? {
        guard element.exists else { return nil }
        let frame = element.frame
        guard frame.height > 40 else { return nil }
        let middle = CGRect(
            x: frame.minX + frame.width * 0.3, y: frame.minY + frame.height * 0.3,
            width: frame.width * 0.4, height: frame.height * 0.4
        )
        let window = app.windows.firstMatch.frame
        guard window.width > 0 else { return nil }
        // Only what is actually seen: the window less the bars drawn over
        // it. "The square is inside the window" was not enough — parked 74%
        // on screen, 63pt of a 201pt square sat under the tab bar
        // (testThePosterIsReadWithTheVideoPartlyOffScreen, 2026-09-23), and a
        // photograph there is partly of the tab bar. The square itself stays
        // the middle of the element, inside the picture under aspect-fit.
        var uncovered = window
        for bar in [app.navigationBars.firstMatch, app.tabBars.firstMatch] where bar.exists {
            let edge = bar.frame
            guard edge.intersects(uncovered) else { continue }
            if edge.midY > window.midY {
                uncovered.size.height = max(0, edge.minY - uncovered.minY)
            } else {
                let top = max(uncovered.minY, edge.maxY)
                uncovered.size.height = max(0, uncovered.maxY - top)
                uncovered.origin.y = top
            }
        }
        let seen = middle.intersection(uncovered)
        guard !seen.isNull, seen.width > 0, seen.height >= frame.height * 0.15 else {
            print("MEASURED sample refused: frame=\(frame) uncovered=\(uncovered) seen=\(seen) "
                  + "nav=\(app.navigationBars.firstMatch.exists ? "\(app.navigationBars.firstMatch.frame)" : "-") "
                  + "tab=\(app.tabBars.firstMatch.exists ? "\(app.tabBars.firstMatch.frame)" : "-")")
            return nil
        }
        guard let full = XCUIScreen.main.screenshot().image.cgImage else { return nil }
        let scale = CGFloat(full.width) / window.width
        let pixels = CGRect(
            x: seen.minX * scale, y: seen.minY * scale,
            width: seen.width * scale, height: seen.height * scale
        ).integral
        guard let cropped = full.cropping(to: pixels) else { return nil }
        return average(of: cropped)
    }

    private static func average(of image: CGImage) -> Sample? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Sample(
            r: Double(pixel[0]) / 255, g: Double(pixel[1]) / 255, b: Double(pixel[2]) / 255
        )
    }

    private static func centreColour(of element: XCUIElement, in app: XCUIApplication) -> Sample? {
        guard element.exists else { return nil }
        let frame = element.frame
        let window = app.windows.firstMatch.frame
        guard frame.height > 40 else { return nil }
        let visible = window.intersection(frame)
        guard visible.height > frame.height * 0.8 else { return nil }

        guard let full = element.screenshot().image.cgImage else { return nil }
        let width = CGFloat(full.width), height = CGFloat(full.height)
        let middle = CGRect(x: width * 0.3, y: height * 0.3, width: width * 0.4, height: height * 0.4)
        guard let cropped = full.cropping(to: middle) else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Sample(
            r: Double(pixel[0]) / 255, g: Double(pixel[1]) / 255, b: Double(pixel[2]) / 255
        )
    }

    /// Talks to the media server from inside the test process, which is how a
    /// broken asset can be made to come back at a moment the test chooses.
    private static func reachMediaServer(path: String) {
        guard let url = URL(string: mediaHost + path) else { return }
        let waited = XCTestExpectation(description: "media server \(path)")
        URLSession.shared.dataTask(with: url) { _, _, _ in waited.fulfill() }.resume()
        _ = XCTWaiter.wait(for: [waited], timeout: 5)
    }

    private static func players(in reading: String) -> Int? {
        value(named: "players", in: reading).flatMap(Int.init)
    }

    private static func value(named key: String, in reading: String) -> String? {
        reading.split(separator: " ")
            .first { $0.hasPrefix("\(key)=") }
            .map { String($0.dropFirst(key.count + 1)) }
    }
}

/// One measured colour.
struct Sample: CustomStringConvertible {
    let r: Double
    let g: Double
    let b: Double

    /// Generous by default: a screenshot is JPEG-ish, H.264 stores 4:2:0 YUV,
    /// and a white bar crosses every frame on purpose. The colours being told
    /// apart are far further apart than this.
    func isNear(_ other: Sample, tolerance: Double = 0.22) -> Bool {
        abs(r - other.r) < tolerance && abs(g - other.g) < tolerance && abs(b - other.b) < tolerance
    }

    var description: String { String(format: "(r %.2f g %.2f b %.2f)", r, g, b) }
}

/// The one wait from `VideoStallPolicy` that a UI test needs to know.
///
/// Restated rather than imported: a UI test bundle does not link the app, so
/// `VideoStallPolicy` is not reachable from here. Kept to the single number the
/// tests actually wait on, with the source named, so the duplication is one
/// obvious line rather than a second scattered set of timings.
enum VideoStallUI {
    /// Mirrors `VideoStallPolicy.recoveryOfferDelay` in
    /// ios-native/Core/Media/VideoPlaybackCoordinator.swift.
    static let recoveryOfferDelay: TimeInterval = 10
}
