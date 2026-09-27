import XCTest

/// The owner's 09-26 decisions, driven through the app: the save button on a
/// post's own row, the person's picture in the feed bar, both ways out of a
/// back swipe, the last post of a list clear of the tab bar, and Create —
/// and the four defects the 09-26 acceptance found around them: the tab bar
/// on a pet page opened from search, the pet page's heart, a slow drag on the
/// share button, and the sign-in card moving under the keyboard.
final class PostRowAndAccountUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var createdUID: String?
    private var temporaryPosts: [String] = []
    private var temporaryLikes: [(post: String, uid: String)] = []

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        for like in temporaryLikes { _ = Self.rest("DELETE", "posts/\(like.post)/likes/\(like.uid)") }
        for id in temporaryPosts { _ = Self.rest("DELETE", "posts/\(id)") }
        if let createdUID { JourneyAdmin.removeProfile(uid: createdUID) }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    // MARK: - Save, from the row

    /// Saved from the card: the detail screen's row and its menu say so, the
    /// menu can take it back and the card follows, and a fresh launch reads
    /// the same from the server — the state does not fall back.
    func testSavingFromThePostRowIsWhatTheMenuAndAFreshLaunchSay() throws {
        let (app, uid) = try signInAsNewAccount("row-save-\(run)@petnote.test")
        createdUID = uid

        let save = app.buttons.matching(identifier: "post.bookmark").firstMatch
        XCTAssertTrue(waitUntilHittable(save, in: app, timeout: 30), "no save button on the first card")
        XCTAssertEqual(save.label, "Save")
        XCTAssertGreaterThanOrEqual(save.frame.height, 44)
        XCTAssertGreaterThanOrEqual(save.frame.width, 44)
        save.tap()
        XCTAssertTrue(waitForLabel(save, "Remove from saved"), "the button did not say it was saved")
        XCTAssertTrue(eventually { (try? Self.bookmarkIDs(uid).count) == 1 }, "no bookmark reached the server")
        let postID = try XCTUnwrap(try Self.bookmarkIDs(uid).first)

        // The detail screen: its own row and its menu say the same.
        openFirstPost(app)
        let detailSave = app.buttons.matching(identifier: "post.bookmark").firstMatch
        XCTAssertTrue(waitForLabel(detailSave, "Remove from saved"), "the detail row disagrees with the card")
        let menu = app.buttons["post.actions"]
        XCTAssertTrue(waitUntilHittable(menu, in: app, timeout: 20))
        menu.tap()
        let menuItem = app.buttons["post.actions.bookmark"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 10))
        XCTAssertEqual(menuItem.label, "Remove from saved", "the menu disagrees with the row")
        // Taken back from the menu: the row follows.
        menuItem.tap()
        XCTAssertTrue(waitForLabel(detailSave, "Save"), "the row did not follow the menu")
        XCTAssertTrue(eventually { (try? Self.bookmarkIDs(uid).isEmpty) == true }, "the unsave did not reach the server")

        // Saved again from the detail row, then a fresh launch.
        detailSave.tap()
        XCTAssertTrue(waitForLabel(detailSave, "Remove from saved"))
        XCTAssertTrue(eventually { (try? Self.bookmarkIDs(uid)) == [postID] })
        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launch()
        XCTAssertTrue(reachedFeed(relaunched), "the session did not come back")
        // Onboarding's dismissal is for the session; a new launch offers it again.
        dismissOnboardingIfShown(relaunched)
        let again = relaunched.buttons.matching(identifier: "post.bookmark").firstMatch
        XCTAssertTrue(waitForLabel(again, "Remove from saved"), "a fresh launch lost the save")
        again.tap()
        XCTAssertTrue(waitForLabel(again, "Save"))
        XCTAssertTrue(eventually { (try? Self.bookmarkIDs(uid).isEmpty) == true })
    }

    // MARK: - The account entry

    /// The person's own picture when there is one; the placeholder when there
    /// is none and when the picture does not load. Always "Account" to
    /// VoiceOver, and always the way into the menu.
    func testTheFeedBarShowsThePersonsOwnPictureAndThePlaceholderWithoutOne() throws {
        let (app, uid) = try signInAsNewAccount("row-avatar-\(run)@petnote.test")
        createdUID = uid
        let entry = app.buttons["account.menu"]
        XCTAssertTrue(waitUntilHittable(entry, in: app, timeout: 30))
        XCTAssertEqual(entry.label, "Account")
        let before = Self.colourfulness(of: entry)
        print("MEASURED account entry colourfulness, no picture: \(before)")
        XCTAssertLessThan(before, 0.05, "a new account has no picture; the placeholder should show")

        try Self.setAvatar(uid, "https://res.cloudinary.com/demo/image/upload/sample.jpg")
        reopenTheFeed(app)
        XCTAssertTrue(
            eventually(timeout: 30) { Self.colourfulness(of: entry) > 0.2 },
            "the picture never replaced the placeholder (\(Self.colourfulness(of: entry)))"
        )
        print("MEASURED account entry colourfulness, with a picture: \(Self.colourfulness(of: entry))")
        XCTAssertEqual(entry.label, "Account")

        // One that does not load: the placeholder again, not a blank.
        try Self.setAvatar(uid, "https://res.cloudinary.com/demo/image/upload/petnote-test-missing-avatar-\(run).jpg")
        reopenTheFeed(app)
        XCTAssertTrue(
            eventually(timeout: 30) { Self.colourfulness(of: entry) < 0.05 },
            "a picture that fails left something other than the placeholder (\(Self.colourfulness(of: entry)))"
        )

        entry.tap()
        XCTAssertTrue(app.buttons["session.signOut"].waitForExistence(timeout: 10), "the entry did not open the menu")
    }

    // MARK: - Back

    /// A third of a swipe from the edge, released slowly, is not a back: the
    /// post stays and so does what was typed. All the way across is a back,
    /// and — the confirmed rule, the web client's too — an unsent comment
    /// does not survive leaving the post.
    func testAPartBackSwipeKeepsTheCommentAndAFullOneLeaves() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        openFirstPost(app)
        let field = app.textFields["composer.field"]
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 20))
        field.tap()
        field.typeText("part swipe \(run)")
        XCTAssertTrue(app.navigationBars["Post"].exists)

        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.35))
        edge.press(
            forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35)),
            withVelocity: .slow, thenHoldForDuration: 0.6
        )
        _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
        XCTAssertTrue(app.navigationBars["Post"].exists, "a third of a swipe went back")
        XCTAssertEqual(field.value as? String, "part swipe \(run)", "the comment was lost on a cancelled back")

        edge.press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.35)),
            withVelocity: .fast, thenHoldForDuration: 0
        )
        XCTAssertTrue(app.navigationBars["PetNote"].waitForExistence(timeout: 10), "a full swipe did not go back")

        openFirstPost(app)
        let reopened = app.textFields["composer.field"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 20))
        XCTAssertFalse(
            ((reopened.value as? String) ?? "").contains("part swipe"),
            "an unsent comment came back, which the confirmed rule says it does not"
        )
    }

    // MARK: - The end of a list

    /// Scrolled to the very end, a list's last post — a video here — sits
    /// above the tab bar, with its controls reachable: the bar floats over
    /// the list and must not keep the last of it underneath.
    func testThePetPagesLastPostAndItsVideoClearTheTabBar() throws {
        let accountA = try XCTUnwrap(try JourneyAdmin.uid(forEmail: "accept-a@example.com"))
        // Three posts on the acceptance seed's Mochi, which has none; the
        // oldest — last on its page — is a video.
        let now = Date()
        for (index, video) in [(0, false), (1, false), (2, true)] {
            let id = "row-end-\(run)-\(index)"
            try Self.createPost(
                id: id, authorID: accountA, petID: "accept-pet",
                text: "TEST CONTENT end of list \(index) \(run)",
                createdAt: now.addingTimeInterval(TimeInterval(-60 * (index + 1))),
                video: video
            )
            temporaryPosts.append(id)
        }

        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        let search = app.buttons["feed.search"]
        XCTAssertTrue(waitUntilHittable(search, in: app, timeout: 30))
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 20))
        field.tap()
        field.typeText("Mochi\n")
        let result = app.buttons["search.pet.accept-pet"]
        XCTAssertTrue(waitUntilHittable(result, in: app, timeout: 30), "search did not find the acceptance Mochi")
        result.tap()
        XCTAssertTrue(app.staticTexts["pet.name"].waitForExistence(timeout: 30))

        let lastText = app.staticTexts
            .matching(NSPredicate(format: "label == %@", "TEST CONTENT end of list 2 \(run)")).firstMatch
        for _ in 0..<6 where !(lastText.exists && lastText.isHittable) { app.swipeUp() }
        // And on past the end, so what shows is where the list stops.
        app.swipeUp()
        _ = waitForQuietUI(app, quietFor: 1, timeout: 10)

        // The shell's rule hides the tab bar on a pet's page. Opened from
        // search it used to show anyway (fixed 09-26, see
        // `testAPetPageHidesTheTabBarWhicheverWayItIsOpened`); the bottom is
        // still measured against whichever is there.
        let window = app.windows.firstMatch.frame
        let tabBar = app.tabBars.firstMatch
        let barShowing = Self.tabBarShown(app)
        print("MEASURED tab bar showing on the pet page: \(barShowing) \(barShowing ? "\(tabBar.frame)" : "")")
        XCTAssertFalse(barShowing, "the tab bar is showing on a pet page opened from search")
        let barTop = barShowing ? tabBar.frame.minY : window.maxY - 34
        XCTAssertTrue(lastText.exists, "the last post's text is not in the tree")
        print("MEASURED last text \(lastText.frame) tab bar top \(barTop)")
        XCTAssertLessThanOrEqual(lastText.frame.maxY, barTop, "the last post's text ends under the tab bar")
        XCTAssertTrue(lastText.isHittable, "the last post's text cannot be reached")

        // The page has one video, the last post's: firstMatch is it, and it
        // is resolved when each property is read rather than collected first.
        let surface = app.otherElements.matching(identifier: "video.surface").firstMatch
        let mute = app.buttons.matching(identifier: "video.mute").firstMatch
        XCTAssertTrue(surface.exists, "the last post's video is not on screen")
        print("MEASURED last video \(surface.frame)")
        XCTAssertLessThanOrEqual(surface.frame.maxY, barTop, "the last video ends under the tab bar")
        if mute.exists {
            XCTAssertLessThanOrEqual(mute.frame.maxY, barTop, "the last video's control is under the tab bar")
            XCTAssertTrue(mute.isHittable, "the last video's control cannot be reached")
        }
    }

    // MARK: - Found in the 09-26 acceptance

    /// The shell hides the tab bar on a pet's page. Opened from search it
    /// stayed up, because search asked for `.visible` and that held for the
    /// screen pushed over it; opened from the profile it hid.
    func testAPetPageHidesTheTabBarWhicheverWayItIsOpened() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        openTheAcceptanceMochiFromSearch(app)
        XCTAssertFalse(Self.tabBarShown(app), "the tab bar is showing on a pet page opened from search")

        // From the profile, in a fresh launch that keeps the session.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(reachedFeed(app), "the relaunch did not keep the session")
        let profile = app.tabBars.buttons["Profile"]
        XCTAssertTrue(waitUntilHittable(profile, in: app, timeout: 20))
        profile.tap()
        let pet = app.buttons["profile.pet.accept-pet"]
        XCTAssertTrue(waitUntilHittable(pet, in: app, timeout: 30), "the acceptance Mochi is not on the profile")
        pet.tap()
        XCTAssertTrue(app.staticTexts["pet.name"].waitForExistence(timeout: 30))
        _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
        XCTAssertFalse(Self.tabBarShown(app), "the tab bar is showing on a pet page opened from the profile")
    }

    /// The pet page's heart was `onLike: {}`: drawn, tappable, and doing
    /// nothing. It now likes and unlikes, on screen and on the server.
    func testTheHeartOnAPetPageLikesAndUnlikesThePost() throws {
        let accountA = try XCTUnwrap(try JourneyAdmin.uid(forEmail: "accept-a@example.com"))
        let id = "pet-like-\(run)"
        let text = "TEST CONTENT pet page like \(run)"
        // The newest post on the page, so it is the first card.
        try Self.createPost(id: id, authorID: accountA, petID: "accept-pet", text: text,
                            createdAt: Date(), video: false)
        temporaryPosts.append(id)

        let (app, uid) = try signInAsNewAccount("pet-like-\(run)@petnote.test")
        createdUID = uid
        temporaryLikes.append((post: id, uid: uid))
        openTheAcceptanceMochiFromSearch(app)

        let first = app.staticTexts.matching(identifier: "post.text").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30), "the pet page has no posts")
        XCTAssertEqual(first.label, text, "the temporary post is not the first card")
        let heart = app.buttons.matching(identifier: "post.like").firstMatch
        for _ in 0..<4 where !(heart.exists && heart.isHittable) { nudgeFeedUp(app) }
        XCTAssertTrue(waitUntilHittable(heart, in: app, timeout: 10), "the first card's heart cannot be reached")
        XCTAssertEqual(heart.label, "Like")
        XCTAssertEqual(heart.value as? String, "0 likes")

        heart.tap()
        XCTAssertTrue(waitForLabel(heart, "Unlike"), "the heart did not fill")
        XCTAssertTrue(eventually { (heart.value as? String) == "1 likes" }, "the count did not move: \(String(describing: heart.value))")
        XCTAssertTrue(eventually { Self.rest("GET", "posts/\(id)/likes/\(uid)") == 200 },
                      "no like on the server")

        heart.tap()
        XCTAssertTrue(waitForLabel(heart, "Like"), "the heart did not empty")
        XCTAssertTrue(eventually { (heart.value as? String) == "0 likes" }, "the count did not come back")
        XCTAssertTrue(eventually { Self.rest("GET", "posts/\(id)/likes/\(uid)") == 404 },
                      "the like is still on the server")
    }

    /// A slow drag that begins on a card's share button moves the feed, as
    /// one from the heart beside it does. It was a `Menu` and moved 0pt.
    func testASlowDragThatStartsOnTheShareButtonMovesTheFeed() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        let shares = app.buttons.matching(identifier: "post.share")
        XCTAssertTrue(shares.firstMatch.waitForExistence(timeout: 30))
        // A share button in the middle of the screen, brought there from the
        // margin beside the cards.
        var share = shares.firstMatch
        for _ in 0..<8 {
            share = shares.firstMatch
            let frame = share.frame
            if frame.midY > 350, frame.midY < 600 { break }
            if frame.midY >= 600 { nudgeFeedUp(app) } else { app.swipeUp() }
        }
        let start = share.frame
        XCTAssertTrue(start.midY > 350 && start.midY < 600, "no share button in the middle of the screen: \(start)")
        let texts = app.staticTexts.matching(identifier: "post.text")
        let reference = texts.element(matching: NSPredicate(format: "label == %@",
                                                              texts.firstMatch.label))
        let before = reference.frame.minY

        let from = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: start.midX, dy: start.midY))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -200)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        _ = waitForQuietUI(app, quietFor: 1, timeout: 10)

        let moved = before - reference.frame.minY
        print("MEASURED slow drag from the share button moved the feed \(moved)pt")
        XCTAssertGreaterThan(moved, 150, "the feed did not follow a slow drag from the share button")
        XCTAssertFalse(app.buttons["Copy Link"].exists, "the drag opened the share choices")
    }

    /// The card is centred in the height without the keyboard, so the
    /// keyboard coming up does not move it: the field about to be tapped is
    /// where it was seen. It jumped 112pt, and on the phone the device
    /// suite's taps landed where the password field had just been.
    func testTheSignInCardStaysPutWhenTheKeyboardComesUp() {
        let app = launchOnSignIn()
        let email = app.textFields["login.email"]
        let password = app.secureTextFields["login.password"]
        let submit = app.buttons["login.submit"]
        XCTAssertTrue(waitUntilHittable(email, in: app, timeout: 30))
        let resting = password.frame

        email.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "no keyboard came up")
        _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
        XCTAssertEqual(password.frame.minY, resting.minY, accuracy: 1, "the card moved when the keyboard came up")

        email.typeText("accept-a@example.com")
        password.tap()
        XCTAssertTrue(eventually { password.hasKeyboardFocusValue }, "the password field did not take the tap")
        _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
        XCTAssertEqual(password.frame.minY, resting.minY, accuracy: 1, "the card moved when the password field took focus")
        let keyboard = app.keyboards.firstMatch.frame
        XCTAssertLessThanOrEqual(submit.frame.maxY, keyboard.minY, "Sign in is under the keyboard")
    }

    // MARK: - Create

    /// The composer tab: named, tappable, and it opens the composer.
    func testCreateIsNamedTappableAndOpensTheComposer() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        let create = app.tabBars.buttons["Create"]
        XCTAssertTrue(waitUntilHittable(create, in: app, timeout: 20), "Create is not reachable")
        XCTAssertGreaterThanOrEqual(create.frame.height, 44)
        XCTAssertGreaterThanOrEqual(create.frame.width, 44)
        create.tap()
        XCTAssertTrue(app.buttons["compose.addMedia"].waitForExistence(timeout: 20), "Create did not open the composer")
    }

    // MARK: - Helpers

    private func openTheAcceptanceMochiFromSearch(_ app: XCUIApplication) {
        let search = app.buttons["feed.search"]
        XCTAssertTrue(waitUntilHittable(search, in: app, timeout: 30))
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 20))
        field.tap()
        field.typeText("Mochi\n")
        let result = app.buttons["search.pet.accept-pet"]
        XCTAssertTrue(waitUntilHittable(result, in: app, timeout: 30), "search did not find the acceptance Mochi")
        result.tap()
        XCTAssertTrue(app.staticTexts["pet.name"].waitForExistence(timeout: 30))
        _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
    }

    private static func tabBarShown(_ app: XCUIApplication) -> Bool {
        let bar = app.tabBars.firstMatch
        guard bar.exists else { return false }
        let frame = bar.frame
        return !frame.isEmpty && frame.minY < app.windows.firstMatch.frame.maxY
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 20) -> Bool {
        eventually(timeout: timeout) { element.exists && element.label == label }
    }

    private func eventually(timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    /// Away to the profile tab and back: the feed reads the picture again.
    private func reopenTheFeed(_ app: XCUIApplication) {
        app.tabBars.buttons["Profile"].tap()
        app.tabBars.buttons["Home"].tap()
        _ = app.navigationBars["PetNote"].waitForExistence(timeout: 10)
    }

    /// The share of an element's pixels that are clearly coloured: near 0 for
    /// the grey placeholder on the bar's glass, well above it for a photo.
    private static func colourfulness(of element: XCUIElement) -> Double {
        guard element.exists, let image = element.screenshot().image.cgImage else { return -1 }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return -1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var coloured = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]), g = Double(pixels[index + 1]), b = Double(pixels[index + 2])
            let high = max(r, g, b), low = min(r, g, b)
            if high > 40, (high - low) / high > 0.3 { coloured += 1 }
        }
        return Double(coloured) / Double(width * height)
    }

    // MARK: - The emulator, directly

    private static var documents: String {
        "\(EmulatorAdmin.firestore)/v1/projects/\(EmulatorAdmin.projectID)/databases/(default)/documents"
    }

    @discardableResult
    private static func rest(_ method: String, _ path: String, query: String = "", body: [String: Any]? = nil) -> Int {
        var request = URLRequest(url: URL(string: "\(documents)/\(path)\(query)")!)
        request.httpMethod = method
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        let done = DispatchSemaphore(value: 0)
        var status = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        return status
    }

    private static func bookmarkIDs(_ uid: String) throws -> Set<String> {
        let listed = try EmulatorAdmin.get("\(documents)/users/\(uid)/bookmarks?pageSize=50", owner: true)
        let rows = listed["documents"] as? [[String: Any]] ?? []
        return Set(rows.compactMap { ($0["name"] as? String)?.components(separatedBy: "/").last })
    }

    private static func setAvatar(_ uid: String, _ url: String) throws {
        let status = rest(
            "PATCH", "users/\(uid)", query: "?updateMask.fieldPaths=avatarUrl",
            body: ["fields": ["avatarUrl": ["stringValue": url]]]
        )
        guard status == 200 else {
            throw NSError(domain: "PostRowAndAccountUITests", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "could not set the avatar: HTTP \(status)"])
        }
    }

    private static func createPost(
        id: String, authorID: String, petID: String, text: String, createdAt: Date, video: Bool
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let media: [String: Any] = video
            ? ["mapValue": ["fields": [
                "url": ["stringValue": "https://res.cloudinary.com/demo/video/upload/v1/dog.mp4"],
                "type": ["stringValue": "video"],
                "thumbUrl": ["stringValue": "https://res.cloudinary.com/demo/video/upload/so_0,w_800,q_auto,f_auto/v1/dog.jpg"],
            ]]]
            : ["mapValue": ["fields": [
                "url": ["stringValue": "https://res.cloudinary.com/demo/image/upload/sample.jpg"],
                "type": ["stringValue": "image"],
            ]]]
        let fields: [String: Any] = [
            "authorId": ["stringValue": authorID],
            "authorName": ["stringValue": "Accept A"],
            "petId": ["stringValue": petID],
            "petName": ["stringValue": "Mochi"],
            "text": ["stringValue": text],
            "media": ["arrayValue": ["values": [media]]],
            "createdAt": ["timestampValue": formatter.string(from: createdAt)],
        ]
        let status = rest("PATCH", "posts/\(id)", body: ["fields": fields])
        guard status == 200 else {
            throw NSError(domain: "PostRowAndAccountUITests", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "could not create post \(id): HTTP \(status)"])
        }
    }
}
