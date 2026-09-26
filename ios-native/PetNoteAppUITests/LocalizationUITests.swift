import XCTest

/// The app with the iPhone set to Chinese: the words on the screens, read
/// off the screens. The catalog being complete is `LocalizationTests`; this
/// is the check that the running app actually chose it.
final class LocalizationUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var uid: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        if let uid { JourneyAdmin.removeProfile(uid: uid) }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    func testTheAppInChinese() throws {
        let (app, me) = try signInAsNewAccount(
            "zh-\(run)@petnote.test",
            extraArguments: ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        )
        uid = me

        // The tabs, including the two whose English words mean something
        // else elsewhere ("Create", "Profile").
        for label in ["首页", "地点", "发布", "聚会", "我的"] {
            XCTAssertTrue(app.tabBars.buttons[label].exists, "no tab \(label)\n\(app.tabBars.firstMatch.debugDescription)")
        }
        XCTAssertEqual(app.buttons["feed.notifications"].label, "通知")
        XCTAssertEqual(app.buttons["feed.search"].label, "搜索")

        // A post's share menu.
        let share = app.buttons.matching(identifier: "post.share").firstMatch
        XCTAssertTrue(waitUntilHittable(share, in: app, timeout: 30), "no share button")
        XCTAssertEqual(share.label, "分享")
        share.tap()
        for label in ["复制链接", "分享到…", "分享为图片"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), "the share menu has no \(label)\n\(app.debugDescription)")
        }
        app.buttons["复制链接"].tap()

        // Settings, section by section.
        app.tabBars.buttons["我的"].tap()
        let settings = app.buttons["profile.settings"]
        XCTAssertTrue(waitUntilHittable(settings, in: app, timeout: 20))
        settings.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 20), "no Settings title in Chinese\n\(app.debugDescription)")
        for header in ["账号", "通知", "隐私"] {
            XCTAssertTrue(app.staticTexts[header].exists, "no section \(header)\n\(app.debugDescription)")
        }
        XCTAssertTrue(app.buttons["settings.changePassword"].label.contains("修改密码"))
        XCTAssertTrue(app.buttons["settings.signOut"].label.contains("退出登录"))

        // Change Password: the password rules, which were plain English
        // strings until they were made translatable.
        app.buttons["settings.changePassword"].tap()
        let field = app.secureTextFields["changePassword.new"]
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 20))
        field.tap()
        field.typeText("a")
        let rule = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '至少 8 个字符'")).firstMatch
        XCTAssertTrue(rule.waitForExistence(timeout: 10), "a password rule is not in Chinese\n\(app.debugDescription)")
    }
}
