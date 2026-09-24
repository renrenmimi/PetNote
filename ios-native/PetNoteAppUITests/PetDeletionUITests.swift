import XCTest

/// Deleting a pet from its page, as the one person the app lets: its last
/// owner. And the other half of the same rule — with a second owner, neither
/// owner is offered Delete, and the server refuses the deletion anyway.
///
/// The rule is the server's (`deletePetCallable`, functions/src/pets.ts: it
/// "takes being the only one left"). The app decides what to show from
/// `PetOwnership.canDelete` — a member of a family of at most one — which
/// `PetOwnershipTests` pins without a screen. The web page makes the same
/// split (src/pages/PetProfile.tsx `canDeletePet`), and gives a co-owner
/// "Owners" in place of Delete; here that is "Owners & invites".
///
/// The confirmation's words differ from the web on purpose: the web says
/// "This action cannot be undone", and the app says what survives — the
/// posts — because `onPetDeleted` keeps them (`PetProfileViewModel.deletionConsequences`).
final class PetDeletionUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private let password = "Passw0rd!x"
    private var emailA: String { "petdel-a-\(run)@petnote.test" }
    private var emailB: String { "petdel-b-\(run)@petnote.test" }
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
            }
            JourneyAdmin.deleteDocument(path: "pets/\(petID)")
            // Written with the deletion and removed when its cascade finishes;
            // a run that stopped in between leaves it.
            JourneyAdmin.deleteDocument(path: "petDeletionTasks/\(petID)")
        }
        for uid in [uidA, uidB].compactMap({ $0 }) { JourneyAdmin.removeProfile(uid: uid) }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    func testTheLastOwnerDeletesAPetFromItsPageAndItIsGoneFromTheServerAndTheProfile() throws {
        let (app, me) = try signInAsNewAccount(emailA)
        uidA = me
        let name = "Bye \(run)"
        let petID = try addPetThroughTheScreens(app, named: name)
        self.petID = petID
        XCTAssertEqual(try ServerFixtures.ids(in: "pets/\(petID)/family"), [me],
                       "precondition: the creator is the pet's only owner")
        waitForOwners(app, count: 1)

        openPetMenu(app)
        let delete = app.buttons["pet.delete"]
        XCTAssertTrue(waitUntilHittable(delete, in: app, timeout: 10),
                      "the last owner is not offered Delete\n\(app.debugDescription)")
        delete.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "deleting did not ask first\n\(app.debugDescription)")
        XCTAssertTrue(alert.staticTexts["Delete \(name)?"].exists,
                      "the confirmation does not name the pet\n\(alert.debugDescription)")
        let survives = alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Posts are not deleted"))
        XCTAssertTrue(survives.firstMatch.exists,
                      "the confirmation does not say the posts stay\n\(alert.debugDescription)")
        let confirm = alert.buttons["Delete"]
        XCTAssertTrue(confirm.exists, "the confirmation has no Delete")
        confirm.tap()

        // The server first. The pet goes in the callable's transaction; its
        // family goes in the cascade after it, and the record of owed work is
        // cleared only when that cascade finishes — so all three are waited for.
        let petGone = try serverEventually { try JourneyAdmin.fields(path: "pets/\(petID)") == nil }
        XCTAssertTrue(petGone, "the pet is still on the server")
        let familyGone = try serverEventually { try ServerFixtures.ids(in: "pets/\(petID)/family").isEmpty }
        XCTAssertTrue(familyGone, "the pet's family outlived it")
        let cascadeDone = try serverEventually { try JourneyAdmin.fields(path: "petDeletionTasks/\(petID)") == nil }
        XCTAssertTrue(cascadeDone, "the deletion's cleanup never finished")

        // The screen: off the deleted pet's page, onto the profile, and the
        // pet no longer listed there.
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts["pet.name"], timeout: 30),
                      "still on the deleted pet's page\n\(app.debugDescription)")
        XCTAssertTrue(waitForExistence(of: app.staticTexts["profile.pets.empty"], in: app, timeout: 30),
                      "My pets did not notice the pet is gone\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["profile.pet.\(petID)"].exists, "the deleted pet is still listed on the profile")
    }

    func testWithASecondOwnerNeitherOwnerIsOfferedDeleteAndTheServerRefusesIt() throws {
        let b = try EmulatorAdmin.createVerifiedAccount(email: emailB, password: password)
        uidB = b
        let (app, a) = try signInAsNewAccount(emailA)
        uidA = a
        let name = "Shared \(run)"
        let petID = try addPetThroughTheScreens(app, named: name)
        self.petID = petID

        // B becomes an owner by a document written the way
        // redeemInvitationCallable writes one. Not through an invitation:
        // that path has its own tests (SocialJourneyUITests,
        // FamilyManageUITests), and all this one needs is a family of two.
        try ServerFixtures.write("pets/\(petID)/family/\(b)", [
            "userId": b, "userName": "Second \(run)", "relationship": "caretaker",
            "role": "member", "joinedAt": Date(),
        ])
        XCTAssertEqual(try ServerFixtures.ids(in: "pets/\(petID)/family"), [a, b])

        // A, the primary: out and back in, so the page reads the family it
        // has now rather than the one it was drawn for.
        popToTabRoot(app)
        openOwnPet(app, petID: petID)
        assertNoDeleteOffered(app, owners: 2, to: "the primary owner")

        // The server agrees, in its own words.
        let token = try ServerFixtures.idToken(email: emailA, password: password)
        let refused = try ServerFixtures.call("deletePetCallable", ["petId": petID], idToken: token)
        XCTAssertEqual(refused.status, 400, "deletePetCallable did not refuse: HTTP \(refused.status) \(refused.text)")
        XCTAssertTrue(refused.text.contains("FAILED_PRECONDITION"), "refused, but not as the last-owner rule: \(refused.text)")
        XCTAssertNotNil(try JourneyAdmin.fields(path: "pets/\(petID)"), "the server deleted a pet that has two owners")

        // B, the other owner, sees the same page.
        popToTabRoot(app, then: "Home")
        signOutFromAccountMenu(app)
        signIn(app, email: emailB, password: password, expectFeed: false)
        dismissOnboardingIfShown(app)
        XCTAssertTrue(reachedFeed(app), "B did not reach the feed")
        openOwnPet(app, petID: petID)
        assertNoDeleteOffered(app, owners: 2, to: "the second owner")
        XCTAssertNotNil(try JourneyAdmin.fields(path: "pets/\(petID)"))
    }

    // MARK: - Steps

    /// The family has been read — the page says how many owners — and the
    /// menu is live. Until the family read lands the menu is disabled
    /// (`permissions` offers nothing on a read that has not happened), and a
    /// tap on it then does nothing at all.
    private func waitForOwners(_ app: XCUIApplication, count: Int) {
        let owners = app.staticTexts["pet.ownerCount"]
        XCTAssertTrue(waitForExistence(of: owners, in: app, timeout: 30),
                      "the pet's owners never loaded\n\(app.debugDescription)")
        let expected = count == 1 ? "1 owner" : "\(count) owners"
        XCTAssertTrue(waitUntilLabel(of: owners, equals: expected),
                      "the page says \(owners.label); the server has \(count)")
        XCTAssertTrue(waitForEnabled(app.buttons["pet.menu"], timeout: 20), "the pet menu never became available")
    }

    private func assertNoDeleteOffered(_ app: XCUIApplication, owners: Int, to who: String) {
        waitForOwners(app, count: owners)
        XCTAssertTrue(waitForExistence(of: app.buttons["pet.family"], in: app, timeout: 10),
                      "\(who) is not offered Owners & invites, the way out a co-owner has instead")
        openPetMenu(app)
        XCTAssertTrue(waitUntilHittable(app.buttons["pet.edit"], in: app, timeout: 10), "\(who) is not offered Edit")
        XCTAssertFalse(app.buttons["pet.delete"].exists, "\(who) is offered Delete on a pet with \(owners) owners")
        closePetMenu(app)
    }

    private func openPetMenu(_ app: XCUIApplication) {
        let menu = app.buttons["pet.menu"]
        XCTAssertTrue(waitUntilHittable(menu, in: app, timeout: 20), "no pet menu")
        menu.tap()
    }

    /// A tap outside a menu closes it and goes no further. The navigation
    /// bar's title is somewhere a tap that did go further would land on
    /// nothing.
    private func closePetMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertTrue(waitForDisappearance(of: app.buttons["pet.edit"], timeout: 10), "the pet menu would not close")
    }
}
