import XCTest

/// Two people and one pet, through the screens, against the emulator:
/// A adds a pet and makes an invitation code; B joins with it and becomes an
/// owner; B leaves; B follows the pet as a visitor, then unfollows.
///
/// Every step is a tap or a keystroke, and every change is read back from the
/// server — the family document, the follow document — because the screen
/// saying "you're an owner" proves the screen drew it, and the question is
/// whether `redeemInvitationCallable` wrote it.
///
/// Fresh accounts rather than the seeded ones: joining a family changes who
/// owns a pet, and the seeded pets are what other suites read. Everything this
/// creates is removed in `tearDown`.
final class SocialJourneyUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private let password = "Passw0rd!x"
    private var emailA: String { "social-a-\(run)@petnote.test" }
    private var emailB: String { "social-b-\(run)@petnote.test" }
    private var petName: String { "Pudding \(run)" }

    private var uidA: String?
    private var uidB: String?
    private var petID: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        if let petID {
            for uid in [uidA, uidB].compactMap({ $0 }) {
                JourneyAdmin.deleteDocument(path: "pets/\(petID)/family/\(uid)")
                JourneyAdmin.deleteDocument(path: "pets/\(petID)/followers/\(uid)")
                JourneyAdmin.deleteDocument(path: "users/\(uid)/followingPets/\(petID)")
            }
            for name in (try? JourneyAdmin.documentNames(in: "invitations", field: "petId", equals: petID)) ?? [] {
                EmulatorAdmin.deleteComment(documentName: name)
            }
            JourneyAdmin.deleteDocument(path: "pets/\(petID)")
        }
        for uid in [uidA, uidB].compactMap({ $0 }) {
            if let name = try? JourneyAdmin.fields(path: "users/\(uid)").flatMap({ JourneyAdmin.string($0["displayName"]) }) {
                JourneyAdmin.deleteDocument(path: "usernames/\(JourneyAdmin.reservationID(for: name))")
            }
            JourneyAdmin.deleteDocument(path: "users/\(uid)")
        }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    func testTwoPeopleShareAPetThroughAnInvitationAndOneLeaves() throws {
        uidA = try EmulatorAdmin.createVerifiedAccount(email: emailA, password: password)
        uidB = try EmulatorAdmin.createVerifiedAccount(email: emailB, password: password)
        let uidA = try XCTUnwrap(uidA), uidB = try XCTUnwrap(uidB)

        // --- A: a pet and an invitation code
        let app = launchOnSignIn()
        signIn(app, email: emailA, password: password, expectFeed: false)
        closeOnboardingIfShown(app)
        let petID = try addPet(app)
        self.petID = petID
        app.buttons["pet.family"].tap()
        let generate = app.buttons["invite.generate"]
        XCTAssertTrue(waitUntilHittable(generate, in: app, timeout: 20),
                      "no way to make an invitation\n\(app.debugDescription)")
        generate.tap()
        let codeElement = app.staticTexts["invite.code"]
        XCTAssertTrue(waitForExistence(of: codeElement, in: app, timeout: 30), "no invitation code appeared")
        // Read one character at a time for VoiceOver: "Invitation code A B C …".
        let code = codeElement.label
            .replacingOccurrences(of: "Invitation code", with: "")
            .replacingOccurrences(of: " ", with: "")
        XCTAssertFalse(code.isEmpty, "the invitation code was empty")
        let invitations = try JourneyAdmin.documentNames(in: "invitations", field: "petId", equals: petID)
        XCTAssertEqual(invitations.count, 1, "expected one invitation on the server")

        popToRoot(app)
        signOutFromAccountMenu(app)

        // --- B: join with the code
        signIn(app, email: emailB, password: password, expectFeed: false)
        closeOnboardingIfShown(app)
        app.tabBars.buttons["Profile"].tap()
        let join = app.buttons["profile.joinFamily"]
        XCTAssertTrue(waitUntilHittable(join, in: app, timeout: 30), "no Join a pet's family on the profile")
        join.tap()
        let codeField = app.textFields["join.code"]
        XCTAssertTrue(waitUntilHittable(codeField, in: app, timeout: 20))
        codeField.tap()
        codeField.typeText(code)
        app.buttons["join.check"].tap()
        let relationship = app.buttons["join.relationship.caretaker"]
        XCTAssertTrue(waitUntilHittable(relationship, in: app, timeout: 30),
                      "the code was not accepted\n\(app.debugDescription)")
        relationship.tap()
        app.buttons["join.submit"].tap()

        // Joining lands on the pet's page, now as an owner.
        let title = app.staticTexts["pet.name"]
        XCTAssertTrue(waitForExistence(of: title, in: app, timeout: 40),
                      "joining did not open the pet\n\(app.debugDescription)")
        XCTAssertEqual(title.label, petName)
        XCTAssertTrue(waitForExistence(of: app.buttons["pet.family"], in: app, timeout: 20),
                      "B joined but is not offered the family controls")
        let membership = try XCTUnwrap(try JourneyAdmin.fields(path: "pets/\(petID)/family/\(uidB)"),
                                       "the server has no family document for B")
        XCTAssertEqual(JourneyAdmin.string(membership["role"]), "member", "B should join as a member, not primary")
        XCTAssertNotNil(try JourneyAdmin.fields(path: "pets/\(petID)/family/\(uidA)"), "A is no longer in the family")

        // --- B leaves
        app.buttons["pet.family"].tap()
        let leave = app.buttons["family.leave"]
        for _ in 0..<4 where !(leave.exists && leave.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(leave, in: app, timeout: 20), "a member is not offered Leave")
        leave.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Leave'")).firstMatch
        XCTAssertTrue(waitUntilHittable(confirm, in: app, timeout: 10), "no confirmation for leaving")
        confirm.tap()
        var stillMember = true
        for _ in 0..<20 {
            stillMember = try JourneyAdmin.fields(path: "pets/\(petID)/family/\(uidB)") != nil
            if !stillMember { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertFalse(stillMember, "B left on screen but is still in the family on the server")
        XCTAssertNotNil(try JourneyAdmin.fields(path: "pets/\(petID)/family/\(uidA)"),
                        "B leaving took A out of the family")

        // --- B, now a visitor, follows and unfollows
        // Leaving takes B off the family screen and the pet page it was drawn
        // for; the pet is reached again the way any visitor reaches it.
        openPet(app, petID: petID)
        let follow = app.buttons.matching(NSPredicate(format: "label == %@", "Follow \(petName)")).firstMatch
        XCTAssertTrue(waitUntilHittable(follow, in: app, timeout: 30),
                      "a visitor is not offered Follow\n\(app.debugDescription)")
        follow.tap()
        let following = app.buttons.matching(NSPredicate(format: "label == %@", "Following \(petName)")).firstMatch
        XCTAssertTrue(waitForExistence(of: following, in: app, timeout: 20), "the button never said Following")
        XCTAssertNotNil(try JourneyAdmin.fields(path: "users/\(uidB)/followingPets/\(petID)"),
                        "the follow was not written")
        following.tap()
        XCTAssertTrue(waitForExistence(of: follow, in: app, timeout: 20), "the button never went back to Follow")
        var stillFollowing = true
        for _ in 0..<20 {
            stillFollowing = try JourneyAdmin.fields(path: "users/\(uidB)/followingPets/\(petID)") != nil
            if !stillFollowing { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertFalse(stillFollowing, "the unfollow was not written")
    }

    // MARK: - Steps

    private func closeOnboardingIfShown(_ app: XCUIApplication) {
        // A fresh account has not been through onboarding, so it is offered;
        // closing it is the session-only dismissal the web client has.
        let close = app.buttons["onboarding.close"]
        if close.waitForExistence(timeout: 15) { close.tap() }
        XCTAssertTrue(reachedFeed(app), "did not reach the feed")
    }

    private func addPet(_ app: XCUIApplication) throws -> String {
        app.tabBars.buttons["Profile"].tap()
        let add = app.buttons["profile.addPet"]
        XCTAssertTrue(waitUntilHittable(add, in: app, timeout: 30), "no Add a pet")
        add.tap()
        let name = app.textFields["petEditor.name"]
        XCTAssertTrue(waitUntilHittable(name, in: app, timeout: 20))
        name.tap()
        name.typeText(petName)
        for (picker, option) in [("petEditor.species", "Cat"), ("petEditor.relationship", "Mom")] {
            let control = app.buttons[picker]
            for _ in 0..<4 where !(control.exists && control.isHittable) { app.swipeUp() }
            XCTAssertTrue(waitUntilHittable(control, in: app, timeout: 10), "no \(picker)")
            control.tap()
            let choice = app.buttons[option]
            XCTAssertTrue(waitUntilHittable(choice, in: app, timeout: 10), "no \(option)")
            choice.tap()
        }
        let save = app.buttons["petEditor.save"]
        for _ in 0..<6 where !(save.exists && save.isHittable) { app.swipeUp() }
        save.tap()
        XCTAssertTrue(waitForExistence(of: app.staticTexts["pet.name"], in: app, timeout: 40),
                      "the new pet's page did not open")
        let pets = try JourneyAdmin.documentNames(in: "pets", field: "name", equals: petName)
        return try XCTUnwrap(pets.first?.split(separator: "/").last.map(String.init), "the pet is not on the server")
    }

    private func openPet(_ app: XCUIApplication, petID: String) {
        // Not in B's pets any more, so reached the way a visitor reaches it.
        app.tabBars.buttons["Home"].tap()
        let search = app.buttons["feed.search"]
        XCTAssertTrue(waitUntilHittable(search, in: app, timeout: 20), "no search on the feed")
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 20), "no search field\n\(app.debugDescription)")
        field.tap()
        field.typeText(petName + "\n")
        // BEGINSWITH, not CONTAINS: the card's own Follow button is labelled
        // "Follow <name>", and tapping that would follow instead of open.
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", petName)).firstMatch
        XCTAssertTrue(waitUntilHittable(result, in: app, timeout: 30),
                      "search did not find the pet\n\(app.debugDescription)")
        result.tap()
        XCTAssertTrue(waitForExistence(of: app.staticTexts["pet.name"], in: app, timeout: 30),
                      "the search result did not open the pet")
    }

    private func popToRoot(_ app: XCUIApplication) {
        for _ in 0..<4 {
            let back = app.navigationBars.buttons["BackButton"]
            guard back.exists, back.isHittable else { break }
            back.tap()
        }
        app.tabBars.buttons["Home"].tap()
    }
}
