import XCTest

/// The feed's "Following" tab through the screens, against the emulator: what
/// it says to someone who follows nobody and where its button goes, then only
/// the posts of the pets they follow — with For You still showing everyone's.
///
/// A fresh account, so nothing a seeded account follows decides the outcome.
/// The follow and the posts are written straight into the emulator in the
/// shapes the app reads: `users/{uid}/followingPets/{petId}` as
/// `followPetCallable` leaves it, and posts as `PostDecoder` reads them.
/// Following from a pet's page is `SocialJourneyUITests`' to check.
///
/// **The followed pet is a real document.** `onFollowingPetCreated` deletes
/// a follow whose pet does not exist, straight away: the first version of
/// this test followed a made-up id, the write answered 200, and by the time
/// the app read the list the follow was gone. The pet has no family, so the
/// trigger has nobody to notify; it counts the follow and writes the pet's
/// follower mirror, and both are taken away with the rest.
final class FollowingFeedUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var uid: String?
    /// Put down before each write, so a write that lands and then times out
    /// on the way back is still removed.
    private var cleanup: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        for path in cleanup.reversed() { JourneyAdmin.deleteDocument(path: path) }
        if let uid { JourneyAdmin.removeProfile(uid: uid) }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    func testFollowingShowsOnlyTheFollowedPetsAndSaysSoWhenThereAreNone() throws {
        let followedPet = "ui-\(run)-followed"
        cleanup.append("pets/\(followedPet)")
        try PlacesMeetupsUITests.write(path: "pets/\(followedPet)", [
            "name": "Followed \(run)", "species": "dog", "ownerId": "ui-\(run)-owner",
            "primaryOwnerId": "ui-\(run)-owner", "avatarUrl": "", "createdAt": Date(),
        ])
        let followedText = "TEST CONTENT following \(run)"
        let otherText = "TEST CONTENT not followed \(run)"
        try writePost(id: "ui-\(run)-followed-post", text: followedText, petID: followedPet)
        try writePost(id: "ui-\(run)-other-post", text: otherText, petID: "ui-\(run)-other")

        let (app, me) = try signInAsNewAccount("following-\(run)@petnote.test")
        uid = me

        // Following nobody.
        let followingTab = app.buttons["feed.tab.following"]
        XCTAssertTrue(waitUntilHittable(followingTab, in: app, timeout: 30),
                      "no Following tab\n\(app.debugDescription)")
        followingTab.tap()
        XCTAssertTrue(followingTab.isSelected, "Following is not said to be the one showing")
        XCTAssertFalse(app.buttons["feed.tab.forYou"].isSelected, "For You is still said to be showing")
        let empty = app.staticTexts["feed.followingEmpty"]
        XCTAssertTrue(waitForExistence(of: empty, in: app, timeout: 30),
                      "following nobody did not say so\n\(app.debugDescription)")

        // Its way out is search, as on the web.
        let discover = app.buttons["feed.discoverPets"]
        XCTAssertTrue(bringIntoReach(discover, in: app, timeout: 20),
                      "Discover Pets could not be reached\n\(app.debugDescription)")
        discover.tap()
        XCTAssertTrue(waitForExistence(of: app.navigationBars["Search"], in: app, timeout: 20),
                      "Discover Pets did not open search\n\(app.debugDescription)")
        popToFeed(app)
        XCTAssertTrue(followingTab.isSelected, "coming back from search changed the tab")

        // One pet followed: after a refresh, its post and no other. Removed
        // before the pet, in reverse: the follow, then the mirror its trigger
        // wrote.
        cleanup.append("pets/\(followedPet)/followers/\(me)")
        cleanup.append("users/\(me)/followingPets/\(followedPet)")
        try PlacesMeetupsUITests.write(path: "users/\(me)/followingPets/\(followedPet)", [
            "petId": followedPet, "petName": "Followed \(run)", "petAvatar": "", "followedAt": Date(),
        ])
        pullToRefreshFeed(app)
        let texts = app.staticTexts.matching(identifier: "post.text")
        let followedPost = texts.matching(NSPredicate(format: "label == %@", followedText)).firstMatch
        let otherPost = texts.matching(NSPredicate(format: "label == %@", otherText)).firstMatch
        XCTAssertTrue(waitForExistence(of: followedPost, in: app, timeout: 30),
                      "the followed pet's post is not in Following\n\(app.debugDescription)")
        XCTAssertFalse(otherPost.exists, "a post of a pet not followed is in Following")
        XCTAssertFalse(empty.exists, "Following still says it is empty")

        // For You is still everyone's.
        app.buttons["feed.tab.forYou"].tap()
        XCTAssertTrue(waitForExistence(of: otherPost, in: app, timeout: 30),
                      "For You lost the post of a pet not followed\n\(app.debugDescription)")
    }

    // MARK: - Emulator writes

    /// The newest post there is, with no picture, so it is the first card and
    /// short enough to be wholly on screen.
    private func writePost(id: String, text: String, petID: String) throws {
        cleanup.append("posts/\(id)")
        try PlacesMeetupsUITests.write(path: "posts/\(id)", [
            "authorId": "ui-\(run)-author", "authorName": "Following \(run)", "authorAvatar": "",
            "text": text, "createdAt": Date(), "likeCount": 0, "commentCount": 0,
            "petId": petID, "petName": "Pet \(run)",
        ])
    }
}
