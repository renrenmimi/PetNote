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

    // MARK: - Leaving, coming back

    func testScrollingAwayStopsPlaybackAndReleasesThePlayer() {
        let app = launch()
        let state = scrollToAPlayingVideo(app)
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
    func testBackgroundingStopsPlaybackAndReturningIsQuietUntilAScroll() {
        let app = launch()
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
        Self.reachMediaServer(path: "/a2-break")
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

        // In the feed, tapping the card's content — including the video —
        // opens the post.
        try XCTUnwrap(playingSurface(app)?.element).tap()
        XCTAssertTrue(
            app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 20),
            "the post never opened"
        )
        Thread.sleep(forTimeInterval: 2)
        app.navigationBars.buttons.element(boundBy: 0).tap()
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
    }

    // MARK: - Buffering

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
        outer: for _ in 0..<12 {
            for _ in 0..<12 {
                let now = surfaces(app)
                if let opening = now.first(where: { $0.state.contains("state=opening") }) {
                    sawOpening = true
                    openingColour = Self.centreColour(of: opening.element, in: app)
                    break outer
                }
                if now.contains(where: { $0.state.contains("state=picture") }) { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            list(app).swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.5)
        }

        XCTAssertTrue(sawOpening, "never caught a video between having a player and having a picture")
        let colour = try XCTUnwrap(openingColour, "no screenshot of the opening state")
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
