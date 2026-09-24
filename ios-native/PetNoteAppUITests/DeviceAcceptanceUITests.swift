import XCTest

/// The core path, on a real phone, against the independent test project.
///
/// Split deliberately: this drives the interface and reads what the interface
/// says. It never talks to a backend, because the phone cannot reach the
/// emulator and has no business holding cloud credentials. The other half —
/// whether the documents really changed — is checked from the Mac against
/// petnote-devtest, using the identifiers this prints.
///
/// So every assertion here is about what a person would see, and the numbers
/// it prints are what makes the backend check possible.
final class DeviceAcceptanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // These assert things that are only true on a phone pointed at
        // petnote-devtest: the badge naming that project, a video fetched
        // over the public internet. Run on a simulator against the emulator
        // they fail for the environment, which is noise dressed as a defect.
        //
        // A compile-time check rather than a runtime guess: the UI test
        // bundle is built for whichever destination it runs on.
        #if targetEnvironment(simulator)
        throw XCTSkip("device acceptance — runs against a phone on petnote-devtest")
        #endif
    }

    private func launch(signedOut: Bool = true, probe: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var args = signedOut ? ["-petnote-start-signed-out"] : []
        // Without this the surface's accessibility value is the empty string —
        // deliberately, so VoiceOver never reads "state=picture playing=true"
        // aloud. A run that forgets it sees no state anywhere and reports that
        // no video ever had a picture, which is a statement about the probe.
        if probe { args.append("-petnote-video-probe") }
        app.launchArguments = args
        app.launch()
        return app
    }

    /// Before anything else: is this build talking to the project it claims?
    ///
    /// A screenshot of a feed looks the same whichever backend produced it, so
    /// this is the assertion the rest of the run depends on. If the badge said
    /// production, everything below would be evidence about the wrong system.
    func test1TheAppOnThisPhoneIsTalkingToTheTestProject() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 60),
                      "sign-in never appeared\n\(app.debugDescription)")
        typeCredentialsAndSubmit(app)
        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 90),
                      "never reached the feed")

        let badge = app.staticTexts["env.badge"]
        XCTAssertTrue(waitForExistence(of: badge, in: app, timeout: 30), "no environment badge")
        print("MEASURED device badge: \(badge.label)")
        XCTAssertTrue(badge.label.contains("petnote-devtest"),
                      "this build is not on the test project: \(badge.label)")
        XCTAssertTrue(badge.label.uppercased().contains("TESTCLOUD"),
                      "backend is not testcloud: \(badge.label)")
        XCTAssertFalse(badge.label.contains("petnote-a9dac"), "PRODUCTION: \(badge.label)")
    }

    func test2TheFeedLoadsOnTheDevice() {
        let app = signedInApp()
        let posts = app.staticTexts.matching(identifier: "post.text")
        XCTAssertTrue(posts.firstMatch.waitForExistence(timeout: 90), "the feed never loaded")
        print("MEASURED first post: \(posts.firstMatch.label.prefix(60))")
        XCTAssertGreaterThan(posts.count, 0)
    }

    /// The identifier is printed so the Mac can ask the test project whether
    /// the like document and the aggregate really moved.
    func test3LikingAPostOnTheDevice() {
        let app = signedInApp()
        let first = app.staticTexts.matching(identifier: "post.text").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 90))
        print("MEASURED liking the post whose text is: \(first.label)")

        // Brought up rather than waited for: the feed's banner and spotlight
        // rows sit above the first card, and on a phone its actions row
        // starts under the tab bar.
        let like = app.buttons.matching(identifier: "post.like").firstMatch
        XCTAssertTrue(bringIntoReach(like, in: app, timeout: 60), "like is not tappable")
        let before = like.label
        let beforeValue = like.value as? String ?? "?"
        like.tap()
        let flipped = waitForPredicate(on: like, format: "label != %@", before, timeout: 30)
        print("MEASURED like: \(before)/\(beforeValue) -> \(like.label)/\(like.value as? String ?? "?")")
        XCTAssertTrue(flipped, "the heart never changed")
    }

    func test4CommentingOnTheDevice() {
        let app = signedInApp()
        let first = app.staticTexts.matching(identifier: "post.text").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 90))
        print("MEASURED commenting on the post whose text is: \(first.label)")

        let comments = app.buttons.matching(identifier: "post.comments").firstMatch
        XCTAssertTrue(bringIntoReach(comments, in: app, timeout: 60), "comments is not tappable")
        comments.tap()

        let field = app.textFields["composer.field"]
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 60), "no composer")
        // ASCII on purpose: raising a Chinese keyboard is one of the things a
        // program cannot do, and it is on the list for a person.
        let text = "TEST CONTENT device check \(Int(Date().timeIntervalSince1970))"
        field.tap()
        field.typeText(text)
        print("MEASURED comment text: \(text)")
        app.buttons["composer.send"].tap()

        let posted = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(waitForExistence(of: posted, in: app, timeout: 60),
                      "the comment never appeared on screen")
    }

    func test5AVideoPlaysOnTheDevice() {
        let app = launch(probe: true)
        if app.staticTexts["login.title"].waitForExistence(timeout: 60) { typeCredentialsAndSubmit(app) }
        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 90))
        XCTAssertTrue(app.staticTexts.matching(identifier: "post.text").firstMatch
                        .waitForExistence(timeout: 90))

        // Which rows were actually looked at, not how many times the screen
        // was swiped. "Thirty swipes" says nothing about whether a video was
        // ever on screen.
        var seen: [String: String] = [:]
        var best = "none"
        for step in 0..<40 {
            let surfaces = app.otherElements.matching(identifier: "video.surface")
            for i in 0..<surfaces.count {
                let s = surfaces.element(boundBy: i)
                guard s.exists, !s.frame.isEmpty else { continue }
                let state = s.value as? String ?? ""
                let key = "\(Int(s.frame.minY))@step\(step)"
                seen[key] = state.isEmpty ? "(empty value — probe off?)" : state
                if state.contains("state=picture") { best = state }
            }
            if best.contains("state=picture") { break }
            app.swipeUp()
        }

        print("MEASURED video rows that entered view: \(seen.count)")
        for (k, v) in seen.sorted(by: { $0.key < $1.key }).prefix(12) {
            print("MEASURED   \(k) -> \(v)")
        }
        print("MEASURED best video state on device: \(best)")

        XCTAssertFalse(seen.isEmpty, "no video row ever entered view — this says nothing about playback")
        XCTAssertTrue(best.contains("state=picture"), "a video was on screen but never drew: \(best)")
        XCTAssertTrue(best.contains("advanced=true"), "a picture is on screen but the clock never moved: \(best)")
    }

    // MARK: -

    private func signedInApp() -> XCUIApplication {
        let app = launch()
        if app.staticTexts["login.title"].waitForExistence(timeout: 60) { typeCredentialsAndSubmit(app) }
        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 90))
        return app
    }

    /// Types the credentials and submits. Deliberately checks nothing — every
    /// caller asserts the feed appeared on the next line, with a device-sized
    /// timeout of its own.
    ///
    /// Not called `signIn`: that name belongs to `SessionFlow.signIn`, which
    /// asserts it reached the feed. Two helpers with one name and opposite
    /// failure semantics is how a test that checks nothing gets read as one
    /// that does.
    private func typeCredentialsAndSubmit(_ app: XCUIApplication) {
        let email = app.textFields["login.email"]
        email.tap(); email.typeText("accept-a@example.com")
        let password = app.secureTextFields["login.password"]
        password.tap(); password.typeText("Passw0rd!x")
        app.buttons["login.submit"].tap()
    }

    private func waitForPredicate(
        on element: XCUIElement, format: String, _ args: CVarArg..., timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSPredicate(format: format, arguments: getVaList(args)).evaluate(with: element) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }
}

extension DeviceAcceptanceUITests {
    /// The defect the owner found on their phone: comment posted, detail
    /// screen showed it, server said 1, feed still read "0 comments".
    ///
    /// Checked on the feed rather than in the detail view, because the detail
    /// view was never wrong — it was the screen underneath that had a snapshot
    /// taken before the comment existed.
    func test6CommentCountIsRightOnTheFeedAfterComingBack() {
        let app = launch()
        if app.staticTexts["login.title"].waitForExistence(timeout: 60) { typeCredentialsAndSubmit(app) }
        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 90))

        let first = app.staticTexts.matching(identifier: "post.text").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 90))
        let postText = first.label

        let commentsButton = app.buttons.matching(identifier: "post.comments").firstMatch
        XCTAssertTrue(bringIntoReach(commentsButton, in: app, timeout: 60), "comments is not tappable")
        let before = Int(commentsButton.value as? String ?? "") ?? -1
        print("MEASURED feed comment count before: \(before) on \(postText)")
        XCTAssertGreaterThanOrEqual(before, 0, "could not read the feed's comment count")

        commentsButton.tap()
        let field = app.textFields["composer.field"]
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 60))
        let text = "TEST CONTENT count sync \(Int(Date().timeIntervalSince1970))"
        field.tap(); field.typeText(text)
        app.buttons["composer.send"].tap()
        XCTAssertTrue(
            waitForExistence(
                of: app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch,
                in: app, timeout: 60
            ),
            "the comment never appeared on the detail screen"
        )

        // Back the way a person goes back.
        let bar = app.navigationBars.allElementsBoundByIndex
            .filter { $0.exists && $0.identifier != "PetNote" && !$0.frame.isEmpty }.first
        let back = bar?.buttons.allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty }
            .min { $0.frame.minX < $1.frame.minX }
        XCTAssertNotNil(back, "no back button")
        back?.tap()
        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 60))

        // No refresh, no wait: the number has to be right on arrival.
        let after = app.buttons.matching(identifier: "post.comments").firstMatch
        XCTAssertTrue(bringIntoReach(after, in: app, timeout: 30), "comments is not tappable after coming back")
        let shown = Int(after.value as? String ?? "") ?? -1
        print("MEASURED feed comment count after returning: \(shown)")
        XCTAssertEqual(shown, before + 1, "the feed did not pick up the comment that was just written")

        // And when the trigger's number arrives it must not be added twice.
        pullToRefreshOnDevice(app)
        let settled = Int(app.buttons.matching(identifier: "post.comments").firstMatch.value as? String ?? "") ?? -1
        print("MEASURED feed comment count after a refresh: \(settled)")
        XCTAssertEqual(settled, before + 1, "the count moved again after the aggregate landed")
    }

    private func pullToRefreshOnDevice(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.8)
        waitForQuietUI(app, quietFor: 1, timeout: 30)
    }

    /// The second half of the same defect, found after the first was fixed:
    /// the number beside the post on the *detail* screen did not move either.
    func test7CommentCountIsRightOnTheDetailScreenItself() {
        let app = launch()
        if app.staticTexts["login.title"].waitForExistence(timeout: 60) { typeCredentialsAndSubmit(app) }
        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 90))
        XCTAssertTrue(app.staticTexts.matching(identifier: "post.text").firstMatch
                        .waitForExistence(timeout: 90))

        let open = app.buttons.matching(identifier: "post.comments").firstMatch
        XCTAssertTrue(bringIntoReach(open, in: app, timeout: 60), "comments is not tappable")
        open.tap()

        // How many of these are on screen at all, and where.
        //
        // A pushed screen does not remove the one underneath from the
        // hierarchy, so `firstMatch` can be the feed's card rather than the
        // detail's — the same "the query reaches further than intended"
        // mistake that has now been made in four different files here.
        XCTAssertTrue(app.textFields["composer.field"].waitForExistence(timeout: 60),
                      "never reached the detail screen")
        let all = app.buttons.matching(identifier: "post.comments").allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty }
        for (i, b) in all.enumerated() {
            print("MEASURED post.comments[\(i)] frame=\(b.frame) value=\(b.value as? String ?? "?")")
        }
        let window = app.windows.firstMatch.frame
        let detailCount = all.first { window.intersects($0.frame) } ?? all.first
        XCTAssertNotNil(detailCount, "no comments control on the detail screen")
        let before = Int(detailCount?.value as? String ?? "") ?? -1
        print("MEASURED detail comment count before: \(before)")
        XCTAssertGreaterThanOrEqual(before, 0)

        let field = app.textFields["composer.field"]
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 60))
        let text = "TEST CONTENT detail sync \(Int(Date().timeIntervalSince1970))"
        field.tap(); field.typeText(text)
        app.buttons["composer.send"].tap()
        XCTAssertTrue(
            waitForExistence(
                of: app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch,
                in: app, timeout: 60
            ),
            "the comment never appeared in the list"
        )

        // Read it repeatedly rather than once. "It did not move" and "it had
        // not moved yet when I looked" are different findings and a single
        // read cannot tell them apart.
        var readings: [Int] = []
        for _ in 0..<12 {
            readings.append(Int(detailCount?.value as? String ?? "") ?? -1)
            Thread.sleep(forTimeInterval: 0.5)
        }
        print("MEASURED detail count over 6s: \(readings.map(String.init).joined(separator: ","))")
        let after = readings.last ?? -1
        XCTAssertEqual(after, before + 1,
                       "the comment is in the list but the count beside the post did not move")
    }
}
