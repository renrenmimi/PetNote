import XCTest

/// What a 44pt touch target actually is, measured rather than asserted from
/// documentation.
///
/// Three different numbers get confused here, and only one of them is the
/// requirement:
///
///   1. **Accessibility frame** — what `XCUIElement.frame` reports. It is what
///      VoiceOver draws its cursor around.
///   2. **Visual size** — what is drawn. Not directly readable from a test.
///   3. **Hit region** — where a tap actually activates the control. This is
///      what HIG's 44×44 is about, and what these tests probe.
///
/// `isHittable` only says the element's *centre* can be tapped, so it cannot
/// distinguish a 20pt control from a 44pt one. The probe here taps at measured
/// offsets from the centre and checks whether the control responded, which is
/// the only way to learn the hit region's real extent from outside the app.
///
/// **One side is not a size.** An earlier round measured only "22pt above the
/// centre activates" and reported a 44pt-tall target. That does not follow: a
/// region can extend 22pt up and 6pt down. Every measurement here sweeps a
/// ladder of distances in **all four directions** and reports the largest
/// distance that still activated, per direction.
///
/// **A probe that always says yes measures nothing.** Each sweep is paired with
/// offsets that are known to be outside the control, and the run is only
/// meaningful if those come back negative. The outcome is three-way rather than
/// a boolean — *this control fired*, *something else fired*, *nothing happened*
/// — because "the tap landed on the card behind the button and opened the post"
/// and "the tap did nothing" are different facts, and a boolean loses the one
/// that proves the coordinates were real.
final class TouchTargetUITests: XCTestCase {
    override func setUp() {
        // These are measurements. A failed probe in one direction must not
        // throw away the other three.
        continueAfterFailure = true
    }

    // MARK: - Outcomes

    private enum Outcome: String {
        /// The control being probed activated.
        case activated
        /// A different control activated — proof the tap landed somewhere real.
        case somethingElse
        /// The tap landed and nothing observable happened.
        case nothing
        /// The point is outside the window, so it cannot be tapped at all. Not
        /// a measurement — a limit of the screen.
        case offWindow
    }

    private struct Direction {
        let name: String
        let dx: CGFloat
        let dy: CGFloat
    }

    private static let directions = [
        Direction(name: "up", dx: 0, dy: -1),
        Direction(name: "down", dx: 0, dy: 1),
        Direction(name: "left", dx: -1, dy: 0),
        Direction(name: "right", dx: 1, dy: 0),
    ]

    /// Distances swept, in points from the centre. 22 is the edge of a 44pt
    /// box; the values either side of it are what tell a 44pt region from a
    /// 36pt one or a 60pt one.
    private static let ladder: [CGFloat] = [10, 16, 20, 22, 24, 28, 34, 40]

    // MARK: - App

    /// `XCUIApplication()` cannot be a default argument here: constructing one
    /// is main-actor isolated and a default value is evaluated outside that
    /// context. Callers that need to relaunch the same instance pass it in.
    private func signedIn() -> XCUIApplication {
        signedIn(XCUIApplication())
    }

    /// accept-**b**, not accept-a. Four agents share one emulator and the like
    /// suites all drive accept-a; using a different account keeps this suite's
    /// like documents out of theirs, and keeps theirs out of these readings.
    @discardableResult
    private func signedIn(_ app: XCUIApplication) -> XCUIApplication {
        app.launchArguments = ["-petnote-start-signed-out"]
        app.launch()
        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 15))
        let email = app.textFields["login.email"]
        email.tap(); email.typeText("accept-b@example.com")
        let password = app.secureTextFields["login.password"]
        password.tap(); password.typeText("Passw0rd!x")
        app.buttons["login.submit"].tap()
        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 40))
        waitForQuietUI(app)
        return app
    }

    /// An absolute point `dx`/`dy` points from an element's centre.
    ///
    /// `withOffset` on the centre coordinate, not a normalised vector: the
    /// normalised form divides by the element's own height, so the same written
    /// offset means a different distance on a 36pt control than on a 44pt one —
    /// which is precisely the variable under study.
    private func point(from element: XCUIElement, dx: CGFloat, dy: CGFloat) -> XCUICoordinate {
        element
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: dx, dy: dy))
    }

    private func isInsideWindow(_ coordinate: XCUICoordinate, _ app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch.frame
        // Two points of margin: a tap exactly on the boundary is delivered to
        // the window but is not a useful measurement of anything.
        return coordinate.screenPoint.x > window.minX + 2
            && coordinate.screenPoint.x < window.maxX - 2
            && coordinate.screenPoint.y > window.minY + 2
            && coordinate.screenPoint.y < window.maxY - 2
    }

    // MARK: - Probe 1: the like button (our own layout, 44pt by construction)

    /// Taps `dx`/`dy` from the like button's centre and classifies what happened.
    ///
    /// The signal is the **label** — Like ⇄ Unlike — not the value. The value is
    /// "N likes", an aggregate that another signed-in client can move while this
    /// test is running, and this suite shares one emulator with three others.
    /// The label is this account's own like state, so it only changes because
    /// this test tapped something. The value is printed alongside so a
    /// surprising reading can be explained rather than guessed at.
    ///
    /// What is being measured here is whether the *tap reached the control*, and
    /// the optimistic flip is exactly that signal; whether the write then
    /// reached the server is a different question, checked against Firestore
    /// separately.
    private func probeLike(_ app: XCUIApplication, dx: CGFloat, dy: CGFloat) -> Outcome {
        let like = app.buttons.matching(identifier: "post.like").firstMatch
        guard like.waitForExistence(timeout: 20) else { return .nothing }
        let beforeLabel = like.label
        let beforeValue = like.value as? String ?? "?"

        let target = point(from: like, dx: dx, dy: dy)
        guard isInsideWindow(target, app) else { return .offWindow }
        target.tap()
        Thread.sleep(forTimeInterval: 2.0)

        // Did the tap open the post instead? That is the card's own gesture,
        // and it is the thing directly above and below the actions row.
        if app.navigationBars["Post"].exists {
            app.navigationBars["Post"].buttons.element(boundBy: 0).tap()
            _ = waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 20)
            Thread.sleep(forTimeInterval: 1.0)
            return .somethingElse
        }
        let after = app.buttons.matching(identifier: "post.like").firstMatch
        let afterLabel = after.label
        print("MEASURED   label \(beforeLabel)->\(afterLabel) value \(beforeValue)->\(after.value as? String ?? "?")")
        return afterLabel == beforeLabel ? .nothing : .activated
    }

    /// The full four-direction sweep on a control whose geometry we own.
    ///
    /// This is the control group for everything else in this file: if the probe
    /// cannot tell inside from outside on a button that is 44pt by construction,
    /// no reading it gives for a navigation-bar item means anything.
    func testLikeButtonHitRegionInAllFourDirections() {
        let app = signedIn()
        let like = app.buttons.matching(identifier: "post.like").firstMatch
        XCTAssertTrue(waitUntilHittable(like, in: app, timeout: 30))
        let frame = like.frame
        print("MEASURED like button accessibility frame: \(frame.size)")

        var reach: [String: CGFloat] = [:]
        var negatives = 0

        for direction in Self.directions {
            var lastActivated: CGFloat = 0
            for distance in Self.ladder {
                let outcome = probeLike(app, dx: direction.dx * distance, dy: direction.dy * distance)
                print("MEASURED like \(direction.name) \(Int(distance))pt -> \(outcome.rawValue)")
                switch outcome {
                case .activated:
                    lastActivated = max(lastActivated, distance)
                case .nothing, .somethingElse:
                    negatives += 1
                case .offWindow:
                    break
                }
            }
            reach[direction.name] = lastActivated
            print("MEASURED like REACH \(direction.name) = \(lastActivated)pt")
        }

        print("MEASURED like SUMMARY up=\(reach["up"] ?? -1) down=\(reach["down"] ?? -1) "
              + "left=\(reach["left"] ?? -1) right=\(reach["right"] ?? -1) frame=\(frame.size)")

        // The control group, stated as an assertion rather than left to the
        // reader: a probe that activates at every distance in every direction
        // has not measured a hit region, it has found a screen that swallows
        // taps. At least one ladder rung must come back negative.
        XCTAssertGreaterThan(
            negatives, 0,
            "every probe activated the control — the probe cannot tell inside from outside"
        )
        // And it must activate somewhere, or it is measuring a dead button.
        XCTAssertGreaterThan(
            (reach.values.max() ?? 0), 0,
            "no probe activated the control in any direction"
        )
    }

    // MARK: - Probe 2: a navigation-bar item (UIKit's layout, 36pt frame)

    /// Opens the first post, so the navigation bar has a back button in it.
    private func openDetail(_ app: XCUIApplication) -> Bool {
        let comments = app.buttons.matching(identifier: "post.comments").firstMatch
        guard waitUntilHittable(comments, in: app, timeout: 30) else { return false }
        comments.tap()
        return waitForExistence(of: app.navigationBars["Post"], in: app, timeout: 30)
    }

    /// Probes the navigation bar's **back** button rather than sign-out.
    ///
    /// Recoverable, where a sweep that signs out and back in for every rung is
    /// 32 sign-ins.
    ///
    /// **The numbers do not transfer, and this comment used to claim they
    /// did.** It said "same bar, same UIKit layout, same 36pt label", and
    /// `HitRegionBoundaryUITests` has since measured all three clauses wrong:
    /// the back button reports a 44.165x44.060 frame, not 36pt; it is
    /// synthesised by UIKit's navigation controller rather than declared as a
    /// `ToolbarItem` the way sign-out is; and at y=105.875 the back button
    /// activates while sign-out does not. Sharing a bar is not sharing a hit
    /// region. Each control's verdict rests on its own measurement.
    private func probeBack(_ app: XCUIApplication, dx: CGFloat, dy: CGFloat) -> Outcome {
        let bar = app.navigationBars["Post"]
        guard bar.waitForExistence(timeout: 20) else { return .nothing }
        let back = bar.buttons.element(boundBy: 0)
        guard back.exists else { return .nothing }

        let target = point(from: back, dx: dx, dy: dy)
        guard isInsideWindow(target, app) else { return .offWindow }
        target.tap()
        Thread.sleep(forTimeInterval: 1.5)

        if app.navigationBars["PetNote"].exists && !app.navigationBars["Post"].exists {
            // Popped. Go back in for the next rung.
            _ = openDetail(app)
            return .activated
        }
        if app.images["image.full"].exists || app.buttons["full.close"].exists {
            return .somethingElse
        }
        return .nothing
    }

    func testNavigationBarBackButtonHitRegionInAllFourDirections() {
        let app = signedIn()
        XCTAssertTrue(openDetail(app), "could not open a post")
        let bar = app.navigationBars["Post"]
        let back = bar.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 20))
        print("MEASURED nav bar frame: \(bar.frame), back button frame: \(back.frame)")

        var reach: [String: CGFloat] = [:]
        var negatives = 0
        var unreachable: [String] = []

        for direction in Self.directions {
            var lastActivated: CGFloat = 0
            for distance in Self.ladder {
                let outcome = probeBack(app, dx: direction.dx * distance, dy: direction.dy * distance)
                print("MEASURED back \(direction.name) \(Int(distance))pt -> \(outcome.rawValue)")
                switch outcome {
                case .activated: lastActivated = max(lastActivated, distance)
                case .nothing, .somethingElse: negatives += 1
                case .offWindow: unreachable.append("\(direction.name)@\(Int(distance))")
                }
                // A rung that popped the screen needs the detail view back.
                if !app.navigationBars["Post"].exists { _ = openDetail(app) }
            }
            reach[direction.name] = lastActivated
            print("MEASURED back REACH \(direction.name) = \(lastActivated)pt")
        }

        print("MEASURED back SUMMARY up=\(reach["up"] ?? -1) down=\(reach["down"] ?? -1) "
              + "left=\(reach["left"] ?? -1) right=\(reach["right"] ?? -1) frame=\(back.frame.size)")
        print("MEASURED back offWindow rungs: \(unreachable.joined(separator: ","))")

        XCTAssertGreaterThan(
            negatives, 0,
            "every probe activated — the probe cannot tell inside from outside on the bar"
        )
    }

    // MARK: - Probe 3: sign-out, one decisive rung per direction

    /// Sign-out is destructive, so it gets one rung per direction rather than a
    /// ladder: 22pt is the edge of a 44pt box, and that is the number the
    /// requirement is about. Four relaunches, not thirty-two.
    func testSignOutButtonAtTheFourEdgesOfA44ptBox() {
        let app = XCUIApplication()
        var results: [String: String] = [:]
        var frameDescription = "?"

        for direction in Self.directions {
            _ = signedIn(app)
            let signOut = app.buttons["session.signOut"]
            XCTAssertTrue(waitUntilHittable(signOut, in: app, timeout: 20))
            let frame = signOut.frame
            frameDescription = "\(frame.size)"

            // Vertically 22pt (half of 44). Horizontally half the button's own
            // width plus 8pt, which is outside the drawn label in every case.
            let distance: CGFloat = direction.dy == 0 ? (frame.width / 2) + 8 : 22
            let target = point(from: signOut, dx: direction.dx * distance, dy: direction.dy * distance)

            if !isInsideWindow(target, app) {
                results[direction.name] = "offWindow@\(Int(distance))pt"
            } else {
                target.tap()
                let signedOut = waitForExistence(
                    of: app.staticTexts["login.title"], in: app, timeout: 8
                )
                results[direction.name] = "\(signedOut ? "activated" : "nothing")@\(Int(distance))pt"
            }
            print("MEASURED signOut \(direction.name): \(results[direction.name] ?? "?")")
            app.terminate()
        }

        print("MEASURED signOut frame=\(frameDescription) "
              + "up=\(results["up"] ?? "?") down=\(results["down"] ?? "?") "
              + "left=\(results["left"] ?? "?") right=\(results["right"] ?? "?")")

        // No pass/fail on the outcome. This test's job is the four numbers; the
        // judgement about whether 44pt is met is made in the report, where the
        // difference between the three sizes can be stated instead of hidden
        // behind a green tick.
        XCTAssertEqual(results.count, 4, "a direction was not probed")
    }

    /// The one number the four-edge probe left ambiguous.
    ///
    /// Sign-out activated 22pt **above** its centre and did not activate 22pt
    /// **below** it. Two different things produce that reading and they have
    /// opposite verdicts:
    ///
    ///   * the region is a half-open 44pt box `[centre-22, centre+22)`, in
    ///     which case the requirement is met exactly; or
    ///   * the region really is shorter below, in which case it is not.
    ///
    /// The ladder in `testNavigationBarBackButtonHitRegionInAllFourDirections`
    /// already resolved the back button's lower edge to `(20, 22]`. This does
    /// the same for sign-out, three launches rather than one, because the
    /// difference between those two readings is the difference between "44pt"
    /// and "not 44pt" and it is not a difference to leave to an assumption.
    ///
    /// **Superseded as evidence, kept as a ladder.** Reaching outwards from a
    /// centre cannot separate "the region is 44pt" from "the centre sits half a
    /// point high", which is the whole reason `HitRegionBoundaryUITests`
    /// exists; it measures both boundaries absolutely instead and found
    /// sign-out's height to be in [43.438, 44.062) — unconfirmed against 44.
    /// Nothing here should be quoted as a verdict.
    func testSignOutLowerEdgeAtFinerResolution() {
        let app = XCUIApplication()
        var results: [String] = []

        for distance in [CGFloat(18), 20, 21] {
            _ = signedIn(app)
            let signOut = app.buttons["session.signOut"]
            XCTAssertTrue(waitUntilHittable(signOut, in: app, timeout: 20))
            let target = point(from: signOut, dx: 0, dy: distance)
            let outcome: String
            if !isInsideWindow(target, app) {
                outcome = "offWindow"
            } else {
                target.tap()
                outcome = waitForExistence(of: app.staticTexts["login.title"], in: app, timeout: 8)
                    ? "activated" : "nothing"
            }
            results.append("\(Int(distance))pt=\(outcome)")
            print("MEASURED signOutFine down \(Int(distance))pt -> \(outcome)")
            app.terminate()
        }

        print("MEASURED signOutFine SUMMARY \(results.joined(separator: " "))")
        XCTAssertEqual(results.count, 3, "a rung was not probed")
    }

    // MARK: - Control group, kept from the earlier round

    /// The probe has to be able to tell "inside the control" from "outside" it,
    /// or every other measurement in this file means nothing.
    ///
    /// Deliberately narrow and fast: 18pt above the like button's centre is
    /// inside a 44pt box and must register; 40pt above it is outside and must
    /// not.
    func testTheProbeCanTellInsideFromOutside() {
        let app = signedIn()
        let like = app.buttons.matching(identifier: "post.like").firstMatch
        XCTAssertTrue(waitUntilHittable(like, in: app, timeout: 30))
        print("MEASURED like button frame: \(like.frame.size)")
        // A hair of tolerance, and the reason is not sloppiness: this
        // assertion failed at 43.99999999999997. The button is laid out at
        // exactly 44 and the frame arrives through a float round trip, so a
        // strict >= 44 fails on arithmetic rather than on anything about the
        // control. Half a point is far below the resolution of any tap and
        // cannot hide a real shortfall — the next size down would be 40.
        XCTAssertGreaterThanOrEqual(like.frame.height, 43.5, "content controls are sized by us")

        let inside = probeLike(app, dx: 0, dy: -18)
        print("MEASURED control group inside (-18pt): \(inside.rawValue)")
        XCTAssertEqual(inside, .activated, "a tap inside the control must register")

        let outside = probeLike(app, dx: 0, dy: -40)
        print("MEASURED control group outside (-40pt): \(outside.rawValue)")
        XCTAssertNotEqual(outside, .activated, "a tap outside the control must not register")
    }
}
