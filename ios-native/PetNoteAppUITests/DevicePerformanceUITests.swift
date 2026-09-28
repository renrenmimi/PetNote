import XCTest

/// Launch, scrolling and memory on the phone, measured by XCTest's own metrics.
///
/// XCTest prints each result itself ("measured [Duration (AppLaunch), s]
/// average: …, values: […]"); `scripts/device-acceptance.sh` collects those
/// lines. What is printed here as MEASURED is the context a number needs to
/// mean anything: how many times the block ran, whether each launch reached
/// the screen it was supposed to, how far each stretch of scrolling went.
///
/// **What these numbers are, and are not** (docs/perf-baseline.md sets the
/// boundaries):
///
///   - They are from `Debug-TestCloud`, built `-Onone`. A baseline for that
///     build, not a statement about a release.
///   - The launch metric ends at the first frame iOS draws. That is not
///     perf-baseline's "cold start", which ends at the first frame holding
///     real feed content; for the signed-in launch the time to the first post
///     is printed beside it, by the wall clock, with XCUITest's own waiting in
///     it.
///   - Every launch here follows a terminated process, so after the first
///     the system's caches are warm. A cold launch in Apple's sense needs a
///     restart, which a test cannot do.
///   - Five iterations: enough to see an average and its spread, not enough
///     for the p95 that perf-baseline asks twenty samples for.
///
/// Nothing here writes to the server: signing in, launching, scrolling and
/// reading are all it does.
final class DevicePerformanceUITests: XCTestCase {
    private static let iterations = 5
    /// Fast swipes per scrolling iteration.
    private static let flingsPerIteration = 3
    /// Posts each memory iteration scrolls past.
    private static let postsPerMemoryIteration = 40

    override func setUpWithError() throws {
        continueAfterFailure = false
        // A simulator's launch time, frame pacing and memory describe the Mac
        // it runs on (perf-baseline: 模拟器的数字不替代真机的启动、帧率、内存).
        #if targetEnvironment(simulator)
        throw XCTSkip("device performance — a simulator's numbers are the Mac's")
        #endif
    }

    private func measureOptions(manual: Bool = false) -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = Self.iterations
        if manual { options.invocationOptions = [.manuallyStart, .manuallyStop] }
        return options
    }

    // MARK: - Launch

    /// From a terminated process to the sign-in screen. Signed out on purpose
    /// by the launch flag, so every launch lands on the same screen.
    func testLaunchToTheSignInScreen() {
        var runs = 0
        var reachedSignIn: [Bool] = []
        measure(metrics: [XCTApplicationLaunchMetric()], options: measureOptions()) {
            let app = XCUIApplication()
            app.launchArguments = ["-petnote-start-signed-out"]
            app.launch()
            runs += 1
            reachedSignIn.append(app.staticTexts["login.title"].waitForExistence(timeout: 30))
        }
        print("MEASURED launch to sign-in: the block ran \(runs) time(s) for \(Self.iterations) iteration(s); "
              + "reached sign-in: \(reachedSignIn.map { $0 ? "yes" : "NO" }.joined(separator: ","))")
        XCTAssertFalse(reachedSignIn.isEmpty, "the measurement never launched the app")
        XCTAssertFalse(reachedSignIn.contains(false),
                       "a launch did not reach the sign-in screen, so its number is not a launch to sign-in")
    }

    /// The launch a person has most days: signed in already, straight to the
    /// feed. Signs in once by typing, then measures launches that restore
    /// that session.
    func testLaunchOfASignedInSession() {
        let first = deviceSignedInApp()
        XCTAssertTrue(first.staticTexts.matching(identifier: "post.text").firstMatch.waitForExistence(timeout: 90),
                      "the feed never loaded before measuring")
        first.terminate()

        var runs = 0
        var outcomes: [String] = []
        var landedOnFeed: [Bool] = []
        measure(metrics: [XCTApplicationLaunchMetric()], options: measureOptions()) {
            let app = XCUIApplication()
            app.launchArguments = []
            let started = Date()
            app.launch()
            runs += 1
            let feed = app.navigationBars["PetNote"].waitForExistence(timeout: 30)
            let post = feed && app.staticTexts.matching(identifier: "post.text").firstMatch.waitForExistence(timeout: 60)
            let seconds = Date().timeIntervalSince(started)
            landedOnFeed.append(feed && !app.staticTexts["login.title"].exists)
            outcomes.append(post ? String(format: "%.2fs", seconds) : (feed ? "feed, no post" : "no feed"))
        }
        print("MEASURED signed-in launch: the block ran \(runs) time(s) for \(Self.iterations) iteration(s)")
        print("MEASURED   rough wall clock from launch() to the first post (XCUITest's own waiting included, "
              + "not the metric): \(outcomes.joined(separator: ", "))")
        XCTAssertFalse(landedOnFeed.isEmpty, "the measurement never launched the app")
        XCTAssertFalse(landedOnFeed.contains(false),
                       "a launch did not restore the session to the feed, so its number is not a signed-in launch")
    }

    // MARK: - Scrolling

    /// Hitches while the feed decelerates after fast swipes, the
    /// measurement Apple's scroll metric makes. Only the swipes are inside
    /// the measurement; going back up for the next iteration is not.
    func testScrollingTheFeedWithFastSwipes() {
        let app = deviceSignedInApp()
        XCTAssertTrue(app.staticTexts.matching(identifier: "post.text").firstMatch.waitForExistence(timeout: 90),
                      "the feed never loaded")
        let list = deviceFeedList(app)
        XCTAssertTrue(list.exists, "no feed list to scroll\n\(app.debugDescription)")
        waitForQuietUI(app, quietFor: 2, timeout: 15)

        let flings = Self.flingsPerIteration
        var runs = 0
        var stretches: [String] = []
        var moved: [Bool] = []
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: measureOptions(manual: true)) {
            runs += 1
            let before = self.deviceVisiblePostTexts(app)
            self.startMeasuring()
            for _ in 0..<flings { list.swipeUp(velocity: .fast) }
            self.stopMeasuring()
            let after = self.deviceVisiblePostTexts(app)
            moved.append(!after.isEmpty && after != before)
            stretches.append("\(seedRange(before))→\(seedRange(after))")
            // Back to where it began, so each iteration scrolls the same
            // stretch of the feed rather than a new one that has to load.
            for _ in 0..<flings { list.swipeDown(velocity: .fast) }
            self.waitForQuietUI(app, quietFor: 1, timeout: 15)
        }
        print("MEASURED fast scrolling: the block ran \(runs) time(s) for \(Self.iterations) iteration(s), "
              + "\(Self.flingsPerIteration) fast swipes each")
        print("MEASURED   visible posts by seed index, before→after each measured stretch: "
              + stretches.joined(separator: "  "))
        XCTAssertEqual(app.state, .runningForeground, "the app did not survive the scrolling")
        XCTAssertTrue(moved.contains(true), "the feed never moved, so there was no deceleration to measure")
    }

    // MARK: - Memory

    /// The app's memory while it scrolls through about forty posts, five
    /// times, each stretch continuing from where the last one stopped — so
    /// the five numbers also say whether each forty costs more than the
    /// forty before (images and players that are never let go).
    ///
    /// Posts are counted as distinct texts that came on screen, not as
    /// swipes: a swipe's distance depends on the cards it passes. Reading the
    /// texts is itself an accessibility query and costs the app a little
    /// memory; it is the same cost in every iteration.
    func testMemoryWhileScrollingThroughFortyPosts() {
        let app = deviceSignedInApp()
        XCTAssertTrue(app.staticTexts.matching(identifier: "post.text").firstMatch.waitForExistence(timeout: 90),
                      "the feed never loaded")
        let list = deviceFeedList(app)
        XCTAssertTrue(list.exists, "no feed list to scroll\n\(app.debugDescription)")
        waitForQuietUI(app, quietFor: 2, timeout: 15)

        let target = Self.postsPerMemoryIteration
        var runs = 0
        var stretches: [String] = []
        var counted: [Int] = []
        measure(metrics: [XCTMemoryMetric(application: app)], options: measureOptions()) {
            runs += 1
            let firstSeen = self.deviceVisiblePostTexts(app)
            var seen = Set(firstSeen)
            var swipes = 0
            var stalled = 0
            var last = firstSeen
            while seen.count < target, swipes < 80, stalled < 4 {
                list.swipeUp()
                swipes += 1
                last = self.deviceVisiblePostTexts(app)
                let before = seen.count
                seen.formUnion(last)
                stalled = seen.count == before ? stalled + 1 : 0
            }
            counted.append(seen.count)
            stretches.append("#\(runs): \(seen.count) posts in \(swipes) swipes, "
                             + "\(seedRange(firstSeen))→\(seedRange(last))"
                             + (stalled >= 4 ? " (stopped moving: end of the feed?)" : ""))
        }
        print("MEASURED memory while scrolling: the block ran \(runs) time(s) for \(Self.iterations) iteration(s), "
              + "about \(Self.postsPerMemoryIteration) posts each")
        for stretch in stretches { print("MEASURED   \(stretch)") }
        XCTAssertEqual(app.state, .runningForeground, "the app did not survive the scrolling")
        XCTAssertGreaterThan(counted.first ?? 0, 1, "the first stretch saw no posts go by, so it measured nothing")
    }
}

/// The seed writes each post's index into its text, `[#007]`; the lowest and
/// highest on screen say where in the feed a reading was taken. Posts without
/// one (written by other tests) are left out. A plain function, so the
/// measure blocks can call it without reaching for the test case.
private func seedRange(_ texts: [String]) -> String {
    let indices = texts.compactMap { text -> Int? in
        guard let range = text.range(of: #"\[#(\d+)\]"#, options: .regularExpression) else { return nil }
        return Int(text[range].dropFirst(2).dropLast())
    }
    guard let low = indices.min(), let high = indices.max() else { return "?" }
    return low == high ? "\(low)" : "\(low)-\(high)"
}

extension XCTestCase {
    /// The feed's list. A SwiftUI `List` is a collection view to XCUITest;
    /// anything carrying the identifier is the fallback.
    func deviceFeedList(_ app: XCUIApplication) -> XCUIElement {
        let asCollection = app.collectionViews["feed.list"]
        if asCollection.waitForExistence(timeout: 10) { return asCollection }
        return app.descendants(matching: .any).matching(identifier: "feed.list").firstMatch
    }

    /// The texts of the posts whose text is inside the window, read in the
    /// same pass that selects them (TestHygieneTests: a second pass over
    /// collected elements reads a tree that has moved).
    func deviceVisiblePostTexts(_ app: XCUIApplication) -> [String] {
        let window = app.windows.firstMatch.frame
        return app.staticTexts.matching(identifier: "post.text").allElementsBoundByIndex
            .compactMap { element -> String? in
                guard element.exists else { return nil }
                let frame = element.frame
                guard !frame.isEmpty, window.intersects(frame) else { return nil }
                return element.label
            }
    }
}
