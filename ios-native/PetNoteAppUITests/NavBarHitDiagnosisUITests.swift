import XCTest

/// A diagnosis, not a check: what XCUITest's hit test finds at the feed's
/// navigation bar items when the Popular Pets row is the list's first row.
///
/// On 2cc7eea the bell was reported not hittable on the feed's first
/// appearance (three tests), a synthesized tap on it still opened
/// Notifications, and after going there and back it was hittable. Without
/// the row it was hittable from the start. The cause was not found, and
/// XCUITest's hit test is the accessibility one VoiceOver's touch
/// exploration uses, so it is looked at directly here rather than guessed.
///
/// It prints and asserts nothing about the app. Each reading gives, for the
/// three bar items, `isHittable` and the frame, then every element in the
/// tree whose frame contains the bell's centre, with its depth, so whatever
/// sits over the bell — or the absence of anything — is on the record.
final class NavBarHitDiagnosisUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testWhatSitsAtTheBarItemsOnTheFeedsFirstAppearance() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        waitForQuietUI(app)

        let spotlight = app.descendants(matching: .any).matching(identifier: "feed.spotlight").firstMatch
        _ = spotlight.waitForExistence(timeout: 20)
        print("DIAG spotlight exists=\(spotlight.exists) frame=\(spotlight.exists ? spotlight.frame : .null)")

        reading("after sign-in settled", app)
        Thread.sleep(forTimeInterval: 3)
        reading("3s later", app)
        Thread.sleep(forTimeInterval: 7)
        reading("10s later", app)

        nudgeListUp(app)
        _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
        reading("after the list moved up", app)

        let bell = app.buttons["feed.notifications"]
        bell.tap()
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 10) {
            back.tap()
            _ = app.navigationBars["PetNote"].waitForExistence(timeout: 10)
            _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
            reading("back from Notifications", app)
        } else {
            print("DIAG no back button after tapping the bell")
        }
    }

    private func reading(_ when: String, _ app: XCUIApplication) {
        let ids = ["feed.notifications", "feed.search", "account.menu"]
        var bellCentre: CGPoint?
        for id in ids {
            let button = app.buttons[id]
            guard button.exists else {
                print("DIAG [\(when)] \(id) missing")
                continue
            }
            let frame = button.frame
            print("DIAG [\(when)] \(id) hittable=\(button.isHittable) frame=\(frame)")
            if id == "feed.notifications" { bellCentre = CGPoint(x: frame.midX, y: frame.midY) }
        }
        let bar = app.navigationBars["PetNote"]
        print("DIAG [\(when)] bar hittable=\(bar.exists && bar.isHittable) frame=\(bar.exists ? bar.frame : .null)")
        guard let bellCentre else { return }

        // One snapshot of the whole tree, read as text: each line carries the
        // element's type, its frame and its identifier. Every line whose frame
        // contains the bell's centre is printed with its indentation, which
        // is its depth.
        let tree = app.debugDescription
        let framePattern = #/\{\{(-?[\d.]+), (-?[\d.]+)\}, \{([\d.]+), ([\d.]+)\}\}/#
        var covering = 0
        for line in tree.split(separator: "\n") {
            guard let match = line.firstMatch(of: framePattern),
                  let x = Double(match.1), let y = Double(match.2),
                  let w = Double(match.3), let h = Double(match.4) else { continue }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            // Everything contains the window's centre region; the application
            // and window lines are expected and printed too, for depth.
            if rect.contains(bellCentre) {
                covering += 1
                print("DIAG [\(when)] at bell centre: \(line.prefix(220))")
            }
        }
        print("DIAG [\(when)] \(covering) elements contain the bell's centre \(bellCentre)")
    }
}
