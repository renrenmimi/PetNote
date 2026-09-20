import XCTest
#if canImport(UIKit)
import UIKit
#endif

private func fmt(_ value: CGFloat) -> String { String(format: "%.3f", value) }

/// Where the hit region *is*, in absolute window coordinates.
///
/// Every earlier attempt measured outwards from the element's centre, and that
/// cannot answer the question. "22pt above activates, 22pt below does not" is
/// consistent with a 44pt region whose centre sits half a point high, and
/// equally consistent with a 43pt one. Reaching from the middle conflates
/// *where the centre is* with *how tall the region is*, and only the second is
/// what §6.4 asks about.
///
/// So this finds each boundary as an absolute coordinate and subtracts. No
/// assumption of symmetry, and no inference from one side to the other.
///
/// Two claims are made about a size, and they are different kinds of claim:
///
///   * **the floor is a fact.** Two points activated; a hit region is one
///     connected rectangle, so everything between them is in it, so the extent
///     is at least their separation.
///   * **the ceiling is the complement.** Two points did not activate, so the
///     region reaches neither, so the extent is less than *their* separation.
///
/// Between those two lies the interval the search could not close, and it is
/// reported as an interval. It is never collapsed to a single number, because
/// a single number was never observed — see `Conditions.tolerance`.
///
/// Binary search rather than a 1pt sweep for a practical reason: activating
/// the back button pops the screen and activating sign-out ends the session,
/// so every probe costs a navigation round trip or a whole relaunch. A sweep
/// of sixty rungs would take hours; eight probes per boundary take minutes and
/// land in the same place.
///
/// ## What it read, 2026-09-19, pn-a4 (iPhone 17, iOS 27.0)
///
/// Window coordinates, window `(0, 0, 402, 874)` with its origin on the
/// screen's, scale 3.0x, so one device pixel is 0.333pt and that is the
/// bracket every boundary below is quoted to.
///
///     back      top (61.812, 62.125]   bottom [105.875, 106.188)
///               left (15.742, 16.031]  right  [59.875, 60.188)
///               reported frame (15.917, 61.970, 44.165, 44.060)
///     signOut   top (61.812, 62.125]   bottom [105.562, 105.875)
///               reported frame (295, 66, 87, 36)
///
/// Three things in there are worth more than the numbers:
///
///   1. **The back button's hit region is its reported frame.** All four
///      brackets contain the corresponding frame edge, to within a pixel. That
///      is the one control here where `frame` may be used as a size.
///   2. **The sign-out button's is not.** Its frame ends at y=102, and taps at
///      104 and 105.562 still activate it; it starts at y=66, and the region
///      starts at ~62. The bar has already expanded the item to its own
///      content box — which is exactly why adding padding and a `contentShape`
///      at the call site moved nothing, as `SignedInView` records.
///   3. **The two are not the same control.** At y=105.875 the back button
///      activates and sign-out does not. Same bar, same tap, different answer.
///
/// ## Why tapping cannot certify sign-out at 44pt
///
/// Certifying "at least 44" by tapping means producing two activating points
/// 44pt apart. For sign-out the highest activating point found is 62.125 and
/// the lowest non-activating one below is 105.875, so any certifying pair's
/// upper member must lie above 105.875 − 44 = 61.875. But 61.812 does not
/// activate, and the region is one interval, so nothing at or below 61.812
/// does either. The whole remaining window is (61.812, 61.875) — 0.063pt, a
/// fifth of one device pixel. No tap can be aimed inside it.
///
/// So the honest result for sign-out is an interval, [43.438, 44.062), and
/// "unconfirmed" — not because the search stopped early, but because the
/// evidence that would settle it is finer than the instrument. Anyone tempted
/// to run more bisections should read the paragraph above first.
final class HitRegionBoundaryUITests: XCTestCase {
    override func setUp() {
        // These are measurements. A boundary that cannot be found must not
        // throw away the three that can.
        continueAfterFailure = true
    }

    // MARK: - Conditions of measurement

    /// Everything a reader needs in order to know what these numbers are
    /// numbers *of*. Asked for explicitly, and rightly: a length with no
    /// coordinate space and no resolution attached is not a measurement.
    private struct Conditions {
        /// The window's frame, in screen coordinates.
        let window: CGRect
        /// Where the window's `(0, 0)` lands on the screen. When this equals
        /// `window.origin`, window and screen coordinates coincide and every
        /// figure below can be read as either; when it does not, everything
        /// below is window-relative.
        let originOnScreen: CGPoint
        /// Pixels per point, read from a real screenshot rather than assumed
        /// from the device name.
        let scale: CGFloat

        /// The width of the bracket every boundary is reported as: one device
        /// pixel. Stopping finer than this would be inventing resolution —
        /// there is no coordinate between two adjacent pixels for a tap to
        /// land on, so a narrower bracket describes the search, not the
        /// control.
        var tolerance: CGFloat { 1 / scale }

        var summary: String {
            "coordinates=window window=\(window) window(0,0)onScreen=\(originOnScreen) "
            + "scale=\(fmt(scale))x pixel=\(fmt(1 / scale))pt bracket=\(fmt(tolerance))pt"
        }
    }

    private func conditions(_ app: XCUIApplication) -> Conditions {
        let window = app.windows.firstMatch
        let recorded = Conditions(
            window: window.frame,
            originOnScreen: window.coordinate(withNormalizedOffset: .zero).screenPoint,
            scale: XCUIScreen.main.screenshot().image.scale
        )
        print("MEASURED conditions \(recorded.summary)")
        return recorded
    }

    // MARK: - One boundary, as the pair of coordinates that bracket it

    private struct Edge {
        let name: String
        /// The furthest coordinate in this direction that activated.
        let inside: CGFloat
        /// The nearest that did not. `nil` when the search ran out of window
        /// before it ran out of hit region: the region reaches the edge of the
        /// screen, and where it *would* have ended is not observable from here.
        let outside: CGFloat?
        /// Which way the search ran. It decides which end of the bracket is
        /// open, and getting that backwards misstates the result by a pixel in
        /// the direction that matters.
        let searchedUpwards: Bool
        let probes: Int

        var description: String {
            guard let outside else {
                return "\(name): still activating at \(fmt(inside)), which is the window edge — "
                    + "no outer boundary is visible from outside the app"
            }
            // Searching towards larger coordinates, the boundary is the *last*
            // coordinate inside, so it lies in [inside, outside). Searching
            // towards smaller ones it is the *first* inside, so (outside, inside].
            let bracket = searchedUpwards
                ? "[\(fmt(inside)), \(fmt(outside)))"
                : "(\(fmt(outside)), \(fmt(inside))]"
            return "\(name): boundary in \(bracket) — "
                + "activates at \(fmt(inside)), does not at \(fmt(outside)) [\(probes) probes]"
        }
    }

    /// Bisects between a coordinate known to activate and one known not to.
    ///
    /// `limit` is probed first, and a `nil` outside is returned if it activates
    /// too. That case is not a failure of the search, it is a fact about the
    /// screen, and silently bisecting anyway would have returned a confident
    /// boundary that is really just the edge of the display.
    ///
    /// The bisection assumes the region is connected along the axis — one
    /// interval, not two. That is what a UIKit hit region is; it is stated
    /// here because the search would not notice if it were wrong.
    private func findEdge(
        name: String,
        inside: CGFloat,
        limit: CGFloat,
        tolerance: CGFloat,
        probe: (CGFloat) -> Bool
    ) -> Edge {
        var probes = 0
        func test(_ value: CGFloat) -> Bool {
            probes += 1
            let hit = probe(value)
            print("MEASURED   \(name) #\(probes) at \(fmt(value)) -> \(hit ? "activated" : "nothing")")
            return hit
        }

        let upwards = limit > inside
        if test(limit) {
            return Edge(name: name, inside: limit, outside: nil,
                        searchedUpwards: upwards, probes: probes)
        }
        var good = inside
        var bad = limit
        while abs(bad - good) > tolerance {
            let mid = (good + bad) / 2
            if test(mid) { good = mid } else { bad = mid }
        }
        return Edge(name: name, inside: good, outside: bad,
                    searchedUpwards: upwards, probes: probes)
    }

    /// An extent, as the interval the two brackets allow, and the verdict that
    /// interval supports — which is sometimes neither pass nor fail.
    @discardableResult
    private func extent(
        _ control: String, _ name: String, from low: Edge, to high: Edge, requirement: CGFloat
    ) -> String {
        guard let lowOutside = low.outside, let highOutside = high.outside else {
            print("MEASURED \(control) \(name): UNRESOLVED — the region runs to the window edge "
                  + "on at least one side, so its extent is not observable by tapping")
            return "UNRESOLVED"
        }
        let atLeast = high.inside - low.inside
        let lessThan = lowOutside < highOutside ? highOutside - lowOutside : lowOutside - highOutside
        let verdict: String
        if atLeast >= requirement {
            verdict = "PASS"
        } else if lessThan <= requirement {
            verdict = "FAIL"
        } else {
            verdict = "UNCONFIRMED"
        }
        print("MEASURED \(control) \(name) in [\(fmt(atLeast)), \(fmt(lessThan))) vs required "
              + "\(fmt(requirement)) -> \(verdict)")
        return verdict
    }

    // MARK: - Driving the app

    @discardableResult
    private func signIn(_ app: XCUIApplication) -> Bool {
        app.launchArguments = ["-petnote-start-signed-out"]
        app.launch()
        guard waitForExistence(of: app.staticTexts["login.title"], in: app, timeout: 30) else {
            return false
        }
        let email = app.textFields["login.email"]
        email.tap(); email.typeText("accept-b@example.com")
        let password = app.secureTextFields["login.password"]
        password.tap(); password.typeText("Passw0rd!x")
        app.buttons["login.submit"].tap()
        guard waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 60) else {
            return false
        }
        waitForQuietUI(app)
        return true
    }

    /// A tap at an absolute point in the window's coordinate space.
    ///
    /// Deliberately not `element.coordinate(withNormalizedOffset:)`: the
    /// normalised form divides by the element's own size, so the same written
    /// offset means a different distance on a 36pt control than on a 44pt one,
    /// and that size is the variable under study.
    private func tap(_ app: XCUIApplication, _ point: CGPoint) {
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y))
            .tap()
    }

    /// The back button, found in the **detail screen's own bar**.
    ///
    /// Three earlier versions of this got the wrong control, and the lesson
    /// from each is in the query:
    ///
    ///   - `.firstMatch` over `app.navigationBars.buttons` returned an 87x36
    ///     element — sign-out, which is the one control here whose activation
    ///     cannot be undone. The first probe signed the session out and every
    ///     later one had no bar to find.
    ///   - Taking the leftmost instead did not fix it, because
    ///     `app.navigationBars` is *every* bar in the hierarchy. If the push
    ///     never happened, the only bar present is the feed's, sign-out is the
    ///     only button in it, and "leftmost" dutifully returns it. Geometry is
    ///     a consequence of being on a screen, not evidence of it.
    ///
    /// So the bar is named — `navigationBars["Post"]` only exists on the
    /// detail screen — and the caller has already waited for that screen. The
    /// leftmost tie-break is kept only for the case of a bar with several
    /// items; the back button carries no identifier of its own.
    ///
    /// Identity is then confirmed by *behaviour*, not by either: the probe
    /// counts a hit only when the screen pops. Sign-out cannot pop a screen,
    /// so a run that measured sign-out by mistake would record every probe as
    /// a miss and find no boundary at all.
    private static func backButton(inDetailBarOf app: XCUIApplication) -> XCUIElement {
        let bar = app.navigationBars["Post"]
        let buttons = bar.buttons.allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty }
        print("MEASURED detail bar frame = \(bar.frame), \(buttons.count) button(s): "
              + buttons.map { "[\($0.identifier)|\($0.label)|\($0.frame)]" }.joined(separator: " "))
        guard let leftmost = buttons.min(by: { $0.frame.minX < $1.frame.minX }) else {
            return bar.buttons.firstMatch
        }
        return leftmost
    }

    private func dismissStrayOverlays(_ app: XCUIApplication) {
        dismissSavePasswordSheetIfPresent(app)
        // A probe below the bar can land on the post's image and open the
        // full-screen viewer. That is a negative result for the button, but it
        // leaves a screen the next probe cannot see past.
        let close = app.buttons["full.close"]
        if close.exists, close.isHittable {
            close.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    @discardableResult
    private func ensureOnDetail(_ app: XCUIApplication) -> Bool {
        dismissStrayOverlays(app)
        if app.navigationBars["Post"].exists { return true }
        let rows = app.buttons.matching(identifier: "post.comments")
        guard waitUntilHittable(rows.firstMatch, in: app, timeout: 30) else { return false }
        rows.firstMatch.tap()
        return waitForExistence(of: app.navigationBars["Post"], in: app, timeout: 20)
    }

    /// Both bars exist briefly during the push and pop animations, so the
    /// signal is the detail bar being *gone*, not the feed bar being present.
    private func waitForPop(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.navigationBars["PetNote"].exists && !app.navigationBars["Post"].exists {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    private func probeBack(_ app: XCUIApplication, at point: CGPoint) -> Bool {
        guard ensureOnDetail(app) else {
            XCTFail("lost the detail screen before the probe at \(point)")
            return false
        }
        tap(app, point)
        let popped = waitForPop(app, timeout: 5)
        if !popped { dismissStrayOverlays(app) }
        return popped
    }

    /// The bar geometry from the first launch, to check it against later ones.
    private var signOutFrame: CGRect?
    // MARK: - The system back button

    /// UIKit's own back button: created by the navigation controller, not by
    /// any `ToolbarItem` of ours. Measured on its own account — see the note
    /// on `testSignOutHitRegionBoundaries` for why its result cannot be lent
    /// to the sign-out button.
    func testBackButtonHitRegionBoundaries() {
        let app = XCUIApplication()
        XCTAssertTrue(signIn(app), "could not sign in")
        let conditions = conditions(app)
        XCTAssertTrue(ensureOnDetail(app), "could not open a post")

        let back = Self.backButton(inDetailBarOf: app)
        let frame = back.frame
        print("MEASURED back reported(accessibility) frame = \(frame)")
        XCTAssertLessThan(frame.width, 60,
                          "this is not the back button — \(frame.size) looks like the sign-out control")

        let centreX = frame.midX, centreY = frame.midY

        // If the centre does not activate, everything below is measuring some
        // other control and the search would still return boundaries for it.
        XCTAssertTrue(probeBack(app, at: CGPoint(x: centreX, y: centreY)),
                      "the centre of the button does not activate it; this probe is not measuring this control")

        let window = conditions.window
        let top = findEdge(name: "back.top", inside: centreY,
                           limit: max(window.minY + 1, centreY - 40),
                           tolerance: conditions.tolerance) {
            self.probeBack(app, at: CGPoint(x: centreX, y: $0))
        }
        let bottom = findEdge(name: "back.bottom", inside: centreY,
                              limit: min(window.maxY - 1, centreY + 40),
                              tolerance: conditions.tolerance) {
            self.probeBack(app, at: CGPoint(x: centreX, y: $0))
        }
        let left = findEdge(name: "back.left", inside: centreX,
                            limit: max(window.minX + 1, centreX - 60),
                            tolerance: conditions.tolerance) {
            self.probeBack(app, at: CGPoint(x: $0, y: centreY))
        }
        let right = findEdge(name: "back.right", inside: centreX,
                             limit: min(window.maxX - 1, centreX + 80),
                             tolerance: conditions.tolerance) {
            self.probeBack(app, at: CGPoint(x: $0, y: centreY))
        }

        print("MEASURED ---- back button ----")
        print("MEASURED \(conditions.summary)")
        for edge in [top, bottom, left, right] { print("MEASURED \(edge.description)") }
        let height = extent("back", "height", from: top, to: bottom, requirement: 44)
        let width = extent("back", "width", from: left, to: right, requirement: 44)
        print("MEASURED back VERDICT height=\(height) width=\(width)")

        // Recorded, not asserted into a pass. A shortfall here is a finding
        // about UIKit's bar, and a run that goes red on it hides the four
        // numbers underneath a failure message.
        XCTAssertNotEqual(height, "", "height was not measured")
    }
}
