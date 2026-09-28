import XCTest

/// When the last typed sign-in was submitted and the last "Save Password?"
/// sheet was dismissed, so `settleSavePasswordPrompt` knows whether the sheet
/// for this sign-in has already been and gone. UI tests drive the app from
/// the test's main thread, one step at a time.
enum SavePasswordPrompt {
    nonisolated(unsafe) static var lastSubmitted: Date?
    nonisolated(unsafe) static var lastDismissed: Date?
}

/// Shared helpers for driving the app in UI tests.
extension XCTestCase {
    /// Dismisses iOS's "Save Password?" sheet if it is on screen.
    ///
    /// Two things make this sheet awkward, and both are the reason this is not
    /// an `addUIInterruptionMonitor`:
    ///
    ///   - **It is not SpringBoard's.** Unlike most system alerts it lives in
    ///     the app's own process, so it has to be queried from `app`, not from
    ///     a SpringBoard proxy.
    ///   - **It can arrive late** — after a sign-in has already completed and
    ///     the next screen is up. A one-shot wait before the next action misses
    ///     it, so this is folded into every wait instead.
    ///
    /// "Not Now" rather than "Save": saving would write a credential into the
    /// simulator's keychain and change what the next run starts from.
    func dismissSavePasswordSheetIfPresent(_ app: XCUIApplication) {
        let notNow = app.buttons["Not Now"]
        guard notNow.exists, notNow.isHittable else { return }
        // Checking and tapping are two moments, and this sheet closes itself.
        // On a device the gap was wide enough to lose the race: the check
        // passed, the sheet went away, and the tap failed the test with
        // "Failed to tap 'Not Now': No matches found" — a housekeeping helper
        // reporting a defect in whatever test happened to call it.
        //
        // A sheet that is already gone is the outcome this wants anyway.
        if notNow.waitForExistence(timeout: 1), notNow.isHittable {
            notNow.tap()
            SavePasswordPrompt.lastDismissed = Date()
        }
    }

    /// Waits for the "Save Password?" sheet that follows a typed sign-in to
    /// come and go, then for the screen to be still.
    ///
    /// It arrives when it likes. In the full regression of 2026-09-24, 132 of
    /// 136 typed sign-ins got it, 2.3 to 20.4 seconds after Sign in was tapped
    /// (most near 3.6 s). A test that measures what can be tapped right after
    /// signing in measured the sheet whenever it came mid-measurement: the
    /// feed's bell, a card's open area and the detail screen's Back were each
    /// reported "not hittable" that way, and the same tests passed on the run
    /// where the sheet happened to come first. So a sign-in is not over until
    /// the system has finished asking. Nothing about what is asserted changes.
    func settleSavePasswordPrompt(_ app: XCUIApplication, within timeout: TimeInterval = 25) {
        if let submitted = SavePasswordPrompt.lastSubmitted,
           let dismissed = SavePasswordPrompt.lastDismissed, dismissed > submitted {
            _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
            return
        }
        let start = SavePasswordPrompt.lastSubmitted ?? Date()
        let deadline = start.addingTimeInterval(timeout)
        let notNow = app.buttons["Not Now"]
        while Date() < deadline {
            if notNow.exists {
                dismissSavePasswordSheetIfPresent(app)
                let gone = Date().addingTimeInterval(10)
                while notNow.exists, Date() < gone { Thread.sleep(forTimeInterval: 0.25) }
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
    }

    /// Waits for `element` to exist, clearing the save-password sheet while it
    /// waits. Returns false on timeout rather than failing, so callers can
    /// attach their own diagnosis.
    @discardableResult
    func waitForExistence(
        of element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 20
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSavePasswordSheetIfPresent(app)
            if element.exists { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return element.exists
    }

    /// Waits until the save-password sheet has stayed away for `quietFor`.
    ///
    /// Needed before measuring anything: the sheet can arrive seconds after the
    /// screen it covers, so clearing it once and then walking the hierarchy
    /// races it. Anything behind it reads as "not hittable", which looks
    /// exactly like a touch-target defect and is not one.
    ///
    /// **Returns false when it gave up.** It used to return `Void`, which meant
    /// the one outcome this helper exists to prevent — the sheet still up when
    /// the caller starts measuring — left no trace at all: the loop ran out,
    /// the function returned, and every frame read afterwards was read through
    /// a sheet. A housekeeping helper that cannot report its own failure hands
    /// the caller a measurement of the wrong screen.
    ///
    /// Deliberately not an `XCTFail` from in here: the helper does not know
    /// what the caller was about to do, and thirty call sites would start
    /// failing on a sheet that the next line would have dismissed anyway. The
    /// result is there so a caller that is about to *measure* can say so.
    @discardableResult
    func waitForQuietUI(
        _ app: XCUIApplication,
        quietFor: TimeInterval = 2,
        timeout: TimeInterval = 20
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var quietSince = Date()
        var clearances = 0
        while Date() < deadline {
            if app.buttons["Not Now"].exists {
                dismissSavePasswordSheetIfPresent(app)
                clearances += 1
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) >= quietFor {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        print("MEASURED waitForQuietUI gave up after \(timeout)s; "
              + "cleared the save-password sheet \(clearances) time(s) and it kept coming back. "
              + "Anything measured from here is measured through it.")
        return false
    }

    /// Same, but for something that has to be tappable — a control behind the
    /// save-password sheet exists and is not hittable, which is exactly the
    /// failure this whole helper exists for.
    @discardableResult
    func waitUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 20
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSavePasswordSheetIfPresent(app)
            if element.exists, element.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return element.exists && element.isHittable
    }
}
