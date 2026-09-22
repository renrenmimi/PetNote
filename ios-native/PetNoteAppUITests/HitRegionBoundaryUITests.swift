import XCTest
#if canImport(UIKit)
import UIKit
#endif

private func fmt(_ value: CGFloat) -> String { String(format: "%.3f", value) }

/// Where a hit region *is*, in absolute window coordinates.
///
/// Every earlier attempt measured outwards from the element's centre, and that
/// cannot answer the question. "22pt above activates, 22pt below does not" is
/// consistent with a 44pt region whose centre sits half a point high, and
/// equally consistent with a 43pt one. Reaching from the middle conflates
/// *where the centre is* with *how far the region reaches*, and only the second
/// is what §6.4 asks about. It is also how a shortfall got reported as a pass
/// once: "the centre plus 22pt up activates" was written down as "at least 44
/// tall", and the later measurement found the region reaching 22 up and not 22
/// down. One side is not a size.
///
/// So this finds each boundary as an absolute coordinate and subtracts. No
/// assumption of symmetry, and no inference from one side to the other.
///
/// Two claims are made about an extent, and they are different kinds of claim:
///
///   * **the floor is a fact.** Two points activated; a hit region is one
///     connected rectangle, so everything between them is in it, so the extent
///     is at least their separation.
///   * **the ceiling is the complement.** Two points did not activate, so the
///     region reaches neither, so the extent is less than *their* separation.
///
/// Between those lies the interval the search could not close, and it is
/// reported as an interval. It is never collapsed to a single number, because
/// a single number was never observed — see `Conditions.tolerance`.
///
/// Binary search rather than a 1pt sweep for a practical reason: activating
/// the back button pops the screen and activating sign-out ends the session,
/// so every probe costs a navigation round trip or a whole sign-in. A sweep of
/// sixty rungs would take hours; eight probes per boundary take minutes and
/// land in the same place.
///
/// ## What this file trusts, and what proves it
///
/// The search is only as good as the probe underneath it, and last round the
/// probe was broken in three ways that all pushed the same direction — towards
/// smaller regions and an unearned control group. They are recorded in
/// `TouchTargetUITests`, which is the instrument and its own tests:
/// `testEachOutcomeIsReachable`, `testACoverLeavesTheDetailBarInTheTreeAndIsClearedAnyway`
/// and `testANegativeIsConfirmedRatherThanAssumed`. Those have to be green
/// before any number below means anything.
///
/// `testTheSearchRecoversAKnownExtent` covers the other half — the arithmetic
/// of the search itself — against synthetic regions whose size is known
/// exactly, including ones far smaller and far larger than 44. It costs no
/// simulator time and it is the one place where "the instrument reads 44 on a
/// 44pt target" is checked without a single confounder.
///
/// ## The reading from 2026-09-19 that is now known to be biased
///
/// The back-button figures previously recorded here were taken with the broken
/// probe: `dismissStrayOverlays` looked for `full.close`, a name the app never
/// sets, so a probe that opened the full-screen photo left the viewer up and
/// every probe after it was recorded as a miss. Those numbers are not quoted
/// any more. What survives from that round is one *argument*, because it does
/// not depend on the readings being right:
///
/// > Certifying "at least 44" by tapping means producing two activating points
/// > 44pt apart. If the highest activating point found is `a` and the lowest
/// > non-activating point below it is `b`, any certifying pair's upper member
/// > must lie above `b − 44`. When `b − 44` falls inside a bracket that has
/// > already been shown not to activate, the remaining window is narrower than
/// > one device pixel and no tap can be aimed inside it.
///
/// That is why a verdict here has three values and not two. `UNCONFIRMED` is
/// not the search stopping early; it is the evidence that would settle it
/// being finer than the instrument.
///
/// ## What a hit region turned out to be, which is not what this file assumed
///
/// For two rounds the control group failed and the instrument was blamed. It
/// was right the second time. A touch region is **not** the view's frame, and
/// how far it exceeds it depends on who laid the control out:
///
///     control        accessibility frame    measured hit region
///     back            (16, 62) 44 x 44       44.0 x 44.0    the frame
///     account.menu    (349, 66) 30 x 36      43.8 x 43.7    grown to 44
///     session.signOut (8, 710.8) 386 x 53.8  83.3 x 386.3   +15 above/below
///     post.like       (16, 753) 48.3 x 44    62.0 x >= 75.3 see below
///
/// The two in the middle are the platform: UIKit grows an undersized bar item
/// to 44, and a SwiftUI control with room around it is given about 15pt of it.
/// Where two interactive regions would overlap, the space between them is
/// split down the middle — `post.like` and `post.comments` are 24pt apart and
/// their regions meet at 76.333, which both searches found independently.
///
/// Three consequences for anyone reading numbers out of this file:
///
///   1. **A frame is a lower bound on a hit region, never an upper one.** The
///      §6.4 question "is this control at least 44pt" is answered *more*
///      easily than the layout suggests, and the interesting question is
///      whether a control is big enough *before* the platform helps.
///   2. **`post.comments` cannot be measured from the feed at all.** In
///      `FeedView` its action is `open(post)` and so is the card's
///      `onOpenPost`, so "the button fired" and "the photo above it fired"
///      are one event. Its vertical boundaries here are the *card's*, not the
///      button's, which is why they run to the limit. Only its left boundary
///      is its own, because the thing on the other side is a different button.
///   3. **A control sitting alone reads much larger than it is laid out.**
///      `session.signOut` is 56pt by construction and measures 83.
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
            // "as read" matters: every boundary below is a window coordinate
            // taken in the layout the control's anchor frame was read in. When
            // the control moves — the feed re-anchors its scroll position after
            // a pop — the probe point is translated with it rather than the
            // numbers being restated, so a reader maps a boundary back to the
            // screen through the control's reported frame, which is printed
            // with every measurement.
            "coordinates=window(as read at the anchor) window=\(window) "
            + "window(0,0)onScreen=\(originOnScreen) "
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
        /// What the nearest non-activating probe actually saw.
        ///
        /// `nothing` means the region simply ends and there is clear space
        /// beyond it. `somethingElse` means the neighbouring control begins
        /// right there, so this boundary is where one region gives way to the
        /// next rather than where a region ends — worth saying out loud,
        /// because a control with no dead band around it is a different
        /// product fact from one with 24pt of clearance.
        let outsideOutcome: TouchOutcome
        /// Which way the search ran. It decides which end of the bracket is
        /// open, and getting that backwards misstates the result by a pixel in
        /// the direction that matters.
        let searchedUpwards: Bool
        /// Whether the furthest point this search was allowed to try was the
        /// edge of the window or merely the end of its own `reach`.
        ///
        /// **These are different results and were reported as the same one.**
        /// When `outside` is nil the search never found a point that failed to
        /// activate, and the reason matters: at the window edge there is
        /// genuinely nowhere further to tap, and the region's true end is not
        /// observable from outside the app. At the end of `reach` the region
        /// simply continues past where this search bothered to look, and the
        /// honest report is "look further", not "the screen ran out".
        ///
        /// `comments.top` was reported for two rounds as reaching the window
        /// edge. Its limit was 735 and the window starts at 0. What actually
        /// happened is that the probe cannot tell the comments button from the
        /// card above it — they run the same action — so it kept activating
        /// for as far as the search looked.
        let limitIsWindowEdge: Bool
        let probes: Int

        var description: String {
            guard let outside else {
                let why = limitIsWindowEdge
                    ? "which is the window edge — no outer boundary is visible from outside the app"
                    : "which is as far as this search was told to look (reach); the region "
                      + "continues past it and this is not a measurement of where it ends"
                return "\(name): still activating at \(fmt(inside)), \(why)"
            }
            // Searching towards larger coordinates, the boundary is the *last*
            // coordinate inside, so it lies in [inside, outside). Searching
            // towards smaller ones it is the *first* inside, so (outside, inside].
            let bracket = searchedUpwards
                ? "[\(fmt(inside)), \(fmt(outside)))"
                : "(\(fmt(outside)), \(fmt(inside))]"
            return "\(name): boundary in \(bracket) — activates at \(fmt(inside)), "
                + "at \(fmt(outside)) the probe saw \(outsideOutcome.rawValue) [\(probes) probes]"
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
        limitIsWindowEdge: Bool,
        tolerance: CGFloat,
        probe: (CGFloat) -> TouchOutcome
    ) -> Edge {
        var probes = 0
        func test(_ value: CGFloat) -> TouchOutcome {
            probes += 1
            let outcome = probe(value)
            print("MEASURED   \(name) #\(probes) at \(fmt(value)) -> \(outcome.rawValue)")
            return outcome
        }

        let upwards = limit > inside
        let atLimit = test(limit)
        if atLimit == .activated {
            return Edge(name: name, inside: limit, outside: nil, outsideOutcome: atLimit,
                        searchedUpwards: upwards, limitIsWindowEdge: limitIsWindowEdge,
                        probes: probes)
        }
        var good = inside
        var bad = limit
        var badOutcome = atLimit
        while abs(bad - good) > tolerance {
            let mid = (good + bad) / 2
            let outcome = test(mid)
            if outcome == .activated {
                good = mid
            } else {
                bad = mid
                badOutcome = outcome
            }
        }
        return Edge(name: name, inside: good, outside: bad, outsideOutcome: badOutcome,
                    searchedUpwards: upwards, limitIsWindowEdge: limitIsWindowEdge,
                    probes: probes)
    }

    /// An extent, as the interval the two brackets allow.
    private struct Extent {
        let control: String
        let axis: String
        /// A fact: two points this far apart both activated.
        let atLeast: CGFloat
        /// The complement: two points this far apart both did not.
        let lessThan: CGFloat
        let verdict: String

        var description: String {
            "\(control) \(axis) in [\(fmt(atLeast)), \(fmt(lessThan))) -> \(verdict)"
        }
    }

    @discardableResult
    private func extent(
        _ control: String, _ axis: String, from low: Edge, to high: Edge, requirement: CGFloat
    ) -> Extent? {
        guard let lowOutside = low.outside, let highOutside = high.outside else {
            let open = [low, high].filter { $0.outside == nil }
            let why = open.allSatisfy(\.limitIsWindowEdge)
                ? "the region runs to the window edge on at least one side, so its extent is "
                  + "not observable by tapping"
                : "the search kept activating as far as it was told to look on "
                  + open.filter { !$0.limitIsWindowEdge }.map(\.name).joined(separator: " and ")
                  + "; the region is larger than the reach, and this is not its extent"
            print("MEASURED \(control) \(axis): UNRESOLVED — \(why)")
            return nil
        }
        let atLeast = high.inside - low.inside
        let lessThan = abs(highOutside - lowOutside)
        let verdict: String
        if atLeast >= requirement {
            verdict = "PASS"
        } else if lessThan <= requirement {
            verdict = "FAIL"
        } else {
            verdict = "UNCONFIRMED"
        }
        let measured = Extent(
            control: control, axis: axis, atLeast: atLeast, lessThan: lessThan, verdict: verdict
        )
        print("MEASURED \(measured.description) vs required \(fmt(requirement))")
        return measured
    }

    /// The clear space between two neighbouring regions.
    ///
    /// Both bounds come out of brackets that were measured, not out of a
    /// layout constant: `low` is the left/upper region's outer edge and `high`
    /// is the right/lower region's, so the band is at least
    /// `high.outside − low.outside` and at most `high.inside − low.inside`.
    /// The two differ by no more than two brackets, which is the whole error
    /// budget of the reading.
    @discardableResult
    private func band(_ name: String, from low: Edge, to high: Edge) -> Extent? {
        guard let lowOutside = low.outside, let highOutside = high.outside else {
            print("MEASURED \(name): UNRESOLVED — one of the two boundaries was never closed, "
                  + "so there is no outer edge to measure the band between")
            return nil
        }
        let measured = Extent(
            control: name, axis: "clear band",
            atLeast: highOutside - lowOutside, lessThan: high.inside - low.inside,
            verdict: "measured"
        )
        print("MEASURED \(name) clear band in (\(fmt(measured.atLeast)), \(fmt(measured.lessThan))]")
        return measured
    }

    // MARK: - Both boundaries on one axis

    private func edgesOnAxis(
        _ control: String,
        centre: CGPoint,
        reach: CGFloat,
        vertical: Bool,
        conditions: Conditions,
        probe: (CGPoint) -> TouchOutcome
    ) -> (low: Edge, high: Edge) {
        let window = conditions.window
        let centreValue = vertical ? centre.y : centre.x
        let lowLimit = vertical
            ? max(window.minY + 1, centre.y - reach)
            : max(window.minX + 1, centre.x - reach)
        let highLimit = vertical
            ? min(window.maxY - 1, centre.y + reach)
            : min(window.maxX - 1, centre.x + reach)
        func at(_ value: CGFloat) -> CGPoint {
            vertical ? CGPoint(x: centre.x, y: value) : CGPoint(x: value, y: centre.y)
        }
        // Which of the two bounds actually bound: the clamp, or `reach`. Only
        // the clamp means "there is nowhere further to tap".
        let lowIsWindow = lowLimit > (vertical ? centre.y : centre.x) - reach
        let highIsWindow = highLimit < (vertical ? centre.y : centre.x) + reach
        let low = findEdge(
            name: "\(control).\(vertical ? "top" : "left")",
            inside: centreValue, limit: lowLimit, limitIsWindowEdge: lowIsWindow,
            tolerance: conditions.tolerance
        ) { probe(at($0)) }
        let high = findEdge(
            name: "\(control).\(vertical ? "bottom" : "right")",
            inside: centreValue, limit: highLimit, limitIsWindowEdge: highIsWindow,
            tolerance: conditions.tolerance
        ) { probe(at($0)) }
        return (low, high)
    }

    // MARK: - The back button, in the detail screen's own bar

    /// The back button, found in the **detail screen's own bar**.
    ///
    /// Three earlier versions of this got the wrong control, and the lesson
    /// from each is in the query:
    ///
    ///   - `.firstMatch` over `app.navigationBars.buttons` returned an 87x36
    ///     element — sign-out, which at the time was the one control here whose
    ///     activation cannot be undone. The first probe signed the session out
    ///     and every later one had no bar to find.
    ///   - Taking the leftmost instead did not fix it, because
    ///     `app.navigationBars` is *every* bar in the hierarchy. If the push
    ///     never happened, the only bar present is the feed's, and "leftmost"
    ///     dutifully returns whatever is in it. Geometry is a consequence of
    ///     being on a screen, not evidence of it.
    ///
    /// So the bar is named — `navigationBars["Post"]` only exists on the
    /// detail screen — and the caller has already waited for that screen. The
    /// leftmost tie-break is kept only for the case of a bar with several
    /// items; the back button carries no identifier of its own.
    ///
    /// Identity is then confirmed by *behaviour*, not by either: the probe
    /// counts a hit only when the screen pops.
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

    // MARK: - The search, against regions whose size is known exactly

    /// The arithmetic, checked where there is nothing to confound it.
    ///
    /// The owner's instruction was to prove the instrument on targets of known
    /// size before pointing it at anything, and this is the half of that which
    /// can be made exact: a synthetic region, a synthetic probe, and a known
    /// answer. Four sizes rather than one — 18, 44, 60 and 44.165 — because an
    /// instrument that returns 44 for everything also returns 44 for a 44pt
    /// control, and the way to tell those apart is to give it something that
    /// is not 44.
    ///
    /// Each recovered interval must contain the true size and must be no wider
    /// than two brackets, which is the most two bisections can leave open.
    ///
    /// ## The result that changed how the readings below are written
    ///
    /// **A region of exactly 44 cannot be certified PASS by tapping.** This
    /// test was first written expecting one, and it was wrong to. Certifying
    /// the floor means finding two *activating* points 44 apart, and the
    /// bisection only ever brackets each boundary to within a device pixel —
    /// so the floor lands a fraction of a pixel inside the true edge at each
    /// end and the measured interval straddles the requirement. Run here:
    ///
    ///     18      [17.500, 18.125)   FAIL
    ///     44      [43.750, 44.375)   UNCONFIRMED
    ///     44.165  [43.750, 44.375)   UNCONFIRMED
    ///     60      [60.000, 60.625)   PASS
    ///
    /// Every one of those intervals contains the true size, and the two
    /// verdicts that are not `UNCONFIRMED` are the two where the truth is
    /// clear of the line by more than the instrument's own error. So a control
    /// laid out at *exactly* the minimum is unconfirmable by this method, by
    /// construction and not by bad luck — which is the measured form of the
    /// argument `AccountMenuView` makes when it gives the sign-out row a grid
    /// step of headroom instead of sitting it on 44.
    ///
    /// The verdicts are therefore checked for *consistency with the truth*
    /// rather than against an expected string: a region at or above the
    /// requirement must never be called FAIL, one below must never be called
    /// PASS, and UNCONFIRMED must appear exactly when the requirement falls
    /// inside the measured interval.
    func testTheSearchRecoversAKnownExtent() {
        let tolerance: CGFloat = 1.0 / 3.0   // one device pixel at 3x
        for size in [CGFloat(18), 44, 60, 44.165] {
            // A region centred at 400, so neither boundary is near a limit.
            let low = 400 - size / 2, high = 400 + size / 2
            func probe(_ value: CGFloat) -> TouchOutcome {
                (value >= low && value <= high) ? .activated : .nothing
            }
            let top = findEdge(name: "synthetic.top", inside: 400, limit: 400 - 80,
                               limitIsWindowEdge: false, tolerance: tolerance, probe: probe)
            let bottom = findEdge(name: "synthetic.bottom", inside: 400, limit: 400 + 80,
                                  limitIsWindowEdge: false, tolerance: tolerance, probe: probe)
            guard let measured = extent("synthetic\(fmt(size))", "extent",
                                        from: top, to: bottom, requirement: 44) else {
                XCTFail("the search could not close a synthetic region of \(size)")
                continue
            }
            XCTAssertLessThanOrEqual(
                measured.atLeast, size,
                "the floor claims more than the region has: \(fmt(measured.atLeast)) > \(fmt(size))"
            )
            XCTAssertGreaterThan(
                measured.lessThan, size,
                "the ceiling excludes the true size: \(fmt(measured.lessThan)) <= \(fmt(size))"
            )
            XCTAssertLessThanOrEqual(
                measured.lessThan - measured.atLeast, 2 * tolerance + 0.001,
                "the interval is wider than two brackets, so the search stopped short"
            )
            // The verdict follows from the interval, and the interval has to
            // be consistent with the truth. Not an expected string: see the
            // note above on why 44 comes back UNCONFIRMED.
            if size >= 44 {
                XCTAssertNotEqual(measured.verdict, "FAIL",
                                  "a \(fmt(size))pt region was failed against a 44pt requirement")
            } else {
                XCTAssertNotEqual(measured.verdict, "PASS",
                                  "a \(fmt(size))pt region was passed against a 44pt requirement")
            }
            XCTAssertEqual(
                measured.verdict == "UNCONFIRMED",
                measured.atLeast < 44 && measured.lessThan > 44,
                "the verdict does not follow from the interval: \(measured.description)"
            )
        }
    }

    // MARK: - The feed's action row: two known frames and the boundary between them

    /// The like and comments buttons, and the boundary they share.
    ///
    /// **This is the control group for everything else in this file, and it is
    /// also two of the controls under test.**
    ///
    /// ## The premise this test used to hold, and the measurement that broke it
    ///
    /// It used to assert that the like button's hit region *equals* its
    /// accessibility frame: 44 tall by construction, 48.33 wide from the
    /// label, with `Spacing.xl` (24) of clear space before the comments
    /// button. The reasoning was that `.contentShape(.rect)` sits on
    /// `.frame(minWidth: 44, minHeight: 44)`, so the shape follows the frame.
    /// That reasoning describes where SwiftUI *draws* the shape. It does not
    /// describe where a touch is delivered, and the two are not the same:
    ///
    ///     like a11y frame          x[16.000,  64.333]  y[753, 797]
    ///     like hit region          x[ 1.000,  76.333]  y[747, 809]
    ///
    /// Three of those four boundaries are exact functions of the layout, and
    /// none of them is the frame:
    ///
    ///   * `747.000` is the midpoint of the `Spacing.m` (12) gap between the
    ///     photo above and the action row — the photo opens the post, the
    ///     button likes it, and the space between them is split down the
    ///     middle;
    ///   * `809.000` is the card's own bottom edge, `actions.maxY` plus the
    ///     card's `Spacing.m` bottom padding, where there is no neighbour to
    ///     split with;
    ///   * `76.333` is the midpoint of the `Spacing.xl` (24) gap to the
    ///     comments button.
    ///
    /// The reading was called an instrument fault twice — "collapsed to a
    /// point" in the first round and "inflated by 40%" in the second — and the
    /// first of those really was one (`dismissStrayOverlays` looked for a name
    /// the app never sets, so every probe after a cover opened was recorded as
    /// a miss). The second was not. It is the touch region, and it is bigger
    /// than the view.
    ///
    /// ## Why this is the instrument being right rather than the test being
    /// relaxed
    ///
    /// Four independent results, from runs that reproduce bit for bit:
    ///
    ///   1. **The system back button reads exactly its frame.** 44x44
    ///      reported, `[43.828, 44.172)` by `[43.570, 44.133)` measured — four
    ///      boundaries each within one device pixel of the frame. An
    ///      instrument that inflates cannot return that.
    ///   2. **The account entry reads 44x44 from a 30x36 frame** — the
    ///      documented UIKit minimum for a bar item, recovered rather than
    ///      assumed.
    ///   3. **`like.right` and `comments.left` agree.** They are searched
    ///      independently, from opposite directions, by two different probes
    ///      with two different activation signals, and they bracket the same
    ///      coordinate to within one device pixel — the coordinate the layout
    ///      predicts. An instrument that saturates in either direction cannot
    ///      produce a shared boundary at a predicted place.
    ///   4. **One run still yields three different numbers**: ~62 for the
    ///      like button's height, ~75 for the comments button's width, and ~0
    ///      for the band between the two, which used to be asserted at 24 and
    ///      is not there — the regions are adjacent.
    ///
    /// So the assertions below are the claims that survive: the region has to
    /// *contain* the control, it has to stop short of the *neighbouring*
    /// control, and the boundary between the two has to land where the layout
    /// says. Those are predictions made from `likeFrame` and `commentsFrame`
    /// as read at runtime, not numbers copied back out of a log. The old
    /// assertion is not loosened, it is replaced: "the region equals the
    /// frame" was disproved, and "the region contains the frame and stops at
    /// the midpoint" is the thing that can now be shown false.
    ///
    /// What is *not* claimed here is a §6.4 verdict on the two buttons. Their
    /// frames are 44 and their touch regions are larger than their frames;
    /// that is recorded, and the verdict line still prints.
    func testTheInstrumentAgreesWithTheKnownGeometryOfTheFeedActionRow() {
        let app = XCUIApplication()
        XCTAssertTrue(launchSignedInForProbing(app), "could not sign in")
        let conditions = conditions(app)

        let like = app.buttons.matching(identifier: "post.like").firstMatch
        XCTAssertTrue(waitUntilHittable(like, in: app, timeout: 40), "no post in the feed")
        XCTAssertTrue(frameSettled(like), "the feed is still moving")
        let likeFrame = like.frame
        let comments = app.buttons.matching(identifier: "post.comments").firstMatch
        XCTAssertTrue(comments.waitForExistence(timeout: 20))
        let commentsFrame = comments.frame
        let postText = app.staticTexts.matching(identifier: "post.text").firstMatch
        XCTAssertTrue(postText.waitForExistence(timeout: 20), "the first post has no text")
        let postLabel = postText.label
        let postTextFrame = postText.frame

        print("MEASURED like reported(accessibility) frame = \(likeFrame)")
        print("MEASURED comments reported(accessibility) frame = \(commentsFrame)")
        print("MEASURED first post text frame = \(postTextFrame) label=\"\(postLabel.prefix(48))\"")

        // The disambiguation the comments probe depends on only works if the
        // post it expects to open has text of its own to be recognised by.
        XCTAssertFalse(postLabel.isEmpty, "the first post has no text to identify it by")
        XCTAssertLessThan(postTextFrame.maxY, commentsFrame.minY,
                          "the text this probe identifies the post by belongs to another card")
        XCTAssertLessThan(likeFrame.minX, commentsFrame.minX, "these two are the wrong way round")

        // --- the like button, all four boundaries
        let likeCentre = CGPoint(x: likeFrame.midX, y: likeFrame.midY)
        XCTAssertEqual(
            probeLikeButton(app, at: likeCentre, anchor: likeFrame), .activated,
            "the centre of the like button does not activate it; this probe is measuring something else"
        )
        let likeVertical = edgesOnAxis(
            "like", centre: likeCentre, reach: 40, vertical: true, conditions: conditions
        ) { self.probeLikeButton(app, at: $0, anchor: likeFrame) }
        let likeHorizontal = edgesOnAxis(
            "like", centre: likeCentre, reach: 60, vertical: false, conditions: conditions
        ) { self.probeLikeButton(app, at: $0, anchor: likeFrame) }

        // --- the comments button, all four boundaries
        let commentsCentre = CGPoint(x: commentsFrame.midX, y: commentsFrame.midY)
        XCTAssertEqual(
            probeCommentsButton(app, at: commentsCentre, anchor: commentsFrame,
                                opensPostWithText: postLabel),
            .activated,
            "the centre of the comments button does not open this post"
        )
        let commentsVertical = edgesOnAxis(
            "comments", centre: commentsCentre, reach: 40, vertical: true, conditions: conditions
        ) { self.probeCommentsButton(app, at: $0, anchor: commentsFrame, opensPostWithText: postLabel) }
        let commentsHorizontal = edgesOnAxis(
            "comments", centre: commentsCentre, reach: 60, vertical: false, conditions: conditions
        ) { self.probeCommentsButton(app, at: $0, anchor: commentsFrame, opensPostWithText: postLabel) }

        print("MEASURED ---- feed action row ----")
        print("MEASURED \(conditions.summary)")
        for edge in [likeVertical.low, likeVertical.high, likeHorizontal.low, likeHorizontal.high,
                     commentsVertical.low, commentsVertical.high,
                     commentsHorizontal.low, commentsHorizontal.high] {
            print("MEASURED \(edge.description)")
        }

        let likeHeight = extent("like", "height", from: likeVertical.low, to: likeVertical.high,
                                requirement: 44)
        let likeWidth = extent("like", "width", from: likeHorizontal.low, to: likeHorizontal.high,
                               requirement: 44)
        let commentsHeight = extent("comments", "height", from: commentsVertical.low,
                                    to: commentsVertical.high, requirement: 44)
        let commentsWidth = extent("comments", "width", from: commentsHorizontal.low,
                                   to: commentsHorizontal.high, requirement: 44)
        // Printed, not asserted at 24 any more: the two regions meet, so this
        // band is zero to within a bracket. It is kept because a band that
        // stopped being zero would mean the arbitration between the two
        // regions had changed, and that is worth seeing.
        band("like|comments", from: likeHorizontal.high, to: commentsHorizontal.low)

        // --- the control group, as assertions rather than as a paragraph
        //
        // Stated over *edges* rather than over closed extents on purpose. The
        // like button's region reaches x=1, which is one device pixel inside
        // the window, so its width cannot be closed by tapping and `extent`
        // rightly reports UNRESOLVED. That is a fact about the screen, not a
        // failure of the run, and it must not take the other seven boundaries
        // down with it — which is what the old `guard let likeWidth` did.
        let slack = 2 * conditions.tolerance

        // 1. Containment. Whatever else the hit region is, it has to include
        //    the control that was laid out. This is the assertion that fails
        //    when the probe's negatives are free: the first round's collapsed
        //    reading — 28.1pt tall, both horizontal boundaries on the button's
        //    own centre — is caught here and by nothing else below.
        XCTAssertLessThanOrEqual(
            likeVertical.low.inside, likeFrame.minY + slack,
            "the measured region does not reach the top of the control it is measuring: "
            + "activates no higher than \(fmt(likeVertical.low.inside)), frame starts at "
            + "\(fmt(likeFrame.minY))"
        )
        XCTAssertGreaterThanOrEqual(
            likeVertical.high.inside, likeFrame.maxY - slack,
            "the measured region does not reach the bottom of the control it is measuring: "
            + "activates no lower than \(fmt(likeVertical.high.inside)), frame ends at "
            + "\(fmt(likeFrame.maxY))"
        )
        XCTAssertLessThanOrEqual(
            likeHorizontal.low.inside, likeFrame.minX + slack,
            "the measured region does not reach the left edge of the control: activates no "
            + "further left than \(fmt(likeHorizontal.low.inside)), frame starts at "
            + "\(fmt(likeFrame.minX))"
        )
        XCTAssertGreaterThanOrEqual(
            likeHorizontal.high.inside, likeFrame.maxX - slack,
            "the measured region does not reach the right edge of the control: activates no "
            + "further right than \(fmt(likeHorizontal.high.inside)), frame ends at "
            + "\(fmt(likeFrame.maxX))"
        )

        // 2. Non-engulfment. The like button's region must stop before the
        //    comments button's frame and vice versa, or the instrument is
        //    reporting the row rather than the control — the saturation the
        //    24pt band used to be there to catch.
        XCTAssertLessThan(
            likeHorizontal.high.inside, commentsFrame.minX,
            "the like button's hit region reaches into the comments button's own frame; "
            + "the instrument is measuring the row, not the control"
        )
        XCTAssertGreaterThan(
            commentsHorizontal.low.inside, likeFrame.maxX,
            "the comments button's hit region reaches into the like button's own frame"
        )

        // 3. The shared boundary, which is the calibration.
        //
        //    `like.right` and `comments.left` are found by two different
        //    probes, with two different activation signals, searching in
        //    opposite directions. They have to bracket one coordinate, and it
        //    has to be the one the layout predicts: the middle of the gap
        //    between the two frames. Nothing about this is copied out of a
        //    measurement — both frames are read at runtime, a line above.
        guard let likeRightOutside = likeHorizontal.high.outside,
              let commentsLeftOutside = commentsHorizontal.low.outside else {
            XCTFail("the boundary between the two buttons could not be closed from both sides")
            return
        }
        let midpoint = (likeFrame.maxX + commentsFrame.minX) / 2
        print("MEASURED like|comments shared boundary: like.right in "
              + "[\(fmt(likeHorizontal.high.inside)), \(fmt(likeRightOutside))), comments.left in "
              + "(\(fmt(commentsLeftOutside)), \(fmt(commentsHorizontal.low.inside))], "
              + "layout predicts \(fmt(midpoint))")
        XCTAssertLessThanOrEqual(
            abs(commentsHorizontal.low.inside - likeHorizontal.high.inside), 2 * slack,
            "two independent searches from opposite directions disagree about where the "
            + "boundary between the two buttons is"
        )
        XCTAssertGreaterThanOrEqual(
            midpoint, likeHorizontal.high.inside - slack,
            "the boundary the layout predicts is below the last point that activated the like "
            + "button: predicted \(fmt(midpoint)), activates at \(fmt(likeHorizontal.high.inside))"
        )
        XCTAssertLessThanOrEqual(
            midpoint, commentsHorizontal.low.inside + slack,
            "the boundary the layout predicts is above the first point that activated the "
            + "comments button: predicted \(fmt(midpoint)), activates at "
            + "\(fmt(commentsHorizontal.low.inside))"
        )

        // 4. Resolution: one run, more than one answer. The two buttons have
        //    identical frames and different neighbourhoods, so their regions
        //    must not come out the same size. An instrument returning one
        //    number for everything fails here.
        guard let likeHeight, let commentsWidth else {
            XCTFail("neither the like button's height nor the comments button's width closed; "
                    + "there is no second reading to compare the first against")
            return
        }
        XCTAssertGreaterThan(
            abs(commentsWidth.atLeast - likeHeight.atLeast), 5,
            "two extents that differ in the layout measured the same: the instrument is not "
            + "resolving size. like height \(likeHeight.description), comments width "
            + "\(commentsWidth.description)"
        )

        print("MEASURED VERDICT like height=\(likeHeight.verdict) "
              + "width=\(likeWidth?.verdict ?? "UNRESOLVED")")
        print("MEASURED VERDICT comments height=\(commentsHeight?.verdict ?? "UNRESOLVED") "
              + "width=\(commentsWidth.verdict)")
    }

    // MARK: - The account entry in the feed's navigation bar

    /// The control that replaced the sign-out button in the bar.
    ///
    /// Laid out by UIKit, not by us — a bare `Image` in a `ToolbarItem` — so
    /// nothing about its size is known in advance and the reading is the whole
    /// answer. Recoverable, which the control it replaced was not: opening a
    /// menu can be undone, ending a session cannot.
    func testAccountEntryHitRegionBoundaries() {
        let app = XCUIApplication()
        XCTAssertTrue(launchSignedInForProbing(app), "could not sign in")
        let conditions = conditions(app)
        XCTAssertTrue(arriveAtFeed(app), "could not reach the feed")

        let entry = app.buttons["account.menu"]
        XCTAssertTrue(waitUntilHittable(entry, in: app, timeout: 30), "no account entry in the bar")
        XCTAssertTrue(frameSettled(entry), "the navigation bar is still moving")
        let frame = entry.frame
        print("MEASURED account.menu reported(accessibility) frame = \(frame)")

        let centre = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertEqual(
            probeAccountEntry(app, at: centre, anchor: frame), .activated,
            "the centre of the account entry does not open the menu"
        )
        let vertical = edgesOnAxis("account", centre: centre, reach: 44, vertical: true,
                                   conditions: conditions) {
            self.probeAccountEntry(app, at: $0, anchor: frame)
        }
        let horizontal = edgesOnAxis("account", centre: centre, reach: 60, vertical: false,
                                     conditions: conditions) {
            self.probeAccountEntry(app, at: $0, anchor: frame)
        }

        print("MEASURED ---- account entry ----")
        print("MEASURED \(conditions.summary)")
        for edge in [vertical.low, vertical.high, horizontal.low, horizontal.high] {
            print("MEASURED \(edge.description)")
        }
        let height = extent("account", "height", from: vertical.low, to: vertical.high,
                            requirement: 44)
        let width = extent("account", "width", from: horizontal.low, to: horizontal.high,
                           requirement: 44)
        print("MEASURED VERDICT account height=\(height?.verdict ?? "UNRESOLVED") "
              + "width=\(width?.verdict ?? "UNRESOLVED")")

        // Recorded, not asserted into a pass. A shortfall in a bar UIKit lays
        // out is a finding about where the control lives, and a run that goes
        // red on it hides the four numbers underneath a failure message.
        XCTAssertNotNil(height ?? width, "neither boundary pair could be closed")
    }

    // MARK: - Sign out, inside the account menu

    /// The row that ends the session, which is now somewhere we lay out.
    ///
    /// Every activating probe here costs a sign-in, and that is the point of
    /// the control having moved: when it lived in the navigation bar its
    /// height came out as an interval straddling 44 that no tap could close,
    /// because the bar owned the layout and `.frame`, padding and
    /// `.contentShape` at the call site all moved nothing. Here the height is
    /// `Layout.minTouchTarget + Spacing.m` — 56 — set by a `.contentShape` on
    /// the label, and the instrument has to read a number that is plainly not
    /// 44. That is the "obviously larger target" half of the control group;
    /// the 24pt gap in the feed is the obviously smaller half.
    ///
    /// The row is full width, so the horizontal search is expected to run off
    /// both ends of the window and report UNRESOLVED. That is a third kind of
    /// answer, and an instrument that produced a confident number there would
    /// be inventing one.
    func testSignOutRowHitRegionBoundaries() {
        let app = XCUIApplication()
        XCTAssertTrue(launchSignedInForProbing(app), "could not sign in")
        let conditions = conditions(app)
        XCTAssertTrue(arriveAtAccountMenu(app), "could not open the account menu")

        let row = app.buttons["session.signOut"]
        let frame = row.frame
        print("MEASURED session.signOut reported(accessibility) frame = \(frame)")

        let centre = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertEqual(
            probeSignOutRow(app, at: centre, anchor: frame), .activated,
            "the centre of the sign-out row does not end the session"
        )
        let vertical = edgesOnAxis("signOut", centre: centre, reach: 48, vertical: true,
                                   conditions: conditions) {
            self.probeSignOutRow(app, at: $0, anchor: frame)
        }
        // Deliberately wider than the window: the limits clamp to its edges, so
        // this asks "does the region reach the side of the screen" in one probe
        // per side rather than bisecting towards an answer that is not there.
        let horizontal = edgesOnAxis("signOut", centre: centre, reach: conditions.window.width,
                                     vertical: false, conditions: conditions) {
            self.probeSignOutRow(app, at: $0, anchor: frame)
        }

        print("MEASURED ---- sign-out row ----")
        print("MEASURED \(conditions.summary)")
        for edge in [vertical.low, vertical.high, horizontal.low, horizontal.high] {
            print("MEASURED \(edge.description)")
        }
        let height = extent("signOut", "height", from: vertical.low, to: vertical.high,
                            requirement: 44)
        let width = extent("signOut", "width", from: horizontal.low, to: horizontal.high,
                           requirement: 44)
        print("MEASURED VERDICT signOut height=\(height?.verdict ?? "UNRESOLVED") "
              + "width=\(width?.verdict ?? "UNRESOLVED")")

        guard let height else {
            XCTFail("the sign-out row's height could not be closed")
            return
        }
        // 44 + Spacing.m by construction. This is our layout, so a shortfall
        // here is a defect rather than a finding about UIKit.
        XCTAssertGreaterThanOrEqual(
            height.atLeast, 44,
            "the control that ends the session is under the 44pt minimum: \(height.description)"
        )
        // And the reading has to be *distinguishable* from 44, or it says
        // nothing about the instrument's resolution.
        XCTAssertGreaterThan(
            height.atLeast, 50,
            "a row laid out at 56pt read as if it were the 44pt minimum: \(height.description)"
        )
    }

    // MARK: - The system back button

    /// UIKit's own back button: created by the navigation controller, not by
    /// any `ToolbarItem` of ours.
    ///
    /// Measured on its own account. Sharing a bar with another control is not
    /// sharing a hit region — an earlier round asserted that it was, and the
    /// two were then found to disagree about whether a given point activates.
    func testBackButtonHitRegionBoundaries() {
        let app = XCUIApplication()
        XCTAssertTrue(launchSignedInForProbing(app), "could not sign in")
        let conditions = conditions(app)
        XCTAssertTrue(arriveAtDetail(app), "could not open a post")

        let back = Self.backButton(inDetailBarOf: app)
        XCTAssertTrue(frameSettled(back), "the navigation bar is still moving")
        let frame = back.frame
        print("MEASURED back reported(accessibility) frame = \(frame)")
        XCTAssertLessThan(frame.width, 60,
                          "this is not the back button — \(frame.size) is the wrong shape for it")

        let centre = CGPoint(x: frame.midX, y: frame.midY)
        // If the centre does not activate, everything below is measuring some
        // other control and the search would still return boundaries for it.
        XCTAssertEqual(
            probeBackButton(app, at: centre, anchor: frame), .activated,
            "the centre of the button does not activate it; this probe is not measuring this control"
        )
        let vertical = edgesOnAxis("back", centre: centre, reach: 44, vertical: true,
                                   conditions: conditions) {
            self.probeBackButton(app, at: $0, anchor: frame)
        }
        let horizontal = edgesOnAxis("back", centre: centre, reach: 70, vertical: false,
                                     conditions: conditions) {
            self.probeBackButton(app, at: $0, anchor: frame)
        }

        print("MEASURED ---- back button ----")
        print("MEASURED \(conditions.summary)")
        for edge in [vertical.low, vertical.high, horizontal.low, horizontal.high] {
            print("MEASURED \(edge.description)")
        }
        let height = extent("back", "height", from: vertical.low, to: vertical.high, requirement: 44)
        let width = extent("back", "width", from: horizontal.low, to: horizontal.high, requirement: 44)
        print("MEASURED VERDICT back height=\(height?.verdict ?? "UNRESOLVED") "
              + "width=\(width?.verdict ?? "UNRESOLVED")")

        // Recorded, not asserted into a pass — see the account entry above.
        XCTAssertNotNil(height ?? width, "neither boundary pair could be closed")

        // --- and separately from the §6.4 verdict: this control is the one
        // place in the app where the hit region and the frame are the same
        // rectangle, so it is the instrument's exactness check.
        //
        // UIKit lays this button out at 44x44 and gives it no expansion — the
        // bar is crowded, and 44 is already the minimum a bar item is grown
        // to. Every other control measured in this file reads larger than its
        // frame (the account entry is grown from 30x36 to 44x44; the feed's
        // buttons and the sign-out row are given room around them). If *this*
        // one also read larger, the excess would be the instrument's and not
        // the platform's, and every other figure in this file would be worth
        // nothing.
        //
        // Two brackets of slack, which is the most two bisections can leave
        // open. Asserted rather than recorded because it says nothing about
        // the product: a failure here is a defect in the measuring, which is
        // exactly the kind of failure that should stop a run.
        let slack = 2 * conditions.tolerance
        for (name, measured, expected) in [
            ("top", vertical.low.inside, frame.minY),
            ("bottom", vertical.high.inside, frame.maxY),
            ("left", horizontal.low.inside, frame.minX),
            ("right", horizontal.high.inside, frame.maxX)
        ] {
            XCTAssertLessThanOrEqual(
                abs(measured - expected), slack,
                "the instrument put the back button's \(name) boundary at \(fmt(measured)), "
                + "and the button UIKit laid out has it at \(fmt(expected)). This control has "
                + "no expansion around it, so the difference is the instrument's."
            )
        }
    }
}
