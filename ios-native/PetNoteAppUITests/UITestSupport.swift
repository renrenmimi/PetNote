import XCTest

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
        }
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
    func waitForQuietUI(
        _ app: XCUIApplication,
        quietFor: TimeInterval = 2,
        timeout: TimeInterval = 20
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var quietSince = Date()
        while Date() < deadline {
            if app.buttons["Not Now"].exists {
                dismissSavePasswordSheetIfPresent(app)
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) >= quietFor {
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
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
