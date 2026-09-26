import XCTest

/// Settings through the screens, against the emulator: the notification
/// switches, changing the password, and deleting the account — including
/// backing out, a wrong password, and a deletion that stopped part-way.
///
/// Every account here is created for the test and removed afterwards (or by
/// the deletion itself). Nothing touches the seeded accounts or any cloud.
final class SettingsUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var email: String { "settings-\(run)@petnote.test" }
    private var uid: String?
    private var petID: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        if let uid {
            JourneyAdmin.deleteDocument(path: "users/\(uid)/settings/preferences")
            if let petID {
                JourneyAdmin.deleteDocument(path: "pets/\(petID)/family/\(uid)")
                JourneyAdmin.deleteDocument(path: "pets/\(petID)")
            }
            JourneyAdmin.removeProfile(uid: uid)
        }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    private func openSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Profile"].tap()
        let entry = app.buttons["profile.settings"]
        for _ in 0..<4 where !(entry.exists && entry.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(entry, in: app, timeout: 30), "no Settings on the profile\n\(app.debugDescription)")
        entry.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    func testANotificationSwitchIsSavedAndReadBack() throws {
        let (app, me) = try signInAsNewAccount(email)
        uid = me
        openSettings(app)
        let likes = app.switches["settings.notify.likeNotifications"]
        XCTAssertTrue(waitUntilHittable(likes, in: app, timeout: 30), "no Likes switch\n\(app.debugDescription)")
        XCTAssertEqual(likes.value as? String, "1", "a switch with nothing stored is not on")
        // The switch itself, at the right of the row: a tap on the label
        // does not flip a SwiftUI toggle in a Form.
        likes.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()

        var stored: Bool?
        for _ in 0..<20 {
            stored = JourneyAdmin.bool(try JourneyAdmin.fields(path: "users/\(me)/settings/preferences")?["likeNotifications"])
            if stored == false { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(stored, false, "the switch was not saved")

        // Read back from the server on a fresh visit.
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        openSettings(app)
        let again = app.switches["settings.notify.likeNotifications"]
        XCTAssertTrue(waitUntilHittable(again, in: app, timeout: 30))
        let read = expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: again)
        XCTAssertEqual(XCTWaiter().wait(for: [read], timeout: 15), .completed, "the saved value was not read back")
    }

    func testChangingThePasswordNeedsTheCurrentOneAndThenTheNewOneWorks() throws {
        let (app, me) = try signInAsNewAccount(email)
        uid = me
        openSettings(app)
        let change = app.buttons["settings.changePassword"]
        XCTAssertTrue(waitUntilHittable(change, in: app, timeout: 30))
        change.tap()

        let current = app.secureTextFields["changePassword.current"]
        XCTAssertTrue(waitUntilHittable(current, in: app, timeout: 20))
        current.tap()
        current.typeText("Wr0ng!pass")
        typeNewPassword("N3w!passw0rd", into: app.secureTextFields["changePassword.new"], in: app)
        typeNewPassword("N3w!passw0rd", into: app.secureTextFields["changePassword.confirm"], in: app)
        app.buttons["changePassword.save"].tap()
        let error = app.staticTexts["changePassword.error"]
        XCTAssertTrue(waitForExistence(of: error, in: app, timeout: 30), "a wrong current password was not refused")
        XCTAssertEqual(error.label, "Current password is incorrect.")

        // Not `replaceText`: a secure field reads back as bullets, never the
        // text, so that helper's check cannot hold here. The count can.
        current.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        current.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Wr0ng!pass".count))
        current.typeText("Passw0rd!x")
        XCTAssertEqual((current.value as? String)?.count, "Passw0rd!x".count, "the current password was not replaced")
        app.buttons["changePassword.save"].tap()
        XCTAssertTrue(waitForExistence(of: app.staticTexts["changePassword.done"], in: app, timeout: 30), "the change was not confirmed")
        app.buttons["changePassword.close"].tap()

        // Out, and in with the new password.
        popToTabRoot(app, then: "Home")
        signOutFromAccountMenu(app)
        signIn(app, email: email, password: "N3w!passw0rd", expectFeed: false)
        dismissOnboardingIfShown(app)
        XCTAssertTrue(reachedFeed(app), "the new password did not sign in")
    }

    func testBackingOutOfDeletionAndAWrongPasswordLeaveTheAccountAlone() throws {
        let (app, me) = try signInAsNewAccount(email)
        uid = me
        openSettings(app)
        let delete = app.buttons["settings.deleteAccount"]
        reveal(delete, in: app)
        XCTAssertTrue(waitUntilHittable(delete, in: app, timeout: 20))
        delete.tap()

        // Backing out.
        let keyword = app.textFields["deleteAccount.keyword"]
        XCTAssertTrue(waitUntilHittable(keyword, in: app, timeout: 20))
        XCTAssertFalse(app.buttons["deleteAccount.delete"].isEnabled, "armed with nothing typed")
        keyword.tap()
        keyword.typeText("DELETE")
        XCTAssertFalse(app.buttons["deleteAccount.delete"].isEnabled, "armed without the password")
        app.buttons["deleteAccount.cancel"].tap()
        XCTAssertNotNil(try JourneyAdmin.fields(path: "users/\(me)"), "cancelling deleted the account")

        // A wrong password.
        delete.tap()
        let password = app.secureTextFields["deleteAccount.password"]
        XCTAssertTrue(waitUntilHittable(password, in: app, timeout: 20))
        password.tap()
        password.typeText("Wr0ng!pass")
        keyword.tap()
        keyword.typeText("DELETE")
        app.buttons["deleteAccount.delete"].tap()
        let error = app.staticTexts["deleteAccount.error"]
        XCTAssertTrue(waitForExistence(of: error, in: app, timeout: 30), "a wrong password was not refused")
        XCTAssertEqual(error.label, "That password is not correct.")
        XCTAssertNotNil(try JourneyAdmin.fields(path: "users/\(me)"), "a wrong password still deleted the account")
    }

    func testDeletingTheAccountRemovesItAndItsPetAndSaysSo() throws {
        let (app, me) = try signInAsNewAccount(email)
        uid = me
        petID = try addPetThroughTheScreens(app, named: "Del \(run.prefix(6))")
        popToTabRoot(app)
        openSettings(app)
        try deleteThroughTheSheet(app)

        XCTAssertTrue(waitForExistence(of: app.staticTexts["login.accountDeleted"], in: app, timeout: 120),
                      "the deletion did not end at the sign-in screen saying so\n\(app.debugDescription)")
        XCTAssertNil(try JourneyAdmin.fields(path: "users/\(me)"), "the profile is still there")
        XCTAssertNil(try JourneyAdmin.fields(path: "pets/\(try XCTUnwrap(petID))"), "the pet only this account owned is still there")
        XCTAssertNil(try JourneyAdmin.uid(forEmail: email), "the sign-in account is still there")
        petID = nil
    }

    /// A deletion the server began and did not finish leaves
    /// `deletionPending` on the profile. Settings says so and finishes it.
    func testAnUnfinishedDeletionIsShownAndCanBeFinished() throws {
        let (app, me) = try signInAsNewAccount(email)
        uid = me
        try Self.setDeletionPending(uid: me)
        openSettings(app)
        let notice = app.otherElements["settings.deletionPending"]
        XCTAssertTrue(waitForExistence(of: notice, in: app, timeout: 30), "an unfinished deletion was not shown\n\(app.debugDescription)")
        app.buttons["settings.finishDeleting"].tap()
        try deleteThroughTheSheet(app, openFromSettings: false)
        XCTAssertTrue(waitForExistence(of: app.staticTexts["login.accountDeleted"], in: app, timeout: 120))
        XCTAssertNil(try JourneyAdmin.fields(path: "users/\(me)"))
    }

    // MARK: - Steps

    private func deleteThroughTheSheet(_ app: XCUIApplication, openFromSettings: Bool = true) throws {
        if openFromSettings {
            let delete = app.buttons["settings.deleteAccount"]
            reveal(delete, in: app)
            XCTAssertTrue(waitUntilHittable(delete, in: app, timeout: 20))
            delete.tap()
        }
        let password = app.secureTextFields["deleteAccount.password"]
        XCTAssertTrue(waitUntilHittable(password, in: app, timeout: 20))
        password.tap()
        password.typeText("Passw0rd!x")
        let keyword = app.textFields["deleteAccount.keyword"]
        keyword.tap()
        keyword.typeText("DELETE")
        let button = app.buttons["deleteAccount.delete"]
        XCTAssertTrue(waitForEnabled(button, timeout: 10))
        button.tap()
    }

    private static func setDeletionPending(uid: String) throws {
        let path = "projects/\(EmulatorAdmin.projectID)/databases/(default)/documents/users/\(uid)"
        var request = URLRequest(url: URL(string: "\(EmulatorAdmin.firestore)/v1/\(path)?updateMask.fieldPaths=deletionPending")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fields": ["deletionPending": ["booleanValue": true]]])
        let done = DispatchSemaphore(value: 0)
        var status = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        XCTAssertEqual(status, 200, "could not mark the account as being deleted")
    }
}
