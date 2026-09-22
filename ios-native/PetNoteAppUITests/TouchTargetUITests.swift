import XCTest

/// What a single probe saw.
///
/// Three outcomes and not a boolean, because "the tap landed on the card
/// behind the button and opened the post" and "the tap did nothing" are
/// different facts, and a boolean loses the one that proves the coordinates
/// were real. The fourth is not an outcome at all — it says the point is off
/// the window and cannot be tapped.
///
/// **`somethingElse` was unreachable for the whole of the last round.** The
/// branch tested `app.otherElements["image.full"]`, a name the app never sets,
/// and `app.buttons["full.close"]`, whose real name is `fullImage.close`. A
/// name that does not exist reports `exists == false`, which is
/// indistinguishable from "that control is not on screen" — so a probe that
/// opened the full-screen photo was filed as `nothing`. `nothing` is where the
/// control group draws its negative samples, so the one assertion that was
/// supposed to prove the probe could tell inside from outside could be
/// satisfied by the misclassification itself. `IdentifierGuardTests` now fails
/// the build for an invented identifier; `testEachOutcomeIsReachable` below
/// fails it for an outcome nothing can produce.
enum TouchOutcome: String {
    /// The control being probed activated.
    case activated
    /// A different control activated — proof the tap landed somewhere real.
    case somethingElse
    /// The tap landed and nothing observable happened, **confirmed** rather
    /// than assumed: see `watchForChange`.
    case nothing
    /// Outside the window. A limit of the screen, not a measurement.
    case offWindow
}

/// What it took to see that outcome. Printed with every probe so a reading can
/// be argued with afterwards.
struct TouchWatch {
    let outcome: TouchOutcome
    let samples: Int
    let elapsed: TimeInterval

    var trace: String {
        String(format: "%@ after %d samples / %.2fs", outcome.rawValue, samples, elapsed)
    }
}

// MARK: - The instrument

/// Driving the app for a touch-target measurement, and classifying what came
/// back.
///
/// Kept apart from `HitRegionBoundaryUITests` on purpose: that file is the
/// *search* — where a boundary is, in absolute window coordinates — and this
/// one is the *instrument* the search calls. The self-tests at the bottom of
/// this file are the instrument's own; they have to pass before any number the
/// search prints means anything.
extension XCTestCase {

    // MARK: Waiting for a change, rather than sleeping through one

    /// Polls for an outcome instead of sleeping a fixed time and reading once.
    ///
    /// **The single read was the defect.** `tap()` then `Thread.sleep(2.0)`
    /// then one read cannot tell "it did not change" from "it has not changed
    /// yet", and on a loaded machine the second is common — this machine has
    /// four agents on it and a load average that has been over 7. Every such
    /// false negative does two things at once: it moves a measured boundary
    /// *inwards*, so the region reads smaller than it is, and it hands the
    /// control group a negative sample it did not earn, so "the probe can tell
    /// inside from outside" starts being satisfied by the machine being busy.
    ///
    /// So a positive returns as soon as it is seen, and a negative is only
    /// returned once **both** floors are met: `minSamples` observations *and*
    /// `minSeconds` of wall clock. Two conditions rather than one larger
    /// number, because under load the sample count is reached while nothing
    /// has had time to happen, and when the machine is idle the clock runs out
    /// while the tree has barely been read.
    func watchForChange(
        minSamples: Int = 10,
        minSeconds: TimeInterval = 2.0,
        deadline: TimeInterval = 10,
        _ read: () -> TouchOutcome?
    ) -> TouchWatch {
        let start = Date()
        var samples = 0
        while true {
            samples += 1
            if let outcome = read() {
                return TouchWatch(
                    outcome: outcome, samples: samples, elapsed: Date().timeIntervalSince(start)
                )
            }
            let elapsed = Date().timeIntervalSince(start)
            if samples >= minSamples, elapsed >= minSeconds {
                return TouchWatch(outcome: .nothing, samples: samples, elapsed: elapsed)
            }
            if elapsed >= deadline {
                return TouchWatch(outcome: .nothing, samples: samples, elapsed: elapsed)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// Polls a condition and **hands the answer back rather than failing**.
    ///
    /// Named for what it returns, not for what it waits on. There are two
    /// other `waitUntil` helpers in this project — `TestVideoFixture` and
    /// `ImageLoaderTests`, both in the unit test target — and both of them
    /// fail the test on a timeout: one throws `WaitedTooLong`, the other
    /// records an issue. A third with the same name and the opposite contract
    /// is how a missing `if` turns into a test that can never go red, and
    /// `ClaimGuardTests` allowlists those helpers **by name**, so the name
    /// being shared would have punched a hole in that allowlist. Hence a name
    /// a reader has to assign.
    @discardableResult
    func becomesTrue(within seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    /// Waits until an element's rectangle stops moving.
    ///
    /// A sheet that has just been presented has its controls in the tree while
    /// it is still sliding, so a frame read then is a frame of where the row is
    /// *going to be*. Absolute coordinates derived from it name a place the
    /// control never occupies. Three consecutive equal reads rather than a
    /// fixed sleep, for the same reason the probes poll.
    @discardableResult
    func frameSettled(
        _ element: XCUIElement, tolerance: CGFloat = 0.5, timeout: TimeInterval = 10
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: CGRect?
        var stable = 0
        while Date() < deadline {
            guard element.exists else { return false }
            let frame = element.frame
            if let previous,
               abs(frame.minY - previous.minY) <= tolerance,
               abs(frame.minX - previous.minX) <= tolerance,
               abs(frame.height - previous.height) <= tolerance,
               abs(frame.width - previous.width) <= tolerance {
                stable += 1
                if stable >= 3 { return true }
            } else {
                stable = 0
            }
            previous = frame
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }

    // MARK: What can be on top of the screen

    /// The full-screen photo viewer. Named by the identifier the app actually
    /// sets — the whole point of `IdentifierGuardTests`.
    func fullImageCoverIsUp(_ app: XCUIApplication) -> Bool {
        app.buttons["fullImage.close"].exists
    }

    /// The account menu sheet, by the one control that only it has.
    func accountMenuIsUp(_ app: XCUIApplication) -> Bool {
        app.buttons["session.signOut"].exists
    }

    /// Closes the account menu with the menu's own Close button.
    ///
    /// Deliberately `account.close` and not the drag in `SessionFlow`: the
    /// button is the product's own way out and it is in the tree, whereas the
    /// drag is a gesture that has to start somewhere, and the only place it can
    /// start is above a row that ends the session. The drag stays as the
    /// fallback for the case where the button will not take a tap.
    func closeAccountMenuByItsOwnButton(_ app: XCUIApplication) {
        let close = app.buttons["account.close"]
        if waitUntilHittable(close, in: app, timeout: 5) { close.tap() }
        if becomesTrue(within: 6, { !accountMenuIsUp(app) }) { return }
        closeAccountMenu(app)
    }

    /// Clears anything a probe can have put on top of the screen, and **checks
    /// that it went**.
    ///
    /// The version this replaces looked once, tapped once, slept half a second
    /// and returned nothing. A cover that was still presenting when it looked
    /// was not seen; a tap that missed was not noticed; and either way the next
    /// probe was taken through a screen it could not see past. Every probe
    /// after that one is a miss, which is the bias this whole file exists to
    /// remove.
    @discardableResult
    func clearProbeOverlays(_ app: XCUIApplication) -> Bool {
        dismissSavePasswordSheetIfPresent(app)
        for _ in 0..<4 {
            if fullImageCoverIsUp(app) {
                let close = app.buttons["fullImage.close"]
                if waitUntilHittable(close, in: app, timeout: 5) { close.tap() }
                becomesTrue(within: 8) { !fullImageCoverIsUp(app) }
                continue
            }
            if accountMenuIsUp(app) {
                closeAccountMenuByItsOwnButton(app)
                continue
            }
            return true
        }
        let stillThere = fullImageCoverIsUp(app) || accountMenuIsUp(app)
        if stillThere {
            print("MEASURED clearProbeOverlays gave up: cover=\(fullImageCoverIsUp(app)) "
                  + "menu=\(accountMenuIsUp(app)); anything measured from here is measured through it")
        }
        return !stillThere
    }

    // MARK: Getting somewhere

    /// accept-**b**, not accept-a. The like suites drive accept-a, and a like
    /// is this account's own state — which is the signal these probes read.
    var probeAccount: (email: String, password: String) {
        ("accept-b@example.com", "Passw0rd!x")
    }

    /// Fills in the sign-in form that is already on screen.
    ///
    /// Separate from launching because signing out is a *measurement result*
    /// here, not a teardown: the sign-out row can only be probed by ending the
    /// session, and the cheap way back is this form rather than a relaunch.
    @discardableResult
    func signInFromLoginScreen(_ app: XCUIApplication) -> Bool {
        guard waitForExistence(of: app.staticTexts["login.title"], in: app, timeout: 30) else {
            return false
        }
        let clear = String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40)
        let email = app.textFields["login.email"]
        guard waitUntilHittable(email, in: app, timeout: 30) else { return false }
        email.tap()
        email.typeText(clear + probeAccount.email)
        let password = app.secureTextFields["login.password"]
        guard waitUntilHittable(password, in: app, timeout: 20) else { return false }
        password.tap()
        password.typeText(clear + probeAccount.password)
        app.buttons["login.submit"].tap()
        guard waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 90) else {
            return false
        }
        waitForQuietUI(app)
        return true
    }

    @discardableResult
    func launchSignedInForProbing(_ app: XCUIApplication) -> Bool {
        app.launchArguments = ["-petnote-start-signed-out"]
        app.launch()
        return signInFromLoginScreen(app)
    }

    /// The feed, with nothing on top of it.
    @discardableResult
    func arriveAtFeed(_ app: XCUIApplication) -> Bool {
        guard clearProbeOverlays(app) else { return false }
        if app.staticTexts["login.title"].exists, !signInFromLoginScreen(app) { return false }
        if app.navigationBars["Post"].exists {
            let back = app.navigationBars["Post"].buttons.firstMatch
            if waitUntilHittable(back, in: app, timeout: 10) { back.tap() }
            becomesTrue(within: 15) {
                app.navigationBars["PetNote"].exists && !app.navigationBars["Post"].exists
            }
        }
        return waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 30)
            && !app.navigationBars["Post"].exists
    }

    /// The post detail screen, with nothing on top of it.
    ///
    /// **The overlay check comes first, and that ordering is the fix.** Under a
    /// `fullScreenCover` the pushed screen is still in the hierarchy, so
    /// `navigationBars["Post"].exists` is true with the photo viewer covering
    /// it. The version that asked the bar first therefore answered "yes, we are
    /// on the detail screen" for every probe taken after a cover opened, and
    /// each of those probes was recorded as a miss.
    @discardableResult
    func arriveAtDetail(_ app: XCUIApplication) -> Bool {
        guard clearProbeOverlays(app) else { return false }
        if app.staticTexts["login.title"].exists, !signInFromLoginScreen(app) { return false }
        if app.navigationBars["Post"].exists { return true }
        let rows = app.buttons.matching(identifier: "post.comments")
        guard waitUntilHittable(rows.firstMatch, in: app, timeout: 40) else { return false }
        rows.firstMatch.tap()
        return waitForExistence(of: app.navigationBars["Post"], in: app, timeout: 30)
    }

    /// The account menu, open and finished moving.
    @discardableResult
    func arriveAtAccountMenu(_ app: XCUIApplication) -> Bool {
        if accountMenuIsUp(app) { return frameSettled(app.buttons["session.signOut"]) }
        guard arriveAtFeed(app) else { return false }
        let entry = app.buttons["account.menu"]
        guard waitUntilHittable(entry, in: app, timeout: 30) else { return false }
        entry.tap()
        guard waitUntilHittable(app.buttons["session.signOut"], in: app, timeout: 30) else {
            return false
        }
        return frameSettled(app.buttons["session.signOut"])
    }

    // MARK: Tapping a place rather than a control

    /// A tap at an absolute point in the window's coordinate space.
    ///
    /// Deliberately not `element.coordinate(withNormalizedOffset:)`: the
    /// normalised form divides by the element's own size, so the same written
    /// offset means a different distance on a 36pt control than on a 44pt one,
    /// and that size is the variable under study.
    func tapWindowPoint(_ app: XCUIApplication, _ point: CGPoint) {
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y))
            .tap()
    }

    func isInsideWindow(_ app: XCUIApplication, _ point: CGPoint) -> Bool {
        let window = app.windows.firstMatch.frame
        return point.x > window.minX && point.x < window.maxX
            && point.y > window.minY && point.y < window.maxY
    }

    /// Where to actually tap, given that the control may have moved since the
    /// search began. `nil` when the control is no longer the same control.
    ///
    /// **Measured, and it cost a run.** Absolute window coordinates are the
    /// right frame of reference for a boundary search — they are what keeps
    /// "where the centre is" out of "how far the region reaches" — but they
    /// only name a control while the control stays put, and in the feed it
    /// does not. Any probe that opens a post pops back to a list that
    /// re-anchors the row it left from: `FeedView.onChange(of: path.isEmpty)`
    /// scrolls to it with `anchor: .center`. Mid-bisection the like button
    /// went from y=753 to y=125.667, and every probe after that was a tap at
    /// coordinates that now named the middle of a photo.
    ///
    /// The first version of this guard noticed and abandoned the measurement,
    /// which was right and not useful. So the search keeps bisecting in the one
    /// frame of reference the anchor was taken in, and the *translation*
    /// between that frame and the screen is re-read immediately before every
    /// tap. Nothing is inferred and no offset is measured from a centre: the
    /// two boundaries are still found independently and still subtracted.
    ///
    /// A change of **size** is still fatal, and is a different fact: it means
    /// the control is not the one the search started on. The like button's
    /// label carries the count, so a like that takes it from 9 to 10 does
    /// exactly that — which is why `probeLikeButton` puts the like back.
    func probeTarget(
        _ point: CGPoint, anchor: CGRect, live: CGRect, tolerance: CGFloat = 1.0
    ) -> CGPoint? {
        guard abs(live.width - anchor.width) <= tolerance,
              abs(live.height - anchor.height) <= tolerance else { return nil }
        let shift = CGVector(dx: live.minX - anchor.minX, dy: live.minY - anchor.minY)
        if abs(shift.dx) > tolerance || abs(shift.dy) > tolerance {
            print("MEASURED     the control moved by (\(shift.dx), \(shift.dy)); "
                  + "the probe point is translated with it")
        }
        return CGPoint(x: point.x + shift.dx, y: point.y + shift.dy)
    }

    // MARK: The probes

    /// The like button, in the feed.
    ///
    /// The signal is the **label** — Like ⇄ Unlike — not the value. The value is
    /// "N likes", an aggregate another signed-in client can move while this is
    /// running, and this machine runs several suites at once. The label is this
    /// account's own like state, so it only changes because this test tapped
    /// something.
    func probeLikeButton(
        _ app: XCUIApplication, at point: CGPoint, anchor: CGRect
    ) -> TouchOutcome {
        guard arriveAtFeed(app) else {
            XCTFail("lost the feed before the probe at \(point)")
            return .nothing
        }
        let like = app.buttons.matching(identifier: "post.like").firstMatch
        guard like.waitForExistence(timeout: 30) else { return .nothing }
        // Settled before the frame is read, not merely present. Returning to
        // the feed starts a scroll animation — the list puts the row it left
        // from back under the reader's eye — and a frame read during it is a
        // frame of where the button is going to be, which is exactly the error
        // the translation below exists to remove.
        guard frameSettled(like) else {
            XCTFail("the like button never stopped moving before the probe at \(point)")
            return .nothing
        }
        let frame = like.frame
        guard let target = probeTarget(point, anchor: anchor, live: frame) else {
            XCTFail("the like button changed size to \(frame.size) from \(anchor.size); "
                    + "the search is no longer measuring the control it started on")
            return .nothing
        }
        let before = like.label
        guard isInsideWindow(app, target) else { return .offWindow }

        tapWindowPoint(app, target)
        let watch = watchForChange {
            // Checked before the label, because the detail screen draws the
            // same card: after a push, `post.like` firstMatch is the *other*
            // screen's button and its label has not changed either.
            if app.navigationBars["Post"].exists { return .somethingElse }
            if accountMenuIsUp(app) || fullImageCoverIsUp(app) { return .somethingElse }
            let now = app.buttons.matching(identifier: "post.like").firstMatch
            guard now.exists else { return nil }
            return now.label == before ? nil : .activated
        }
        print("MEASURED     like probe: \(watch.trace) (label was \"\(before)\")")
        if watch.outcome == .activated {
            // Put the like back before the next probe.
            //
            // Not tidiness. The count is drawn inside the button's own label,
            // so a like that takes it from 9 to 10 makes the button wider —
            // and the width is one of the four numbers this search is trying
            // to measure. Leaving the state where the last probe put it would
            // mean the horizontal boundaries were bisected against a control
            // that changes size halfway through. It also leaves the shared
            // emulator as it was found.
            let restore = app.buttons.matching(identifier: "post.like").firstMatch
            if waitUntilHittable(restore, in: app, timeout: 10) {
                restore.tap()
                becomesTrue(within: 10) {
                    app.buttons.matching(identifier: "post.like").firstMatch.label == before
                }
            }
        } else {
            _ = arriveAtFeed(app)
        }
        return watch.outcome
    }

    /// The comments button, in the feed.
    ///
    /// **Its activation is not distinguishable from the card's own.** In the
    /// feed `onOpenComments` and `onOpenPost` are the same call — `open(post)`
    /// in `FeedView` — so "the comments button fired" and "the card's text or
    /// photo fired" produce one event, a push of the same post. What *can* be
    /// told apart is **which** post arrived, and that is what rules out the
    /// neighbouring card below: the probed card's text is captured first and
    /// compared against the detail screen's.
    ///
    /// So the boundary this finds is the edge of the connected region that
    /// contains the button, and it is the button's own edge only if a dead band
    /// separates it from the card content above. The search records what its
    /// outside probes saw, so that band is visible in the output rather than
    /// assumed.
    func probeCommentsButton(
        _ app: XCUIApplication, at point: CGPoint, anchor: CGRect, opensPostWithText text: String
    ) -> TouchOutcome {
        guard arriveAtFeed(app) else {
            XCTFail("lost the feed before the probe at \(point)")
            return .nothing
        }
        let comments = app.buttons.matching(identifier: "post.comments").firstMatch
        guard comments.waitForExistence(timeout: 30) else { return .nothing }
        guard frameSettled(comments) else {
            XCTFail("the comments button never stopped moving before the probe at \(point)")
            return .nothing
        }
        let frame = comments.frame
        guard let target = probeTarget(point, anchor: anchor, live: frame) else {
            XCTFail("the comments button changed size to \(frame.size) from \(anchor.size)")
            return .nothing
        }
        guard isInsideWindow(app, target) else { return .offWindow }

        tapWindowPoint(app, target)
        let watch = watchForChange {
            if fullImageCoverIsUp(app) || accountMenuIsUp(app) { return .somethingElse }
            // Both bars are in the tree during the push, and so are both
            // screens' `post.text`. Reading the label before the feed's bar has
            // gone reads the feed's own first card, which is the same post
            // whenever the probed card is the first one — a check that would
            // agree with itself.
            guard app.navigationBars["Post"].exists,
                  !app.navigationBars["PetNote"].exists else { return nil }
            let opened = app.staticTexts.matching(identifier: "post.text").firstMatch
            guard opened.exists else { return nil }
            let label = opened.label
            guard !label.isEmpty else { return nil }
            return label == text ? .activated : .somethingElse
        }
        print("MEASURED     comments probe: \(watch.trace)")
        _ = arriveAtFeed(app)
        return watch.outcome
    }

    /// The account entry in the feed's navigation bar. Opening the menu is all
    /// it does, which is what makes it safe to probe at all — the control it
    /// replaced ended the session on the first tap.
    func probeAccountEntry(
        _ app: XCUIApplication, at point: CGPoint, anchor: CGRect
    ) -> TouchOutcome {
        guard arriveAtFeed(app) else {
            XCTFail("lost the feed before the probe at \(point)")
            return .nothing
        }
        let entry = app.buttons["account.menu"]
        guard entry.waitForExistence(timeout: 30) else { return .nothing }
        let frame = entry.frame
        guard let target = probeTarget(point, anchor: anchor, live: frame) else {
            XCTFail("the account entry changed size to \(frame.size) from \(anchor.size)")
            return .nothing
        }
        guard isInsideWindow(app, target) else { return .offWindow }

        tapWindowPoint(app, target)
        let watch = watchForChange {
            if accountMenuIsUp(app) { return .activated }
            if app.navigationBars["Post"].exists { return .somethingElse }
            if fullImageCoverIsUp(app) { return .somethingElse }
            return nil
        }
        print("MEASURED     account entry probe: \(watch.trace)")
        _ = arriveAtFeed(app)
        return watch.outcome
    }

    /// The sign-out row inside the account menu.
    ///
    /// Every activation ends the session, so every activating probe costs a
    /// sign-in. That is the price of measuring this control at all, and it is
    /// the reason the search bisects instead of sweeping.
    func probeSignOutRow(
        _ app: XCUIApplication, at point: CGPoint, anchor: CGRect
    ) -> TouchOutcome {
        guard arriveAtAccountMenu(app) else {
            XCTFail("could not open the account menu before the probe at \(point)")
            return .nothing
        }
        let row = app.buttons["session.signOut"]
        let frame = row.frame
        guard let target = probeTarget(point, anchor: anchor, live: frame) else {
            XCTFail("the sign-out row changed size to \(frame.size) from \(anchor.size); "
                    + "the sheet did not come back to the same detent")
            return .nothing
        }
        guard isInsideWindow(app, target) else { return .offWindow }

        tapWindowPoint(app, target)
        // **The menu closing is not yet an answer, and reading it as one would
        // have been a false negative on every activating probe.** Signing out
        // from this row is two steps by design: `SignedInView` closes the sheet
        // and ends the session in the dismissal handler, because replacing the
        // session scope from inside the presented sheet's own action asks UIKit
        // to dismiss a presentation whose presenter is being torn down. So
        // there is a real window where the menu has gone and the sign-in screen
        // has not arrived, and `!accountMenuIsUp` during it means "activated,
        // still in progress" — not "something else happened".
        var menuGoneSince: Date?
        let watch = watchForChange(deadline: 25) {
            if app.staticTexts["login.title"].exists { return .activated }
            guard !accountMenuIsUp(app) else {
                menuGoneSince = nil
                return nil
            }
            let since = menuGoneSince ?? Date()
            menuGoneSince = since
            // Four seconds of no menu and no sign-in screen is a third thing:
            // the sheet was dismissed without the session ending.
            return Date().timeIntervalSince(since) > 4 ? .somethingElse : nil
        }
        print("MEASURED     sign-out probe: \(watch.trace)")
        if watch.outcome == .activated {
            XCTAssertTrue(signInFromLoginScreen(app), "could not sign back in after a probe activated sign-out")
        }
        return watch.outcome
    }

    /// The system back button on the detail screen.
    ///
    /// Identity is confirmed by **behaviour**: a hit is counted only when the
    /// screen pops. Nothing else on that bar can pop a screen, so a run that
    /// somehow aimed at another control would record every probe as a miss and
    /// find no boundary at all, rather than quietly measuring the wrong thing.
    func probeBackButton(
        _ app: XCUIApplication, at point: CGPoint, anchor: CGRect
    ) -> TouchOutcome {
        guard arriveAtDetail(app) else {
            XCTFail("lost the detail screen before the probe at \(point)")
            return .nothing
        }
        // Name-limited to the pushed screen's own bar. `app.navigationBars` as
        // a whole spans every bar in the tree, and index 0 of that once
        // returned the control that ended the session.
        let back = app.navigationBars["Post"].buttons.firstMatch
        guard back.exists else { return .nothing }
        let frame = back.frame
        guard let target = probeTarget(point, anchor: anchor, live: frame) else {
            XCTFail("the back button changed size to \(frame.size) from \(anchor.size)")
            return .nothing
        }
        guard isInsideWindow(app, target) else { return .offWindow }

        tapWindowPoint(app, target)
        let watch = watchForChange {
            // Both bars exist briefly during the pop animation, so the signal
            // is the detail bar being *gone*, not the feed bar being present.
            if app.navigationBars["PetNote"].exists, !app.navigationBars["Post"].exists {
                return .activated
            }
            // A probe below the bar lands on the post's photo, which on this
            // screen opens the full-size viewer. That is a negative for the
            // button and a positive for the instrument.
            if fullImageCoverIsUp(app) { return .somethingElse }
            return nil
        }
        print("MEASURED     back probe: \(watch.trace)")
        if watch.outcome != .activated { _ = arriveAtDetail(app) }
        return watch.outcome
    }
}

// MARK: - The instrument's own tests

/// Whether the instrument can be believed, checked before anything is measured
/// with it.
///
/// The three questions, in the order they have to be answered:
///
///   1. **Can it tell the three outcomes apart?** Each of `activated`,
///      `somethingElse` and `nothing` is produced deliberately here, from a
///      tap whose result is known in advance. An outcome nothing can produce
///      is not a category, it is a dead branch — and a dead `somethingElse`
///      is what put every viewer-opening probe into `nothing`, which is where
///      the control group draws its negatives.
///   2. **Does it notice a screen it cannot see past?** A full-screen cover
///      leaves the pushed screen's navigation bar in the tree, so the question
///      "are we on the detail screen" answers yes while a photo covers it.
///   3. **Is a negative confirmed or merely assumed?** A negative has to cost
///      the full observation window; a negative returned in 200ms is a report
///      about the machine.
///
/// **No size is claimed here.** Measuring outwards from an element's centre
/// cannot answer §6.4: "22pt above the centre activates" is equally consistent
/// with a 44pt region centred half a point high and a 43pt one, because it
/// conflates where the centre is with how far the region reaches. The sizes
/// are in `HitRegionBoundaryUITests`, which bisects for each boundary as an
/// absolute window coordinate and subtracts.
final class TouchTargetUITests: XCTestCase {
    override func setUp() {
        // These are measurements. One probe that cannot be taken must not
        // throw away the rest.
        continueAfterFailure = true
    }

    /// All three outcomes, each from a tap whose result is known beforehand.
    ///
    /// Everything happens on the detail screen, where the neighbourhood is
    /// unambiguous: the photo opens the full-size viewer, the post's text has
    /// no action at all there (`onOpenPost` is nil on this screen), and the
    /// back button pops.
    func testEachOutcomeIsReachable() {
        let app = XCUIApplication()
        XCTAssertTrue(launchSignedInForProbing(app), "could not sign in")
        XCTAssertTrue(arriveAtDetail(app), "could not open a post")

        let back = app.navigationBars["Post"].buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 20))
        let backFrame = back.frame
        print("MEASURED back button frame \(backFrame)")

        // somethingElse — the photo, which on this screen opens the viewer.
        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 20), "this post has no photo to open")
        let photoCentre = photo.frame
        let elsewhere = probeBackButton(
            app, at: CGPoint(x: photoCentre.midX, y: photoCentre.midY), anchor: backFrame
        )
        print("MEASURED outcome on the photo: \(elsewhere.rawValue)")
        XCTAssertEqual(
            elsewhere, .somethingElse,
            "tapping the photo opened the full-size viewer and the probe did not notice. "
            + "That is the branch that was dead for a whole round: the viewer-opening probes "
            + "were filed as `nothing`, which is where the control group takes its negatives."
        )
        XCTAssertTrue(arriveAtDetail(app), "the cover was not cleared after the probe")
        XCTAssertFalse(fullImageCoverIsUp(app), "the cover is still up")

        // nothing — the post's own text, which carries a tap gesture on this
        // screen whose action is nil. A real region, deliberately inert.
        let text = app.staticTexts.matching(identifier: "post.text").firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 20))
        let textFrame = text.frame
        let inert = probeBackButton(
            app, at: CGPoint(x: textFrame.midX, y: textFrame.midY), anchor: backFrame
        )
        print("MEASURED outcome on the post's text: \(inert.rawValue)")
        XCTAssertEqual(inert, .nothing, "a tap on inert text was classified as something happening")

        // activated — the control itself.
        XCTAssertTrue(arriveAtDetail(app))
        let hit = probeBackButton(
            app, at: CGPoint(x: backFrame.midX, y: backFrame.midY), anchor: backFrame
        )
        print("MEASURED outcome on the back button's centre: \(hit.rawValue)")
        XCTAssertEqual(hit, .activated, "the centre of the back button did not activate it")
    }

    /// A cover hides the screen underneath but not its navigation bar.
    ///
    /// This is the specific wrong answer the old helper gave: it asked
    /// `navigationBars["Post"].exists` first, that stayed true under the
    /// viewer, so the probe went ahead and tapped a photo instead of a bar.
    /// The assertion below is the evidence that the bar is not a usable
    /// signal on its own — if it ever stops being true, the ordering in
    /// `arriveAtDetail` can be simplified and this test says so.
    func testACoverLeavesTheDetailBarInTheTreeAndIsClearedAnyway() {
        let app = XCUIApplication()
        XCTAssertTrue(launchSignedInForProbing(app), "could not sign in")
        XCTAssertTrue(arriveAtDetail(app), "could not open a post")

        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 20), "this post has no photo to open")
        photo.tap()
        XCTAssertTrue(
            waitForExistence(of: app.buttons["fullImage.close"], in: app, timeout: 20),
            "the full-size viewer did not open"
        )

        print("MEASURED with the cover up: navigationBars[\"Post\"].exists = "
              + "\(app.navigationBars["Post"].exists), fullImage.close.exists = "
              + "\(app.buttons["fullImage.close"].exists)")
        XCTAssertTrue(
            app.navigationBars["Post"].exists,
            "the detail bar has left the tree under a cover — the ordering in arriveAtDetail "
            + "can be simplified, and this comment is now wrong"
        )
        XCTAssertTrue(fullImageCoverIsUp(app), "the cover is up and the instrument cannot see it")

        XCTAssertTrue(clearProbeOverlays(app), "the cover was not cleared")
        XCTAssertFalse(fullImageCoverIsUp(app), "the cover is still up after clearing")
        XCTAssertTrue(app.navigationBars["Post"].exists, "clearing the cover left the detail screen")
    }

    /// A negative costs the whole observation window; a positive does not.
    ///
    /// The number that matters is not the verdict but the elapsed time
    /// underneath it. `tap()` + `sleep(2.0)` + one read returns "nothing"
    /// after exactly 2 seconds whether or not anything was going to happen,
    /// and on a machine with four agents on it that is routinely wrong in one
    /// direction: towards a smaller region and an unearned control-group
    /// negative.
    func testANegativeIsConfirmedRatherThanAssumed() {
        let app = XCUIApplication()
        XCTAssertTrue(launchSignedInForProbing(app), "could not sign in")

        let quiet = watchForChange(minSamples: 10, minSeconds: 2.0, deadline: 10) { nil }
        print("MEASURED confirmed negative: \(quiet.trace)")
        XCTAssertEqual(quiet.outcome, .nothing)
        XCTAssertGreaterThanOrEqual(quiet.samples, 10, "a negative was returned on too few samples")
        XCTAssertGreaterThanOrEqual(
            quiet.elapsed, 2.0,
            "a negative was returned before the observation window had passed"
        )

        let immediate = watchForChange(minSamples: 10, minSeconds: 2.0, deadline: 10) { .activated }
        print("MEASURED immediate positive: \(immediate.trace)")
        XCTAssertEqual(immediate.outcome, .activated)
        XCTAssertEqual(immediate.samples, 1, "a positive waited for the negative's floors")
        XCTAssertLessThan(
            immediate.elapsed, 1.0,
            "a positive that costs the whole window makes every bisection cost the whole window"
        )
    }
}
