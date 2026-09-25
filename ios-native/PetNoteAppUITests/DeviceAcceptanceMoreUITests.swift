import XCTest

/// More of the core path on the phone, numbered after `DeviceAcceptanceUITests`:
/// search, a pet page with videos on it, saving a post, settings, and the
/// words on screen when the phone is set to Chinese.
///
/// The same split as there. This drives the interface and asserts what a
/// person would see; it never talks to a backend. What has to be checked on
/// the server — the bookmark — is printed as MEASURED lines for the Mac to
/// look up in petnote-devtest.
///
/// **Either language.** The phone this runs on is probably set to Chinese, and
/// nothing here changes that. So a control is found by its identifier wherever
/// the app gives it one, and where only a label will do — a tab, the system's
/// "Save Password?" sheet, the menu's own statement of which way round it is —
/// by the English or the Chinese word, both taken from `Localizable.xcstrings`
/// (or, for the system sheet, from iOS). Only test 12 cares which one is shown.
final class DeviceAcceptanceMoreUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // As in DeviceAcceptanceUITests: on a simulator these would be run
        // against the emulator, where the seeded account and the pet with
        // videos are different things, and they would fail for that.
        #if targetEnvironment(simulator)
        throw XCTSkip("device acceptance — runs against a phone on petnote-devtest")
        #endif
    }

    /// Set between saving a post and unsaving it, so a run that stops in
    /// between says what it left on the test account. The phone cannot clean
    /// it up from here; the Mac can, and the next run of test 10 unsaves it
    /// first if it opens the same post.
    private var leftSaved: String?

    override func tearDown() {
        if let leftSaved {
            print("MEASURED LEFT BEHIND on \(DeviceAccount.email): \(leftSaved)")
        }
        super.tearDown()
    }

    // MARK: - 8. Search

    func test8SearchingForMochiOpensItsPage() {
        let app = deviceSignedInApp()
        let petID = openMochiFromSearch(app)
        XCTAssertNotNil(petID, "no Mochi among the search results")

        let name = app.staticTexts["pet.name"]
        XCTAssertTrue(waitForExistence(of: name, in: app, timeout: 30),
                      "the result did not open a pet page\n\(app.debugDescription)")
        print("MEASURED pet page opened from search: \(name.label) (\(petID ?? "?"))")
        XCTAssertEqual(name.label, "Mochi")
    }

    // MARK: - 9. A pet page with videos on it

    /// The crash fixed in 1a61171: the pet page was pushed without the video
    /// playback coordinator, and the first video card built on it took the
    /// whole app down. Mochi (`ios-pet-latin`) has three video posts in
    /// petnote-devtest. Mirrors `PetPageUITests`, which checks the same thing
    /// against the emulator.
    func test9MochisPageWithItsVideosOpensAndStaysOpen() {
        let app = deviceSignedInApp()
        let petID = openMochiFromSearch(app)
        let name = app.staticTexts["pet.name"]
        XCTAssertTrue(waitForExistence(of: name, in: app, timeout: 30), "the pet page did not open")
        XCTAssertEqual(name.label, "Mochi")

        // Down the page until a video card has been built. The app's state is
        // asked first each time: a query into an app that has crashed fails
        // with words about the query, and the crash is the finding.
        let video = app.otherElements.matching(identifier: "video.surface").firstMatch
        var swipes = 0
        while app.state == .runningForeground, !video.exists, swipes < 25 {
            app.swipeUp()
            swipes += 1
        }
        let state = app.state
        print("MEASURED pet page \(petID ?? "?"): \(swipes) swipe(s); app: \(deviceDescribe(state))")
        XCTAssertEqual(state, .runningForeground, "the app is gone while scrolling Mochi's page")
        XCTAssertTrue(video.waitForExistence(timeout: 20),
                      "no video card on Mochi's page after \(swipes) swipes\n\(app.debugDescription)")

        // Stays open is a statement about a stretch of time, not a moment: the
        // card is built first and its player starts after, and either is a
        // place for the same crash. So the state is read for a few seconds.
        var readings: [String] = []
        let until = Date().addingTimeInterval(6)
        while Date() < until {
            readings.append(deviceDescribe(app.state))
            if app.state != .runningForeground { break }
            Thread.sleep(forTimeInterval: 1)
        }
        print("MEASURED app state over 6s with a video card on the pet page: \(readings.joined(separator: ","))")
        XCTAssertEqual(app.state, .runningForeground, "the app did not stay open with a video card on screen")

        // Still this page. After the swipes the name may be above the top and
        // out of the tree, so the page's own title counts as well.
        let title = app.navigationBars.matching(deviceMatch("identifier", anyOf: DeviceWords.petTitle)).firstMatch
        XCTAssertTrue(app.staticTexts["pet.name"].exists || title.exists,
                      "the pet page is gone\n\(app.debugDescription)")
    }

    // MARK: - 10. Saving a post, and unsaving it

    /// Saved from the post's menu, seen under Profile → Saved posts, unsaved
    /// from the post opened there, and gone from the list on the way back —
    /// `ProfileEditsUITests.testSavingAPostAndUnsavingIt`, with the server
    /// half left to the Mac.
    ///
    /// The account is left as it was found: unsaved. The saved list is where
    /// the post id comes from, because it is the one screen that names a post
    /// by its id (`saved.post.<id>`), and the Mac needs the id to look at
    /// `users/{uid}/bookmarks/{id}`.
    func test10SavingAPostAndUnsavingItLeavesItUnsaved() {
        let app = deviceSignedInApp()
        let first = app.staticTexts.matching(identifier: "post.text").firstMatch
        XCTAssertTrue(waitForExistence(of: first, in: app, timeout: 90), "the feed never loaded")
        let text = first.label
        XCTAssertFalse(text.isEmpty, "the first post has no text to find it by later")
        print("MEASURED saving the post whose text is: \(text)")
        openPost(app, withText: text)

        // The menu reads the server when it appears, and says which way round
        // it is in its own label. Give that read a moment before believing it.
        waitForQuietUI(app, quietFor: 2, timeout: 10)
        var item = openBookmarkItem(app)
        if DeviceWords.removeFromSaved.contains(item.label) {
            // Saved already: an earlier run stopped between saving and
            // unsaving. Put it back first so what follows starts where it
            // means to, and say so, because it is not the state this test
            // expects to find.
            print("MEASURED the post was already saved when the test began; unsaving it first")
            item.tap()
            XCTAssertTrue(waitForEnabled(app.buttons["post.actions"], timeout: 30), "the unsave never finished")
            waitForQuietUI(app, quietFor: 2, timeout: 10)
            item = openBookmarkItem(app)
        }
        print("MEASURED the menu offers: \(item.label)")
        XCTAssertTrue(DeviceWords.save.contains(item.label), "the menu does not offer Save: \(item.label)")
        item.tap()
        leftSaved = "a bookmark on the post whose text is \(text)"
        // The menu is disabled while the write is out, so enabled again means
        // the app has its answer.
        XCTAssertTrue(waitForEnabled(app.buttons["post.actions"], timeout: 30), "the save never finished")
        print("MEASURED saved at \(Self.timestamp())")

        // Listed under Profile → Saved posts. The list reads the server when
        // it opens; the newest save is first.
        popToFeed(app)
        let profile = deviceTabButton(app, DeviceWords.profileTab)
        XCTAssertTrue(waitUntilHittable(profile, in: app, timeout: 20),
                      "no Profile tab\n\(app.tabBars.firstMatch.debugDescription)")
        profile.tap()
        let savedEntry = app.buttons["profile.saved"]
        for _ in 0..<4 where !(savedEntry.exists && savedEntry.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(savedEntry, in: app, timeout: 20), "no Saved posts on the profile")
        savedEntry.tap()
        // A tile's label ends with the post's text (PostThumbnail.label).
        let tile = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "saved.post.", text
        )).firstMatch
        XCTAssertTrue(waitUntilHittable(tile, in: app, timeout: 30),
                      "the saved post is not in Saved posts\n\(app.debugDescription)")
        let postID = String(tile.identifier.dropFirst("saved.post.".count))
        XCTAssertFalse(postID.isEmpty, "the tile carries no post id: \(tile.identifier)")
        print("MEASURED saved post id: \(postID)")
        leftSaved = "users/{uid}/bookmarks/\(postID)"
        print("MEASURED   Mac: users/{uid of \(DeviceAccount.email)}/bookmarks/\(postID) "
              + "existed between 'saved at' and 'unsaved at', and must not exist after this test")

        // Unsaved from the post the tile opens.
        tile.tap()
        let opened = app.staticTexts.matching(identifier: "post.text").firstMatch
        XCTAssertTrue(waitForExistence(of: opened, in: app, timeout: 30), "the tile opened nothing")
        XCTAssertEqual(opened.label, text, "the tile opened a different post")
        waitForQuietUI(app, quietFor: 2, timeout: 10)
        let remove = openBookmarkItem(app)
        print("MEASURED the menu on the saved post offers: \(remove.label)")
        XCTAssertTrue(DeviceWords.removeFromSaved.contains(remove.label),
                      "the menu does not know the post is saved: \(remove.label)")
        remove.tap()
        XCTAssertTrue(waitForEnabled(app.buttons["post.actions"], timeout: 30), "the unsave never finished")
        print("MEASURED unsaved at \(Self.timestamp())")
        leftSaved = nil

        // And the list agrees on the way back: it reads the server again when
        // it reappears.
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(waitUntilHittable(back, in: app, timeout: 10), "no way back to Saved posts")
        back.tap()
        let gone = waitForDisappearance(of: app.buttons["saved.post.\(postID)"], timeout: 30)
        print("MEASURED saved list after unsaving: tile gone=\(gone), "
              + "empty state shown=\(app.descendants(matching: .any)["saved.empty"].exists)")
        XCTAssertTrue(gone, "Saved posts still lists the post that was unsaved\n\(app.debugDescription)")
    }

    // MARK: - 11. Settings

    /// Settings opens and every section is there. Nothing is changed: rows
    /// are only scrolled to, never tapped, and the switches are read.
    ///
    /// Reached from Profile → Settings, not from the account menu: the menu
    /// holds the signed-in address and Sign out and nothing else, on purpose
    /// (`AccountMenuView`: "Deliberately not a settings screen"). The Profile
    /// row is where the web client's gear is and the only entry the app has.
    func test11SettingsOpensAndShowsEverySection() {
        let app = deviceSignedInApp()
        let profile = deviceTabButton(app, DeviceWords.profileTab)
        XCTAssertTrue(waitUntilHittable(profile, in: app, timeout: 20),
                      "no Profile tab\n\(app.tabBars.firstMatch.debugDescription)")
        profile.tap()
        let entry = app.buttons["profile.settings"]
        for _ in 0..<4 where !(entry.exists && entry.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(entry, in: app, timeout: 30), "no Settings on the profile\n\(app.debugDescription)")
        entry.tap()

        let title = app.navigationBars.matching(deviceMatch("identifier", anyOf: DeviceWords.settingsTitle)).firstMatch
        XCTAssertTrue(waitForExistence(of: title, in: app, timeout: 20), "Settings did not open\n\(app.debugDescription)")
        // The switches only exist once the stored preferences have been read.
        let firstSwitch = app.switches["settings.notify.likeNotifications"]
        XCTAssertTrue(waitForExistence(of: firstSwitch, in: app, timeout: 30),
                      "the notification settings never loaded "
                      + "(failed notice shown: \(app.staticTexts["settings.preferencesFailed"].exists))")

        // Section by section, top to bottom, in SettingsView's order. The
        // language section has no header, only a footer.
        let sections: [(header: [String], rows: [String])] = [
            (["Account", "账号"], ["settings.email", "settings.changePassword", "settings.signOut"]),
            (["Notifications", "通知"], ["settings.notify.likeNotifications",
                                        "settings.notify.commentNotifications",
                                        "settings.notify.followNotifications"]),
            ([], ["settings.language"]),
            (["Privacy", "隐私"], ["settings.blocked"]),
            (["Danger Zone", "风险操作"], ["settings.deleteAccount"]),
            (["About", "关于"], ["settings.contact", "settings.legal.terms", "settings.legal.privacy",
                               "settings.version"]),
        ]
        for section in sections {
            for (index, id) in section.rows.enumerated() {
                let row = id.hasPrefix("settings.notify.")
                    ? app.switches.matching(identifier: id).firstMatch
                    : app.descendants(matching: .any).matching(identifier: id).firstMatch
                XCTAssertTrue(revealWithoutTapping(row, in: app),
                              "Settings has no \(id)\n\(app.debugDescription)")
                if id.hasPrefix("settings.notify.") {
                    print("MEASURED \(id) = \(row.value as? String ?? "?")")
                }
                if id == "settings.version" {
                    print("MEASURED \(id): \(row.label) \(row.value as? String ?? "")")
                }
                // The header is above the first row, so it is on screen once
                // that row is.
                if index == 0, !section.header.isEmpty {
                    let header = app.staticTexts.matching(deviceMatch("label", anyOf: section.header)).firstMatch
                    XCTAssertTrue(header.exists, "no section header \(section.header.joined(separator: " / "))")
                }
            }
        }
        // Nothing was opened on the way: the Language row, tapped, would have
        // put the iPhone's own Settings app in front.
        XCTAssertEqual(app.state, .runningForeground, "PetNote is no longer in front after walking Settings")
        XCTAssertTrue(title.exists, "left Settings while only scrolling it")
    }

    // MARK: - 12. Chinese

    /// When the phone is set to Chinese, the app shows Chinese.
    ///
    /// The strings are the catalog's zh-Hans values for what is on the
    /// sign-in screen and the feed's bars, the same ones LocalizationUITests
    /// checks on a simulator with `-AppleLanguages`. Here nothing is passed:
    /// the phone's own setting is the thing being tested, and it is not
    /// touched.
    ///
    /// Decided the way iOS decides. The app has English and Simplified Chinese
    /// only, so a phone set to Traditional Chinese gets English, and that is
    /// not this test's question: it skips and says so.
    func test12TheAppIsInChineseWhenThePhoneIs() throws {
        let preferred = Locale.preferredLanguages
        let first = preferred.first ?? "none"
        let chosen = Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: preferred).first ?? "none"
        print("MEASURED phone languages: \(preferred.prefix(4).joined(separator: ", ")); "
              + "of en and zh-Hans iOS would choose \(chosen)")
        guard first.hasPrefix("zh") else {
            throw XCTSkip("the phone's first language is \(first), not Chinese")
        }
        guard chosen == "zh-Hans" else {
            throw XCTSkip("the phone's first language is \(first); the app has zh-Hans only and iOS chooses \(chosen) for it")
        }

        let app = deviceLaunch()
        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 60),
                      "sign-in never appeared\n\(app.debugDescription)")
        let submit = app.buttons["login.submit"]
        print("MEASURED sign-in button: \(submit.label)")
        XCTAssertEqual(submit.label, "登录", "the sign-in button is not in Chinese")
        XCTAssertTrue(app.staticTexts["登录以继续"].exists, "the sign-in subtitle is not in Chinese\n\(app.debugDescription)")

        deviceTypeCredentialsAndSubmit(app)
        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 90), "never reached the feed")
        deviceSettleSavePasswordSheet(app)

        // The tabs, including the two whose English words mean something else
        // elsewhere ("Post", "Profile").
        for label in ["首页", "地点", "发布", "聚会", "我的"] {
            XCTAssertTrue(app.tabBars.buttons[label].exists,
                          "no tab \(label)\n\(app.tabBars.firstMatch.debugDescription)")
        }
        print("MEASURED tabs in Chinese: 首页 地点 发布 聚会 我的")
        let bar: [(id: String, zh: String)] = [
            ("feed.search", "搜索"), ("feed.notifications", "通知"), ("account.menu", "账号"),
        ]
        for control in bar {
            let button = app.buttons.matching(identifier: control.id).firstMatch
            XCTAssertTrue(waitUntilHittable(button, in: app, timeout: 20), "no \(control.id)")
            print("MEASURED \(control.id) label: \(button.label)")
            XCTAssertEqual(button.label, control.zh, "\(control.id) is not in Chinese")
        }
        let share = app.buttons.matching(identifier: "post.share").firstMatch
        XCTAssertTrue(waitForExistence(of: share, in: app, timeout: 60), "no post to read the share button from")
        print("MEASURED post.share label: \(share.label)")
        XCTAssertEqual(share.label, "分享", "a post's share button is not in Chinese")
    }

    // MARK: - Steps

    /// From the feed's search button to Mochi's page. Returns the pet id the
    /// result row carries, for the MEASURED lines.
    ///
    /// Typed, then Return, then Return again, each only if the one before did
    /// not bring up a result. The search runs by itself after a pause in
    /// typing, and Return runs it at once — but if the phone's keyboard is
    /// Pinyin, the letters are a composition until the first Return commits
    /// them and only the second one searches. The field's contents are printed
    /// at each step so a failure says which of these happened.
    private func openMochiFromSearch(_ app: XCUIApplication) -> String? {
        let search = app.buttons["feed.search"]
        XCTAssertTrue(waitUntilHittable(search, in: app, timeout: 30), "no search on the feed\n\(app.debugDescription)")
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 20), "no search field\n\(app.debugDescription)")
        field.tap()

        // The seeded Mochi by its id first; any pet row that begins "Mochi"
        // after that, and the printout says which one was opened.
        let seeded = app.buttons["search.pet.ios-pet-latin"]
        let anyMochi = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "search.pet.", "Mochi"
        )).firstMatch
        var found = false
        for (step, keys) in ["Mochi", "\n", "\n"].enumerated() {
            field.typeText(keys)
            found = seeded.waitForExistence(timeout: step == 0 ? 8 : 10) || anyMochi.exists
            print("MEASURED search step \(step + 1): field holds \(field.value as? String ?? "?"); result: \(found)")
            if found { break }
        }
        XCTAssertTrue(found, "search did not find Mochi\n\(app.debugDescription)")
        let result = seeded.exists ? seeded : anyMochi
        let petID = String(result.identifier.dropFirst("search.pet.".count))
        print("MEASURED opening search result \(result.identifier): \(result.label)")
        if !result.isHittable {
            // Under the keyboard: Return puts it away, as tapResult does with
            // the keyboard's Search key, whose label is language-dependent.
            field.typeText("\n")
        }
        XCTAssertTrue(waitUntilHittable(result, in: app, timeout: 20), "the Mochi result cannot be tapped")
        result.tap()
        return petID.isEmpty ? nil : petID
    }

    /// Opens the post menu once the last change has finished, and returns its
    /// save item. Every opening here ends in a tap on that item, so the menu
    /// is never left open with nothing chosen.
    private func openBookmarkItem(_ app: XCUIApplication) -> XCUIElement {
        let menu = app.buttons["post.actions"]
        XCTAssertTrue(waitForEnabled(menu, timeout: 30), "the post menu never became usable")
        XCTAssertTrue(waitUntilHittable(menu, in: app, timeout: 30), "no post menu on this screen")
        menu.tap()
        // By identifier, and by its words if the menu did not carry the
        // identifier through — the fallback JourneySupport.tapMenuItem has.
        let byID = app.buttons["post.actions.bookmark"]
        let item = byID.waitForExistence(timeout: 5)
            ? byID
            : app.buttons.matching(deviceMatch("label", anyOf: DeviceWords.save + DeviceWords.removeFromSaved)).firstMatch
        XCTAssertTrue(waitUntilHittable(item, in: app, timeout: 10), "no save item in the post menu\n\(app.debugDescription)")
        return item
    }

    /// Brings a Settings row on screen by dragging the list slowly, never by
    /// a tap, then back up if it was passed. `nudgeListUp` is a slow drag from
    /// the middle of the row, clear of a switch at its right-hand end.
    private func revealWithoutTapping(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<12 {
            if element.exists, element.isHittable { return true }
            nudgeListUp(app)
        }
        for _ in 0..<12 {
            if element.exists, element.isHittable { return true }
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        return element.exists && element.isHittable
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

// MARK: - Shared by the device suites

/// The seeded account the device suites sign in as (`seed-ios-native.mjs`,
/// the same one `DeviceAcceptanceUITests` types). A test account on the test
/// project, not a person's.
enum DeviceAccount {
    static let email = "accept-a@example.com"
    static let password = "Passw0rd!x"
}

/// Words a device test has to find by label, in the two languages the phone
/// may be set to. The app's from `Localizable.xcstrings` (en → zh-Hans); the
/// system's from iOS.
enum DeviceWords {
    /// The "Save Password?" sheet's way out. "Not Now" rather than "Save", as
    /// in `dismissSavePasswordSheetIfPresent`: saving would put the test
    /// account's password into the owner's own keychain. The Chinese is iOS's,
    /// not ours, and has been worded more than one way, so all of them; none
    /// of them means save.
    static let notNow = ["Not Now", "以后", "现在不", "以后再说", "暂不"]
    /// `tab.profile`.
    static let profileTab = ["Profile", "我的"]
    /// `menu.bookmark` and "Remove from saved".
    static let save = ["Save", "收藏"]
    static let removeFromSaved = ["Remove from saved", "取消收藏"]
    /// Navigation titles: PetProfileView's "Pet", SettingsView's "Settings".
    static let petTitle = ["Pet", "宠物"]
    static let settingsTitle = ["Settings", "设置"]
}

/// `key` equal to any of `words`, ignoring case. Case because an English
/// section header may be drawn in capitals; Chinese has none.
///
/// A free function, not a method on the test case: a predicate returned from
/// a method shares the test case's isolation region, and Swift 6 refuses to
/// hand it to XCUIElementQuery on the main actor. One made here is fresh.
func deviceMatch(_ key: String, anyOf words: [String]) -> NSPredicate {
    NSCompoundPredicate(orPredicateWithSubpredicates: words.map {
        NSPredicate(format: "\(key) ==[c] %@", $0)
    })
}

extension XCTestCase {

    /// A tab by its title in either language. The tab items carry no
    /// identifier of their own — `tab.home` and the rest are on the tabs'
    /// contents — so the title is what there is.
    func deviceTabButton(_ app: XCUIApplication, _ words: [String]) -> XCUIElement {
        app.tabBars.buttons.matching(deviceMatch("label", anyOf: words)).firstMatch
    }

    func deviceLaunch(signedOut: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = signedOut ? ["-petnote-start-signed-out"] : []
        app.launch()
        return app
    }

    /// Types the credentials and submits, and notes when, for
    /// `deviceSettleSavePasswordSheet`. Checks only that the form could be
    /// typed into; whether the feed appeared is the caller's to assert.
    func deviceTypeCredentialsAndSubmit(_ app: XCUIApplication) {
        let email = app.textFields["login.email"]
        XCTAssertTrue(waitUntilHittable(email, in: app, timeout: 30), "the email field never became usable")
        email.tap()
        email.typeText(DeviceAccount.email)
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText(DeviceAccount.password)
        app.buttons["login.submit"].tap()
        SavePasswordPrompt.lastSubmitted = Date()
    }

    /// Launched signed out, signed in by typing, on the feed, and past the
    /// save-password sheet.
    @discardableResult
    func deviceSignedInApp(file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = deviceLaunch()
        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 60),
                      "sign-in never appeared\n\(app.debugDescription)", file: file, line: line)
        deviceTypeCredentialsAndSubmit(app)
        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 90),
                      "never reached the feed", file: file, line: line)
        deviceSettleSavePasswordSheet(app)
        return app
    }

    /// The sheet's "Not Now", in whichever language it came in.
    func deviceNotNowButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(deviceMatch("label", anyOf: DeviceWords.notNow)).firstMatch
    }

    /// `dismissSavePasswordSheetIfPresent`, for a phone that may not be in
    /// English. That helper looks for "Not Now" only, and the waits in
    /// UITestSupport call it — so on a Chinese phone they never clear the
    /// sheet, and whatever is behind it reads as "not hittable".
    func deviceDismissSavePasswordSheet(_ app: XCUIApplication) {
        let notNow = deviceNotNowButton(app)
        guard notNow.exists, notNow.isHittable else { return }
        // Checking and tapping are two moments and the sheet closes itself;
        // one already gone is the outcome wanted anyway.
        if notNow.waitForExistence(timeout: 1), notNow.isHittable {
            notNow.tap()
            SavePasswordPrompt.lastDismissed = Date()
        }
    }

    /// `settleSavePasswordPrompt`, in either language: a typed sign-in is not
    /// over until the system has finished asking about the password, or has
    /// had 25 seconds from Sign in to do so. Says which, as a MEASURED line.
    func deviceSettleSavePasswordSheet(_ app: XCUIApplication, within timeout: TimeInterval = 25) {
        let submitted = SavePasswordPrompt.lastSubmitted ?? Date()
        if let dismissed = SavePasswordPrompt.lastDismissed, dismissed > submitted {
            print("MEASURED save-password sheet: already dismissed for this sign-in")
            return
        }
        let deadline = submitted.addingTimeInterval(timeout)
        let notNow = deviceNotNowButton(app)
        var outcome = "did not come within \(Int(timeout))s of Sign in"
        while Date() < deadline {
            if notNow.exists {
                let arrived = Date().timeIntervalSince(submitted)
                deviceDismissSavePasswordSheet(app)
                let gone = Date().addingTimeInterval(10)
                while notNow.exists, Date() < gone { Thread.sleep(forTimeInterval: 0.25) }
                outcome = String(format: "came %.1fs after Sign in; gone: %@", arrived, notNow.exists ? "no" : "yes")
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        print("MEASURED save-password sheet: \(outcome)")
    }

    func deviceDescribe(_ state: XCUIApplication.State) -> String {
        switch state {
        case .runningForeground: return "foreground"
        case .runningBackground: return "background"
        case .runningBackgroundSuspended: return "suspended"
        case .notRunning: return "not running"
        case .unknown: return "unknown"
        @unknown default: return "state \(state.rawValue)"
        }
    }
}
