import XCTest

/// The two follow lists — who follows a pet, and the pets I follow — reached
/// from where the app offers them and read against the server; and someone
/// else's profile, opened from the first of them.
///
/// Three people. A owns the pet and never signs in. C already follows it: C's
/// `followingPets` document is written straight into the emulator in the shape
/// `followPetCallable` writes, so `onFollowingPetCreated` runs for C exactly
/// as it runs for anybody — it is what puts a follower into
/// `pets/{pet}/followers` and counts them. B is the person at the screen and
/// follows through the screens (as `SocialJourneyUITests` does).
///
/// The rows carry identifiers made from the server's own ids —
/// `followers.user.<uid>`, `following.pet.<petId>` — so "the list matches the
/// server" is compared id for id rather than by names, which two new
/// accounts can share.
final class SocialListsUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private let password = "Passw0rd!x"
    private var emailA: String { "lists-a-\(run)@petnote.test" }
    private var emailB: String { "lists-b-\(run)@petnote.test" }
    private var emailC: String { "lists-c-\(run)@petnote.test" }
    private var petID: String { "ui-\(run)-followed" }
    private var petName: String { "Tofu \(run)" }
    private var fanName: String { "Fan\(run)" }
    private var fanBio: String { "TEST CONTENT fan \(run)" }
    private var uidA: String?
    private var uidB: String?
    private var uidC: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        // The follows first: deleting one runs onFollowingPetDeleted, which
        // removes the follower entry and gives the counts back, while the pet
        // and the profiles are still there to be given back to.
        for uid in [uidB, uidC].compactMap({ $0 }) {
            JourneyAdmin.deleteDocument(path: "users/\(uid)/followingPets/\(petID)")
            JourneyAdmin.deleteDocument(path: "pets/\(petID)/followers/\(uid)")
        }
        if let uidA {
            JourneyAdmin.deleteDocument(path: "pets/\(petID)/family/\(uidA)")
            // Each counted follow told the pet's owner.
            ServerFixtures.deleteNotifications(for: uidA)
        }
        JourneyAdmin.deleteDocument(path: "pets/\(petID)")
        for uid in [uidA, uidB, uidC].compactMap({ $0 }) { JourneyAdmin.removeProfile(uid: uid) }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    func testTheFollowerListAndThePetsIFollowMatchTheServerAndAFollowerOpensTheirProfile() throws {
        try givenAPetThatCAlreadyFollows()

        // --- B follows it, through the screens
        let (app, b) = try signInAsNewAccount(emailB)
        uidB = b
        // B's row will carry the name the server knew when the follow was
        // counted, so the profile that name comes from has to exist first.
        let named = try serverEventually {
            let profile = try JourneyAdmin.fields(path: "users/\(b)")
            return !(JourneyAdmin.string(profile?["displayName"]) ?? "").isEmpty
        }
        XCTAssertTrue(named, "B's profile was never created")

        let field = openSearchFromHome(app)
        submitSearch(field, petName)
        tapResult(app.buttons["search.pet.\(petID)"], in: app)
        XCTAssertTrue(waitForExistence(of: app.staticTexts["pet.name"], in: app, timeout: 30),
                      "the result did not open the pet")
        let follow = app.buttons["follow.toggle"]
        XCTAssertTrue(waitUntilLabel(of: follow, equals: "Follow \(petName)", timeout: 30),
                      "a visitor is not offered Follow\n\(app.debugDescription)")
        follow.tap()
        XCTAssertTrue(waitUntilLabel(of: follow, equals: "Following \(petName)"), "the button never said Following")
        let followed = try serverEventually {
            try JourneyAdmin.fields(path: "users/\(b)/followingPets/\(petID)") != nil
        }
        XCTAssertTrue(followed, "the follow was not written")
        let counted = try serverEventually {
            try JourneyAdmin.fields(path: "pets/\(petID)/followers/\(b)") != nil
        }
        XCTAssertTrue(counted, "B never reached the pet's follower list on the server")

        // --- Followers, from the count on the pet's page
        let followers = try ServerFixtures.documents(in: "pets/\(petID)/followers")
        XCTAssertEqual(Set(followers.map(\.id)), [b, uidC ?? ""], "the server's followers are not B and C")
        let followerCount = app.buttons["pet.followers"]
        XCTAssertTrue(waitUntilLabel(of: followerCount, equals: "\(followers.count) followers"),
                      "the page says \(followerCount.label); the server has \(followers.count)")
        followerCount.tap()
        XCTAssertTrue(app.navigationBars["Followers"].waitForExistence(timeout: 20), "the follower list did not open")
        for follower in followers {
            let row = app.buttons["followers.user.\(follower.id)"]
            XCTAssertTrue(waitForExistence(of: row, in: app, timeout: 30),
                          "\(follower.id) follows on the server and is not listed\n\(app.debugDescription)")
            XCTAssertEqual(row.label, ServerFixtures.string(follower.fields, "userName"),
                           "the row does not show the name the server holds")
        }
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "followers.user."))
        XCTAssertEqual(rows.count, followers.count, "the list shows a follower the server does not have")
        // Newest first, as the list is ordered on the server.
        let c = try XCTUnwrap(uidC)
        XCTAssertLessThan(app.buttons["followers.user.\(b)"].frame.minY, app.buttons["followers.user.\(c)"].frame.minY,
                          "the newest follower is not first")

        // --- Someone else's profile, from a follower's row
        app.buttons["followers.user.\(c)"].tap()
        let shownName = app.staticTexts["user.name"]
        XCTAssertTrue(waitForExistence(of: shownName, in: app, timeout: 30),
                      "the row did not open a profile\n\(app.debugDescription)")
        let profile = try XCTUnwrap(try JourneyAdmin.fields(path: "users/\(c)"))
        XCTAssertEqual(shownName.label, JourneyAdmin.string(profile["displayName"]))
        XCTAssertEqual(app.staticTexts["user.bio"].label, JourneyAdmin.string(profile["bio"]))

        // --- The pets B follows, from the profile
        popToTabRoot(app, then: "Profile")
        let link = app.buttons["profile.following"]
        for _ in 0..<4 where !(link.exists && link.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(link, in: app, timeout: 20), "no Pets you follow on the profile")
        link.tap()
        XCTAssertTrue(app.navigationBars["Following"].waitForExistence(timeout: 20), "the list did not open")
        let following = try ServerFixtures.documents(in: "users/\(b)/followingPets")
        XCTAssertEqual(following.map(\.id), [petID], "precondition: on the server B follows this pet and no other")
        let row = app.buttons["following.pet.\(petID)"]
        XCTAssertTrue(waitForExistence(of: row, in: app, timeout: 30),
                      "the followed pet is not listed\n\(app.debugDescription)")
        XCTAssertEqual(row.label, ServerFixtures.string(following[0].fields, "petName"))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "following.pet.")).count,
                       following.count, "the list shows a pet the server does not have B following")
        row.tap()
        let title = app.staticTexts["pet.name"]
        XCTAssertTrue(waitForExistence(of: title, in: app, timeout: 30), "the row did not open the pet")
        XCTAssertEqual(title.label, petName)
    }

    // MARK: - Fixtures

    /// A's pet, and C following it — counted by the trigger before B arrives.
    private func givenAPetThatCAlreadyFollows() throws {
        let a = try EmulatorAdmin.createVerifiedAccount(email: emailA, password: password)
        uidA = a
        try ServerFixtures.write("pets/\(petID)", [
            "name": petName, "nameLower": petName.lowercased(), "species": "cat", "gender": "unknown",
            "breed": "", "bio": "", "avatarUrl": "", "ownerId": a, "primaryOwnerId": a,
            "followerCount": 0, "postCount": 0, "createdAt": Date(),
        ])
        try ServerFixtures.write("pets/\(petID)/family/\(a)", [
            "userId": a, "relationship": "mom", "role": "primary", "joinedAt": Date(),
        ])

        let c = try EmulatorAdmin.createVerifiedAccount(email: emailC, password: password)
        uidC = c
        try ServerFixtures.write("users/\(c)", [
            "displayName": fanName, "displayNameLower": fanName.lowercased(), "bio": fanBio,
            "avatarUrl": "", "onboardingComplete": true, "followingPetsCount": 0, "createdAt": Date(),
        ])
        try ServerFixtures.write("users/\(c)/followingPets/\(petID)", [
            "petId": petID, "petName": petName, "petAvatar": "", "followedAt": Date(), "counted": false,
        ])
        let mirrored = try serverEventually {
            try JourneyAdmin.fields(path: "pets/\(petID)/followers/\(c)") != nil
        }
        XCTAssertTrue(mirrored, "onFollowingPetCreated never listed C as a follower — is the functions emulator running?")
    }
}
