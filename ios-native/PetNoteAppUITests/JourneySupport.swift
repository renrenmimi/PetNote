import XCTest

// What the journeys do to fields, pickers and menus, shared so each one does
// it the way that was found to work — the reasons are on each helper, where
// the next test to need it will read them.
extension XCTestCase {

    /// Types into a `.newPassword` field the way a person who declines the
    /// suggestion does.
    ///
    /// Focusing such a field makes iOS offer "Use Strong Password?" in a sheet
    /// over the keyboard — the system's behaviour, and the reason the field is
    /// `.newPassword`. While it is up, typed characters do not all reach the
    /// field: a first run of this test typed ten and the field held one. The
    /// sheet is closed with its own Close button, which is "choose my own",
    /// and the length is checked afterwards so a lost keystroke fails here
    /// rather than as "the button stayed disabled".
    func typeNewPassword(_ password: String, into field: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(waitUntilHittable(field, in: app))
        let offer = app.staticTexts["Use Strong Password?"]
        // Focusing can bring the offer back, so focus and close until the
        // field has the keyboard with nothing over it.
        for _ in 0..<3 {
            if !field.hasKeyboardFocusValue { field.tap() }
            guard offer.waitForExistence(timeout: 3) else { break }
            let close = app.buttons["xmark"].exists ? app.buttons["xmark"] : app.buttons["Close"]
            XCTAssertTrue(close.exists, "the strong-password offer has no Close\n\(app.debugDescription)")
            close.tap()
            XCTAssertTrue(waitForDisappearance(of: offer, timeout: 5), "the strong-password offer would not close")
        }
        XCTAssertFalse(offer.exists, "the strong-password offer kept coming back")
        field.typeText(password)
        XCTAssertEqual((field.value as? String)?.count, password.count,
                       "the password field did not receive every character")
    }

    /// Replaces what a field holds, and checks that it did.
    ///
    /// The tap goes to the bottom-right corner, not the centre: a tap in the
    /// middle of a text view put the cursor at the *start* of its text, so the
    /// deletes removed nothing and the new text was typed in front of the old
    /// — the server then held "…edited" followed by the original, and the
    /// test read that as an edit that was never written.
    func replaceText(in element: XCUIElement, with text: String) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.9)).tap()
        let current = (element.value as? String) ?? ""
        if !current.isEmpty {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        element.typeText(text)
        XCTAssertEqual(element.value as? String, text, "the field does not hold what was typed")
    }

    func choose(_ app: XCUIApplication, picker identifier: String, option label: String) {
        let picker = app.buttons[identifier]
        for _ in 0..<4 where !(picker.exists && picker.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(picker, in: app, timeout: 10), "no \(identifier)")
        picker.tap()
        let option = app.buttons[label]
        XCTAssertTrue(waitUntilHittable(option, in: app, timeout: 10), "no \(label) in \(identifier)")
        option.tap()
    }

    func pickFirstPhoto(_ app: XCUIApplication) throws {
        // PHPicker's cells are labelled "Photo, <date>". It runs out of
        // process, and its tree is reached through the app's.
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
        XCTAssertTrue(
            waitForExistence(of: photo, in: app, timeout: 30),
            "no photo in the picker — add one with `xcrun simctl addmedia`\n\(app.debugDescription)"
        )
        photo.tap()
        // Multi-select pickers need confirming; single-select ones close on tap.
        let confirm = app.buttons["Add"]
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
    }

    func openPostMenu(_ app: XCUIApplication) {
        let menu = app.buttons["post.actions"]
        XCTAssertTrue(waitUntilHittable(menu, in: app, timeout: 30), "no post menu on the detail screen")
        menu.tap()
    }

    func tapMenuItem(_ app: XCUIApplication, id: String, label: String) {
        let byID = app.buttons[id]
        let item = byID.waitForExistence(timeout: 5) ? byID : app.buttons[label]
        XCTAssertTrue(waitUntilHittable(item, in: app, timeout: 10), "no \(label) in the post menu")
        item.tap()
    }

    func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let enabled = expectation(for: NSPredicate(format: "exists == true AND enabled == true"),
                                  evaluatedWith: element)
        return XCTWaiter().wait(for: [enabled], timeout: timeout) == .completed
    }
}

extension XCTestCase {
    /// A fresh verified account, signed in, with onboarding closed.
    ///
    /// Fresh rather than seeded wherever a test changes what an account owns,
    /// follows or blocks: the seeded accounts are what the other suites read.
    func signInAsNewAccount(
        _ email: String, extraArguments: [String] = [], file: StaticString = #filePath, line: UInt = #line
    ) throws -> (app: XCUIApplication, uid: String) {
        let uid = try EmulatorAdmin.createVerifiedAccount(email: email, password: "Passw0rd!x")
        let app = launchOnSignIn(extraArguments: extraArguments)
        signIn(app, email: email, expectFeed: false)
        dismissOnboardingIfShown(app)
        XCTAssertTrue(reachedFeed(app), "did not reach the feed", file: file, line: line)
        settleSavePasswordPrompt(app)
        return (app, uid)
    }

    /// Profile → Add a pet → name, species, relationship → Save. Returns the
    /// new pet's id, read from the server, with its page open.
    func addPetThroughTheScreens(_ app: XCUIApplication, named name: String) throws -> String {
        app.tabBars.buttons["Profile"].tap()
        let add = app.buttons["profile.addPet"]
        XCTAssertTrue(waitUntilHittable(add, in: app, timeout: 30), "no Add a pet\n\(app.debugDescription)")
        add.tap()
        let field = app.textFields["petEditor.name"]
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 20), "the pet editor did not open")
        field.tap()
        field.typeText(name)
        choose(app, picker: "petEditor.species", option: "Dog")
        choose(app, picker: "petEditor.relationship", option: "Mom")
        let save = app.buttons["petEditor.save"]
        for _ in 0..<6 where !(save.exists && save.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitForEnabled(save, timeout: 10), "Save never became available")
        save.tap()
        XCTAssertTrue(waitForExistence(of: app.staticTexts["pet.name"], in: app, timeout: 40),
                      "the new pet's page did not open\n\(app.debugDescription)")
        let pets = try JourneyAdmin.petDocumentNames(withName: name)
        return try XCTUnwrap(pets.first?.split(separator: "/").last.map(String.init), "the pet is not on the server")
    }

    /// Back to the root of the current tab, one level at a time, waiting for
    /// each transition before looking again.
    func popToTabRoot(_ app: XCUIApplication, then tab: String? = nil) {
        let bar = app.tabBars.firstMatch
        for _ in 0..<5 {
            if bar.exists, bar.buttons.firstMatch.isHittable { break }
            let back = app.navigationBars.buttons["BackButton"].firstMatch
            guard waitUntilHittable(back, in: app, timeout: 5) else { break }
            back.tap()
            waitForQuietUI(app, quietFor: 1, timeout: 10)
        }
        if let tab {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(waitUntilHittable(button, in: app, timeout: 15), "no \(tab) tab\n\(app.debugDescription)")
            button.tap()
        }
    }
}

extension XCUIElement {
    var hasKeyboardFocusValue: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
