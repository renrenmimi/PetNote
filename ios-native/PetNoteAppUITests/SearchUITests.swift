import XCTest

/// Search from the home bar's search button, past what `SocialJourneyUITests`
/// already covers (finding a pet by name): people and the profile a result
/// opens, tags and the posts behind a tag, and the discover page shown before
/// anything is typed.
///
/// **Expected results are read from the server, with the queries
/// `FirestoreSearchRepository` runs.** That keeps these tests about the screen
/// — does it show what the server has, in the amounts the web page shows
/// (`src/pages/Search.tsx`: three people, five tags, five posts; the discover
/// page's twelve tags, nine trending posts, eight suggested pets) — rather than
/// about a copy of the seed written down here. The ordering rules applied on
/// top of the queries are `SearchLogic`'s, which `SearchModelTests` pins; each
/// place one is repeated below says which.
///
/// Tags and discovery read the seeded data (functions/scripts/seed-ios-native.mjs
/// tags its posts `test`, `walk`, `nap`, `food`) and write nothing. The person
/// search makes its own person, with two pets, and removes them.
final class SearchUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private let password = "Passw0rd!x"
    private var viewerEmail: String { "search-me-\(run)@petnote.test" }
    private var personEmail: String { "search-them-\(run)@petnote.test" }
    private var personName: String { "Seek\(run)" }
    private var personBio: String { "TEST CONTENT seeker \(run)" }
    private var uidViewer: String?
    private var uidPerson: String?
    private var wrotePets = false

    private struct FixturePet {
        let id: String
        let name: String
        let species: String
        let relationship: String
        /// `PetDisplay.label(for:)` of `relationship`, as the profile row shows it.
        let relationshipLabel: String
    }

    private var personsPets: [FixturePet] {
        [
            FixturePet(id: "ui-\(run)-seek1", name: "Pip \(run)", species: "dog",
                       relationship: "dad", relationshipLabel: "Dad"),
            FixturePet(id: "ui-\(run)-seek2", name: "Taro \(run)", species: "cat",
                       relationship: "caretaker", relationshipLabel: "Caretaker"),
        ]
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        if wrotePets, let uidPerson {
            for pet in personsPets {
                JourneyAdmin.deleteDocument(path: "pets/\(pet.id)/family/\(uidPerson)")
                JourneyAdmin.deleteDocument(path: "pets/\(pet.id)")
            }
        }
        for uid in [uidViewer, uidPerson].compactMap({ $0 }) { JourneyAdmin.removeProfile(uid: uid) }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    // MARK: - People, and the profile a result opens

    func testSearchingForAPersonFindsThemAndTheirProfileShowsWhatTheServerHolds() throws {
        try givenAPersonWithTwoPets()
        let (app, me) = try signInAsNewAccount(viewerEmail)
        uidViewer = me
        let person = try XCTUnwrap(uidPerson)

        // Typed as the name is written; the search is on the lower-cased name.
        let field = openSearchFromHome(app)
        submitSearch(field, personName)
        let result = app.buttons["search.person.\(person)"]
        XCTAssertTrue(waitForExistence(of: result, in: app, timeout: 30),
                      "search did not find \(personName)\n\(app.debugDescription)")
        XCTAssertTrue(result.label.hasPrefix(personName), "the row does not lead with the name: \(result.label)")
        XCTAssertTrue(result.label.contains(personBio), "the row does not carry the bio: \(result.label)")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.person.")).count, 1,
                       "someone other than \(personName) matched")
        // The pet count arrives in a second read, after the row is drawn.
        let serverPets = try ServerFixtures.petIDs(ownedBy: person)
        XCTAssertEqual(serverPets, Set(personsPets.map(\.id)), "precondition: the person has the two pets on the server")
        let counted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "\(serverPets.count) pets"), object: result
        )
        XCTAssertEqual(XCTWaiter().wait(for: [counted], timeout: 20), .completed,
                       "the row never said how many pets: \(result.label)")

        tapResult(result, in: app)
        let name = app.staticTexts["user.name"]
        XCTAssertTrue(waitForExistence(of: name, in: app, timeout: 30),
                      "the result did not open their profile\n\(app.debugDescription)")
        let profile = try XCTUnwrap(try JourneyAdmin.fields(path: "users/\(person)"))
        XCTAssertEqual(name.label, JourneyAdmin.string(profile["displayName"]))
        XCTAssertTrue(app.staticTexts["@\(personName)"].exists, "no @name under the name")
        XCTAssertEqual(app.staticTexts["user.bio"].label, JourneyAdmin.string(profile["bio"]))

        for pet in personsPets {
            let row = app.buttons["user.pet.\(pet.id)"]
            XCTAssertTrue(waitForExistence(of: row, in: app, timeout: 30),
                          "\(pet.name) is theirs on the server and not on their profile\n\(app.debugDescription)")
            XCTAssertTrue(row.label.contains(pet.name), "the row does not name the pet: \(row.label)")
            XCTAssertTrue(row.label.contains(pet.relationshipLabel),
                          "the row does not say what they are to \(pet.name): \(row.label)")
        }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "user.pet.")).count,
                       serverPets.count, "the profile lists a pet the server does not have for them")
        let petCount = app.descendants(matching: .any)["user.petCount"]
        XCTAssertTrue(petCount.label.hasPrefix("\(serverPets.count)"), "the header counts \(petCount.label)")

        // A pet row opens that pet.
        let first = personsPets[0]
        app.buttons["user.pet.\(first.id)"].tap()
        let title = app.staticTexts["pet.name"]
        XCTAssertTrue(waitForExistence(of: title, in: app, timeout: 30), "the pet row opened nothing")
        XCTAssertEqual(title.label, first.name)
    }

    // MARK: - Tags, and the posts behind one

    func testSearchingATagShowsTheTagsAndThenTheTagsPostsAsTheServerHasThem() throws {
        // A seeded tag, found on the server rather than written down, and
        // searched for by its first letters so the result is a prefix match.
        let busiest = try XCTUnwrap(try ServerFixtures.popularTags(limit: 1).first,
                                    "no hashtags in the emulator — run functions/scripts/seed-ios-native.mjs")
        let prefix = String(busiest.name.prefix(3))
        // `tags(prefix:limit: 10)`, then SearchLogic.sortTags (most posts
        // first, ties in name order) and visibleTags (five).
        let expectedTags = try ServerFixtures.tags(startingWith: prefix, limit: 10)
            .enumerated()
            .sorted { $0.element.postCount != $1.element.postCount
                ? $0.element.postCount > $1.element.postCount
                : $0.offset < $1.offset }
            .map { $0.element }
            .prefix(5)
        XCTAssertFalse(expectedTags.isEmpty)

        let (app, me) = try signInAsNewAccount(viewerEmail)
        uidViewer = me
        let field = openSearchFromHome(app)
        submitSearch(field, prefix)
        for tag in expectedTags {
            let row = app.buttons["search.tag.\(tag.name)"]
            XCTAssertTrue(waitForExistence(of: row, in: app, timeout: 30),
                          "#\(tag.name) matches on the server and is not listed\n\(app.debugDescription)")
            XCTAssertTrue(row.label.contains("#\(tag.name)"), "the row does not show the tag: \(row.label)")
            XCTAssertTrue(row.label.hasSuffix(Self.postCountLabel(tag.postCount)),
                          "the row does not show the server's count (\(tag.postCount)): \(row.label)")
        }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.tag.")).count,
                       expectedTags.count, "the tags listed are not the ones the server matched")

        // A tag in the results searches that tag, as `#tag`.
        let chosen = try XCTUnwrap(expectedTags.first)
        tapResult(app.buttons["search.tag.\(chosen.name)"], in: app)
        XCTAssertTrue(waitUntilValue(of: field, equals: "#\(chosen.name)"),
                      "the field does not hold #\(chosen.name): \(String(describing: field.value))")

        // `posts(taggedWith:limit: 50)`, newest first, five shown. The viewer
        // is new and has blocked nobody, so nothing is filtered out.
        let expectedPosts = Array(try ServerFixtures.posts(taggedWith: chosen.name, limit: 50).prefix(5))
        XCTAssertFalse(expectedPosts.isEmpty, "#\(chosen.name) counts \(chosen.postCount) posts and the query finds none")
        for post in expectedPosts {
            let row = app.buttons["search.post.\(post.id)"]
            XCTAssertTrue(reveal(row, in: app),
                          "post \(post.id), tagged #\(chosen.name) on the server, is not in the results\n\(app.debugDescription)")
        }
        let shown = Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.post."))
            .allElementsBoundByIndex.map { $0.identifier })
        XCTAssertTrue(shown.isSubset(of: Set(expectedPosts.map { "search.post.\($0.id)" })),
                      "the results show posts that are not the tag's five newest: \(shown.sorted())")

        // And a post in them opens that post.
        let first = expectedPosts[0]
        let firstRow = app.buttons["search.post.\(first.id)"]
        for _ in 0..<4 where !(firstRow.exists && firstRow.isHittable) { app.swipeDown() }
        tapResult(firstRow, in: app)
        let text = app.staticTexts.matching(identifier: "post.text").firstMatch
        XCTAssertTrue(waitForExistence(of: text, in: app, timeout: 30), "the result did not open the post")
        XCTAssertEqual(text.label, ServerFixtures.string(first.fields, "text"), "the result opened a different post")
    }

    // MARK: - Discover

    func testTheDiscoverPageShowsTheTagsPostsAndPetsTheServerRanks() throws {
        let (app, me) = try signInAsNewAccount(viewerEmail)
        uidViewer = me
        openSearchFromHome(app)

        // Read at about the moment the screen reads them. The seeded data
        // does not move while this runs; nothing here writes.
        let tags = try ServerFixtures.popularTags(limit: 12)
        let since = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        // SearchLogic.trending: ninety candidates, most liked first, newest
        // first on a tie — the query's own order.
        let trending = try ServerFixtures.posts(since: since, limit: 90)
            .enumerated()
            .sorted { lhs, rhs in
                let left = max(0, ServerFixtures.int(lhs.element.fields, "likeCount") ?? 0)
                let right = max(0, ServerFixtures.int(rhs.element.fields, "likeCount") ?? 0)
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map { $0.element }
            .prefix(9)
        // SearchLogic.discover: the fifty most followed, less the ones the
        // viewer follows (none — a new account), first eight.
        let followed = try ServerFixtures.ids(in: "users/\(me)/followingPets")
        let suggested = try ServerFixtures.petsByFollowers(limit: 50)
            .filter { !followed.contains($0.id) }
            .prefix(8)
        XCTAssertFalse(tags.isEmpty, "no hashtags in the emulator — run functions/scripts/seed-ios-native.mjs")
        XCTAssertFalse(suggested.isEmpty, "no pets in the emulator — run functions/scripts/seed-ios-native.mjs")

        // Tags, each with the server's count.
        let chips = app.otherElements["explore.tags"]
        XCTAssertTrue(waitForExistence(of: chips, in: app, timeout: 30),
                      "no tags on the discover page\n\(app.debugDescription)")
        let heading = tags[0].postCount >= 5 ? "Popular Tags" : "Tags in use"
        XCTAssertTrue(app.staticTexts[heading].exists, "the tags are not headed \(heading)")
        for tag in tags {
            let chip = chips.buttons["explore.tag.\(tag.name)"]
            XCTAssertTrue(chip.exists, "#\(tag.name) is among the server's top tags and not on the page")
            XCTAssertEqual(chip.label, "Tag \(tag.name), \(Self.postCountLabel(tag.postCount))")
        }
        XCTAssertEqual(chips.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "explore.tag.")).count,
                       tags.count, "the page shows a tag that is not among the server's top \(tags.count)")

        // Trending posts. A seed older than the seven-day window has none,
        // and then the module is not drawn at all.
        let grid = app.otherElements["explore.trending"]
        if trending.isEmpty {
            XCTAssertFalse(grid.exists, "trending is shown with no post in the last seven days")
        } else {
            XCTAssertTrue(reveal(grid, in: app), "no trending posts on the discover page\n\(app.debugDescription)")
            for post in trending {
                XCTAssertTrue(reveal(grid.buttons["explore.post.\(post.id)"], in: app),
                              "post \(post.id) is trending on the server and not on the page")
            }
            let cells = Set(grid.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "explore.post."))
                .allElementsBoundByIndex.map { $0.identifier })
            XCTAssertTrue(cells.isSubset(of: Set(trending.map { "explore.post.\($0.id)" })),
                          "the page shows a trending post the server does not rank: \(cells.sorted())")
        }

        // Pets to follow, each with the server's follower count.
        let discover = app.otherElements["explore.discover"]
        XCTAssertTrue(reveal(discover, in: app), "no pets to discover on the page\n\(app.debugDescription)")
        for pet in suggested {
            let card = discover.buttons["explore.pet.\(pet.id)"]
            XCTAssertTrue(card.exists, "\(pet.id) is suggested by the server and not on the page")
            let name = try XCTUnwrap(ServerFixtures.petName(pet))
            let followers = max(0, ServerFixtures.int(pet.fields, "followerCount") ?? 0)
            XCTAssertTrue(card.label.hasPrefix(name), "the card does not name \(name): \(card.label)")
            XCTAssertTrue(card.label.hasSuffix(Self.followerCountLabel(followers)),
                          "the card does not show the server's \(followers) followers: \(card.label)")
        }
        XCTAssertEqual(discover.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "explore.pet.")).count,
                       suggested.count, "the page suggests a pet the server does not")

        // A suggestion opens that pet.
        let first = try XCTUnwrap(suggested.first)
        let card = discover.buttons["explore.pet.\(first.id)"]
        XCTAssertTrue(reveal(card, in: app))
        for _ in 0..<3 where !card.isHittable { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(card, in: app, timeout: 10), "the first suggestion cannot be tapped")
        card.tap()
        let title = app.staticTexts["pet.name"]
        XCTAssertTrue(waitForExistence(of: title, in: app, timeout: 30), "the suggestion opened nothing")
        XCTAssertEqual(title.label, ServerFixtures.petName(first))
    }

    // MARK: - Steps

    /// Someone other than the viewer, findable by name, owning two pets.
    private func givenAPersonWithTwoPets() throws {
        let person = try EmulatorAdmin.createVerifiedAccount(email: personEmail, password: password)
        uidPerson = person
        try ServerFixtures.write("users/\(person)", [
            "displayName": personName, "displayNameLower": personName.lowercased(), "bio": personBio,
            "avatarUrl": "", "onboardingComplete": true, "followingPetsCount": 0, "createdAt": Date(),
        ])
        wrotePets = true
        for pet in personsPets {
            try ServerFixtures.write("pets/\(pet.id)", [
                "name": pet.name, "nameLower": pet.name.lowercased(), "species": pet.species,
                "gender": "unknown", "breed": "", "bio": "", "avatarUrl": "",
                "ownerId": person, "primaryOwnerId": person,
                "followerCount": 0, "postCount": 0, "createdAt": Date(),
            ])
            try ServerFixtures.write("pets/\(pet.id)/family/\(person)", [
                "userId": person, "relationship": pet.relationship, "role": "primary", "joinedAt": Date(),
            ])
        }
    }

    /// Scrolls the page until `element` is on it, for sections a lazy stack
    /// has not drawn yet. Up first, then back down.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if waitForExistence(of: element, in: app, timeout: 15) { return true }
        for _ in 0..<4 {
            app.swipeUp()
            if element.waitForExistence(timeout: 2) { return true }
        }
        for _ in 0..<8 {
            app.swipeDown()
            if element.waitForExistence(timeout: 2) { return true }
        }
        return element.exists
    }

    /// `SearchLogic.postCountLabel` and `PetDisplay.followerCount`, in English.
    private static func postCountLabel(_ count: Int) -> String {
        count == 1 ? "1 post" : "\(count) posts"
    }

    private static func followerCountLabel(_ count: Int) -> String {
        count == 1 ? "1 follower" : "\(count) followers"
    }
}
