import XCTest

/// The subtractions of shared ownership, through the screens, read back from
/// the emulator: a revoked code stops working, the primary hands the role
/// over, and the new primary removes the old one — and each side's screen
/// ends up agreeing with the server about who may do what.
///
/// The rules being checked are the server's (HANDOFF §5): adding is equal,
/// subtracting converges on the primary, the primary can hand the role over.
/// The app decides what to show from `isPrimary`; the server decides what
/// happens. Both are checked here.
final class FamilyManageUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var emailA: String { "fam-a-\(run)@petnote.test" }
    private var emailB: String { "fam-b-\(run)@petnote.test" }
    private var petName: String { "Fam \(run)" }
    private var uidA: String?
    private var uidB: String?
    private var petID: String?
    private var codes: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        if let petID {
            for uid in [uidA, uidB].compactMap({ $0 }) {
                JourneyAdmin.deleteDocument(path: "pets/\(petID)/family/\(uid)")
            }
            for code in codes {
                JourneyAdmin.deleteDocument(path: "pets/\(petID)/invitations/\(code)")
                JourneyAdmin.deleteDocument(path: "invitationCodes/\(code)")
            }
            JourneyAdmin.deleteDocument(path: "pets/\(petID)")
        }
        for uid in [uidA, uidB].compactMap({ $0 }) { JourneyAdmin.removeProfile(uid: uid) }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    func testARevokedCodeStopsWorkingThenThePrimaryHandsOverAndIsRemoved() throws {
        uidB = try EmulatorAdmin.createVerifiedAccount(email: emailB, password: "Passw0rd!x")
        let (app, a) = try signInAsNewAccount(emailA)
        uidA = a
        let petID = try addPetThroughTheScreens(app, named: petName)
        self.petID = petID

        // --- A: a code, revoked; then a second one
        openFamily(app)
        let revoked = try makeCode(app)
        app.buttons["invite.revoke"].tap()
        XCTAssertTrue(waitForExistence(of: app.buttons["invite.generate"], in: app, timeout: 20),
                      "after revoking, no way to make a new code\n\(app.debugDescription)")
        let invitation = try XCTUnwrap(try JourneyAdmin.fields(path: "pets/\(petID)/invitations/\(revoked)"))
        XCTAssertTrue(JourneyAdmin.bool(invitation["revoked"]) == true || JourneyAdmin.bool(invitation["used"]) == true,
                      "the revoked code is not marked on the server: \(invitation.keys.sorted())")
        let good = try makeCode(app)
        XCTAssertNotEqual(good, revoked)
        popToTabRoot(app, then: "Home")
        signOutFromAccountMenu(app)

        // --- B: the revoked code is refused, the new one works
        signIn(app, email: emailB, expectFeed: false)
        dismissOnboardingIfShown(app)
        XCTAssertTrue(reachedFeed(app))
        app.tabBars.buttons["Profile"].tap()
        app.buttons["profile.joinFamily"].tap()
        let field = app.textFields["join.code"]
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 20))
        field.tap()
        field.typeText(revoked)
        app.buttons["join.check"].tap()
        XCTAssertTrue(waitForExistence(of: app.staticTexts["join.message"], in: app, timeout: 30),
                      "a revoked code was not refused\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["join.relationship.caretaker"].exists, "a revoked code offered to join")
        // Not `replaceText`: the field shows the code as "ABCD EFGH", so what
        // it holds never equals the bare code that was typed.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.9)).tap()
        let shown = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: shown.count))
        field.typeText(good)
        XCTAssertEqual((field.value as? String)?.replacingOccurrences(of: " ", with: ""), good,
                       "the field does not hold the second code")
        app.buttons["join.check"].tap()
        let relationship = app.buttons["join.relationship.caretaker"]
        XCTAssertTrue(waitUntilHittable(relationship, in: app, timeout: 30), "the good code was not accepted")
        relationship.tap()
        app.buttons["join.submit"].tap()
        XCTAssertTrue(waitForExistence(of: app.staticTexts["join.done"], in: app, timeout: 40), "joining was not confirmed")
        let uidB = try XCTUnwrap(uidB)
        XCTAssertEqual(JourneyAdmin.string(try JourneyAdmin.fields(path: "pets/\(petID)/family/\(uidB)")?["role"]), "member")
        popToTabRoot(app, then: "Home")
        signOutFromAccountMenu(app)

        // --- A: hand the primary role to B
        signIn(app, email: emailA, expectFeed: false)
        dismissOnboardingIfShown(app)
        XCTAssertTrue(reachedFeed(app))
        openPetFromProfile(app, petID: petID)
        openFamily(app)
        let transfer = app.buttons["family.transfer"]
        XCTAssertTrue(waitUntilHittable(transfer, in: app, timeout: 20), "the primary is not offered Make primary")
        transfer.tap()
        confirm(app, "Make primary")
        var roles: (a: String?, b: String?) = (nil, nil)
        for _ in 0..<20 {
            roles = (JourneyAdmin.string(try JourneyAdmin.fields(path: "pets/\(petID)/family/\(a)")?["role"]),
                     JourneyAdmin.string(try JourneyAdmin.fields(path: "pets/\(petID)/family/\(uidB)")?["role"]))
            if roles.b == "primary" { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(roles.b, "primary", "the role did not move to B")
        XCTAssertEqual(roles.a, "member", "A is not a member after handing over")
        // A's screen converges: a member manages no one.
        XCTAssertTrue(waitForDisappearance(of: app.buttons["family.remove"], timeout: 20),
                      "A still offered Remove after giving up the primary role")
        popToTabRoot(app, then: "Home")
        signOutFromAccountMenu(app)

        // --- B, now primary, removes A
        signIn(app, email: emailB, expectFeed: false)
        dismissOnboardingIfShown(app)
        XCTAssertTrue(reachedFeed(app))
        openPetFromProfile(app, petID: petID)
        openFamily(app)
        let remove = app.buttons["family.remove"]
        XCTAssertTrue(waitUntilHittable(remove, in: app, timeout: 20), "the new primary is not offered Remove")
        remove.tap()
        confirm(app, "Remove")
        var stillThere = true
        for _ in 0..<20 {
            stillThere = try JourneyAdmin.fields(path: "pets/\(petID)/family/\(a)") != nil
            if !stillThere { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertFalse(stillThere, "A is still in the family on the server")
        XCTAssertEqual(JourneyAdmin.string(try JourneyAdmin.fields(path: "pets/\(petID)/family/\(uidB)")?["role"]), "primary")
        XCTAssertTrue(waitForDisappearance(of: app.buttons["family.remove"], timeout: 20),
                      "the removed member is still listed with a Remove button")
    }

    // MARK: - Steps

    private func openFamily(_ app: XCUIApplication) {
        let family = app.buttons["pet.family"]
        XCTAssertTrue(waitUntilHittable(family, in: app, timeout: 30), "no Owners & invites\n\(app.debugDescription)")
        family.tap()
    }

    private func makeCode(_ app: XCUIApplication) throws -> String {
        let generate = app.buttons["invite.generate"]
        XCTAssertTrue(waitUntilHittable(generate, in: app, timeout: 20), "no way to make a code\n\(app.debugDescription)")
        generate.tap()
        let element = app.staticTexts["invite.code"]
        XCTAssertTrue(waitForExistence(of: element, in: app, timeout: 30), "no code appeared")
        let code = element.label.replacingOccurrences(of: "Invitation code", with: "").replacingOccurrences(of: " ", with: "")
        XCTAssertFalse(code.isEmpty)
        codes.append(code)
        return code
    }

    private func openPetFromProfile(_ app: XCUIApplication, petID: String) {
        app.tabBars.buttons["Profile"].tap()
        let row = app.buttons["profile.pet.\(petID)"]
        XCTAssertTrue(waitUntilHittable(row, in: app, timeout: 30), "the pet is not in My pets\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(waitForExistence(of: app.staticTexts["pet.name"], in: app, timeout: 30))
    }

    private func confirm(_ app: XCUIApplication, _ label: String) {
        let button = app.alerts.buttons[label].exists
            ? app.alerts.buttons[label]
            : app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(waitUntilHittable(button, in: app, timeout: 10), "no \(label) confirmation")
        button.tap()
    }
}
