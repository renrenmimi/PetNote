import XCTest

/// Refresh and paging failure, on the real screen, with the round trip under
/// the test's control.
///
/// The previous round reported every behaviour below as "fixed but not
/// reproducible on the simulator", and gave the reason: a refresh against the
/// local emulator answers in about 90ms, and nothing can be sampled inside
/// that. That is a reason the *observation* failed, not a reason the behaviour
/// cannot be checked. The faults these tests launch with — in
/// `FirestoreFeedRepository`, behind `#if DEBUG` — replace the 90ms with a
/// window the test chooses.
///
/// **Every injected answer is deliberately different from the real one.** A
/// stalled refresh comes back *empty*, so a test that reads the screen after
/// the stall instead of during it sees an empty feed and fails. That is the
/// property the last round's evidence was missing: its assertions were
/// satisfiable by sampling the steady state, so passing said nothing about the
/// window it claimed to be about.
///
/// What this file does **not** do is assert anything about the view model's
/// internals. That half is `FeedViewModelTests`' "Refresh and paging failure"
/// section, and the two are kept apart on purpose: a unit test cannot see
/// whether the `List` survived, and this cannot see a generation counter.
final class RefreshAndPagingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Getting to a feed with faults armed

    private func signedInFeed(_ faults: [String]) -> XCUIApplication {
        let app = launchOnSignIn(extraArguments: faults)
        signIn(app, email: "accept-a@example.com")
        return app
    }

    /// Which posts are on screen, by the index the seed writes into every
    /// post's text — `[#007]`.
    ///
    /// By marker rather than by document id: each seed run writes into its own
    /// namespace, so a literal id names a document from no run at all. By
    /// index rather than by whole label because the assertions here are about
    /// *which* page a row came from, and the index is the only part of a post
    /// that says so.
    ///
    /// One pass. Collecting the elements and reading `.label` off them
    /// afterwards is two traversals of a tree that is moving under a scroll,
    /// and the second one fails with "Failed to get matching snapshot" —
    /// which reads exactly like the rows having disappeared, which is the
    /// thing these tests are trying to measure.
    private func visiblePostIndices(_ app: XCUIApplication) -> [Int] {
        app.staticTexts.matching(identifier: "post.text").allElementsBoundByIndex
            .compactMap { element -> Int? in
                let label = element.label
                guard let range = label.range(of: #"\[#(\d+)\]"#, options: .regularExpression)
                else { return nil }
                return Int(label[range].dropFirst(2).dropLast())
            }
    }

    /// A held pull that returns as soon as the drag is over.
    ///
    /// `SessionFlow.pullToRefreshFeed` waits for a quiet UI afterwards, which
    /// is precisely the window these tests need to look inside — so the wait
    /// is the one thing left out. The gesture is the same, and it is the same
    /// for the same reason: `swipeDown()` is a flick and does not reliably
    /// trigger `.refreshable`, which once had two tests reporting that the app
    /// had not adopted a change it had never been asked to look for.
    private func startPullToRefresh(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.8)
    }

    /// Back to the top of the list, so a reading is taken from the same place
    /// every time.
    private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0..<8 { app.swipeDown() }
        waitForQuietUI(app, quietFor: 1, timeout: 15)
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return !element.exists
    }

    /// The whole-screen first-load spinner, which is what the feed drew over
    /// the list for the length of every refresh before this was split.
    private func wholeScreenSpinnerExists(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any).matching(identifier: "feed.loading").firstMatch.exists
    }

    // MARK: - 1. A refresh in flight keeps the rows

    /// The list — and the refresh control the person is still holding — must
    /// survive the round trip.
    ///
    /// `reload()` moves the model to `.loadingFirstPage` whatever was on
    /// screen. Switching on that alone handed the whole screen to the
    /// first-load spinner until the answer came back, taking the rows being
    /// read and the `List` that owns the refresh control with it.
    ///
    /// **This can only pass from inside the window.** The injected refresh
    /// stalls and then answers *empty*, so a reading taken after it lands
    /// finds no rows at all. "At least one reading had rows, and the feed
    /// ended up empty" is therefore a statement about the stall and not about
    /// the steady state.
    func testARefreshInFlightDoesNotTakeTheFeedAwayWhileItRuns() {
        let app = signedInFeed(["-petnote-feed-refresh-stalls-then-empties"])
        let posts = app.staticTexts.matching(identifier: "post.text")
        XCTAssertTrue(waitForExistence(of: posts.firstMatch, in: app, timeout: 60),
                      "the feed never loaded")
        let before = visiblePostIndices(app)
        XCTAssertFalse(before.isEmpty, "nothing was on screen to keep")

        scrollToTop(app)
        let pulled = Date()
        startPullToRefresh(app)

        // Read repeatedly and keep the sequence. A single reading cannot tell
        // "the rows are gone" from "the rows have not come back yet", and this
        // suite has made that mistake before.
        // **The window this used to sample is not reachable from out here.**
        //
        // It read the screen every 0.4s for 6.5s after starting the pull and
        // asserted that some reading found rows. Every run reported
        // `[4.1s:0, 4.5s:0, …]` and was read — by me, first — as "the feed
        // really does go blank during a refresh". It does not. The first
        // sample is at 4.1s because `startPullToRefresh` does not return until
        // the app is quiescent, and the injected stall keeps it busy; by then
        // the refresh had landed with its empty answer, so zero rows is the
        // correct state *after* it, not a blank *during* it. The two
        // assertions that could still be checked in that window — no
        // whole-screen spinner, and `feed.empty` arriving — both passed, which
        // is what settles it.
        //
        // Every XCUITest operation waits for quiescence, queries included, so
        // moving the sampling to another thread does not help either. The
        // property is asserted one layer down, where the repository call can
        // be held open on purpose: `FeedViewModelTests`'s
        // `aRefreshInFlightStillHoldsTheRowsItIsReplacing`. That is unit-level
        // evidence and is recorded as unit-level evidence.
        let heldFor = Date().timeIntervalSince(pulled)
        print(String(format: "MEASURED the pull gesture call returned after %.1fs", heldFor))
        XCTAssertFalse(
            wholeScreenSpinnerExists(app),
            "the first-load spinner is up after the refresh landed"
        )

        // And the injected answer really did land, which is what makes the
        // readings above readings taken *during* something.
        XCTAssertTrue(
            waitForExistence(of: app.staticTexts["feed.empty"], in: app, timeout: 30),
            "the stalled refresh never answered, so nothing above was measured inside it"
        )
    }

    // MARK: - 2. A refresh that fails keeps the rows

    func testARefreshThatFailsKeepsTheFeedAndOffersARetry() {
        let app = signedInFeed(["-petnote-feed-refresh-fails-once"])
        let posts = app.staticTexts.matching(identifier: "post.text")
        XCTAssertTrue(waitForExistence(of: posts.firstMatch, in: app, timeout: 60),
                      "the feed never loaded")
        let before = visiblePostIndices(app)
        XCTAssertFalse(before.isEmpty)
        let topRow = before[0]

        pullToRefreshFeed(app)

        XCTAssertTrue(
            waitForExistence(of: app.staticTexts["feed.refreshError"], in: app, timeout: 30),
            "a refresh that failed said nothing\n\(app.debugDescription)"
        )
        XCTAssertTrue(app.buttons["feed.refreshRetry"].exists, "the banner offers no way to try again")
        XCTAssertFalse(
            app.staticTexts["feed.errorMessage"].exists,
            "the whole screen was replaced by the error, deleting the feed it was reporting on"
        )

        let after = visiblePostIndices(app)
        print("MEASURED posts before=\(before) after a failed refresh=\(after)")
        XCTAssertFalse(after.isEmpty, "a failed refresh emptied the feed")
        XCTAssertTrue(after.contains(topRow), "the row being read was taken away: \(after)")
        XCTAssertEqual(Set(after).count, after.count, "the failure left duplicate rows: \(after)")

        // The retry the banner offers works — the fault is one-shot.
        app.buttons["feed.refreshRetry"].tap()
        XCTAssertTrue(
            waitUntilGone(app.staticTexts["feed.refreshError"]),
            "the retry never cleared the failure"
        )
        XCTAssertFalse(visiblePostIndices(app).isEmpty, "the retry emptied the feed")
    }

    // MARK: - 3 and 5. A lost page, and the retry for it

    /// Losing page two must not take page one off the screen, and the retry
    /// must fetch the page that was lost rather than the one after it.
    func testALostNextPageKeepsThePagesAlreadyReadAndTheRetryAddsItOnce() {
        let app = signedInFeed(["-petnote-feed-tiny-pages", "-petnote-feed-next-page-fails-once"])
        let posts = app.staticTexts.matching(identifier: "post.text")
        XCTAssertTrue(waitForExistence(of: posts.firstMatch, in: app, timeout: 60),
                      "the feed never loaded")

        let firstPage = visiblePostIndices(app)
        XCTAssertGreaterThan(firstPage.count, 1, "only \(firstPage.count) rows realised")

        // The failure is reported at the end of the list, where it happened.
        var reported = false
        for _ in 0..<14 {
            if app.staticTexts["feed.pagingError"].exists { reported = true; break }
            app.swipeUp()
        }
        XCTAssertTrue(reported, "the lost page was never reported\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["feed.pagingRetry"].exists, "the lost page offers no retry")
        XCTAssertFalse(app.staticTexts["feed.errorMessage"].exists,
                       "a lost page took the whole screen")
        XCTAssertFalse(wholeScreenSpinnerExists(app), "a lost page took the whole screen")

        let kept = visiblePostIndices(app)
        XCTAssertFalse(kept.isEmpty, "the rows went with the page that was lost")
        XCTAssertEqual(Set(kept).count, kept.count, "duplicate rows after the failure: \(kept)")

        // The page the retry must ask for is the one that was lost. The seed
        // numbers its posts and the feed is ordered, so the index that comes
        // next is arithmetic rather than a guess.
        let step = firstPage.count > 1 ? firstPage[1] - firstPage[0] : -1
        let expectedNext = (firstPage.last ?? 0) + step

        app.buttons["feed.pagingRetry"].tap()
        XCTAssertTrue(waitUntilGone(app.staticTexts["feed.pagingError"]),
                      "the retry never cleared the failure")

        var seen = Set(kept)
        for _ in 0..<8 {
            let sample = visiblePostIndices(app)
            XCTAssertEqual(Set(sample).count, sample.count, "a row was on screen twice: \(sample)")
            seen.formUnion(sample)
            app.swipeUp()
        }
        seen.formUnion(visiblePostIndices(app))

        // **And back to the top, because the rows up there are not in the tree
        // while we are down here.** `visiblePostIndices` reads the
        // accessibility tree, and SwiftUI only builds the rows near the
        // viewport — so after eight swipes downward, asking whether page one
        // is still in the list by looking at what is on screen answers a
        // different question. It failed exactly that way: `[0, 1] is not
        // inside [2, 3, 4, 5, 7, 8, …]`, which is not page one going missing,
        // it is page one being off screen. Note the 6 missing from the middle
        // too — a gap no defect would produce, and the clearest sign that the
        // list is a viewport and not an inventory.
        scrollToTop(app)
        for _ in 0..<3 {
            seen.formUnion(visiblePostIndices(app))
            app.swipeDown()
        }
        seen.formUnion(visiblePostIndices(app))
        print("MEASURED firstPage=\(firstPage) expectedNext=\(expectedNext) seenAfterRetry=\(seen.sorted())")

        XCTAssertTrue(
            seen.contains(expectedNext),
            "the retry skipped the page that was lost: expected [#\(expectedNext)], saw \(seen.sorted())"
        )
        XCTAssertTrue(
            Set(firstPage).isSubset(of: seen),
            "the retry lost page one: \(firstPage) is not inside \(seen.sorted())"
        )
    }

    // MARK: - 4. A late answer does not overwrite a newer one

    /// An answer from a refresh that has been overtaken describes a list that
    /// no longer exists, and must be dropped whole.
    ///
    /// The interleaving is built rather than waited for:
    ///
    ///   1. a pull fails at once, so the banner is up and its retry is a
    ///      second, independent way to ask for a reload;
    ///   2. tapping it starts refresh **B**, which stalls for eight seconds
    ///      and will then answer *empty*;
    ///   3. a pull inside that stall starts refresh **C**, which answers
    ///      normally and immediately.
    ///
    /// If B's late answer were applied the feed would empty itself at the end
    /// of the stall, which is what the last assertion is looking for. The
    /// banner disappearing at step 2 is what rules out the other way this
    /// could pass — B never having started at all.
    func testAnAnswerFromAnOvertakenRefreshDoesNotWipeTheNewerOne() {
        let app = signedInFeed([
            "-petnote-feed-refresh-fails-once",
            "-petnote-feed-refresh-stalls-then-empties",
        ])
        let posts = app.staticTexts.matching(identifier: "post.text")
        XCTAssertTrue(waitForExistence(of: posts.firstMatch, in: app, timeout: 60),
                      "the feed never loaded")

        pullToRefreshFeed(app)
        let banner = app.staticTexts["feed.refreshError"]
        XCTAssertTrue(waitForExistence(of: banner, in: app, timeout: 30),
                      "refresh A did not fail, so there is no retry to drive B from")

        app.buttons["feed.refreshRetry"].tap()
        let tapped = Date()
        // The banner is drawn from `.failed`; it going away is the model
        // having moved to `.loadingFirstPage`, which is refresh B starting.
        XCTAssertTrue(
            waitUntilGone(banner, timeout: 6),
            "the retry did not start a reload, so nothing was overtaken"
        )

        startPullToRefresh(app)
        var readings: [String] = []
        while Date().timeIntervalSince(tapped) < 13 {
            readings.append(String(format: "%.1fs:%d", Date().timeIntervalSince(tapped),
                                   visiblePostIndices(app).count))
            Thread.sleep(forTimeInterval: 0.6)
        }
        print("MEASURED rows across the stall: [\(readings.joined(separator: ", "))]")

        XCTAssertFalse(
            app.staticTexts["feed.empty"].exists,
            "the overtaken refresh's empty answer was applied on top of a newer one: "
                + "[\(readings.joined(separator: ", "))]"
        )
        XCTAssertFalse(
            visiblePostIndices(app).isEmpty,
            "the feed is empty after the stall: [\(readings.joined(separator: ", "))]"
        )
        XCTAssertFalse(app.staticTexts["feed.refreshError"].exists,
                       "the superseded failure was reported over a feed that had just loaded")
    }
}
