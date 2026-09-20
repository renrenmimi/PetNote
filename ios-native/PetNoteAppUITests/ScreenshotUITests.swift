import XCTest

/// Drives the core path and writes screenshots somewhere a person can open
/// them. Not assertions — evidence.
///
/// These run on a simulator, so what they prove is L4: the screens compose and
/// the data arrives. How any of it looks and feels on a phone is L5 and needs
/// the device.
final class ScreenshotUITests: XCTestCase {
    private let outputDirectory = "/tmp/petnote-shots"

    override func setUp() {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(
            atPath: outputDirectory, withIntermediateDirectories: true
        )
    }

    private func shoot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(name).png"))
    }

    func testCapturesTheCorePath() {
        let app = XCUIApplication()
        app.launchArguments = ["-petnote-start-signed-out"]
        app.launch()

        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 15))
        shoot("01-login")

        let email = app.textFields["login.email"]
        email.tap()
        email.typeText("accept-a@example.com")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("Passw0rd!x")
        app.buttons["login.submit"].tap()

        XCTAssertTrue(
            waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 40),
            "Never reached the feed"
        )
        waitForQuietUI(app)
        // Images arrive over the network; give the first screenful a moment so
        // the shot shows the loaded state rather than placeholders.
        Thread.sleep(forTimeInterval: 4)
        shoot("02-feed")

        // Scroll far enough to prove paging actually appended.
        let list = app.collectionViews.firstMatch.exists
            ? app.collectionViews.firstMatch
            : app.tables.firstMatch
        for _ in 0..<6 { list.swipeUp(velocity: .fast) }
        Thread.sleep(forTimeInterval: 3)
        shoot("03-feed-scrolled")

        // Into a post.
        let firstComments = app.buttons.matching(identifier: "post.comments").firstMatch
        if firstComments.waitForExistence(timeout: 10), firstComments.isHittable {
            firstComments.tap()
            Thread.sleep(forTimeInterval: 4)
            shoot("04-detail")

            let field = app.textFields["composer.field"]
            if field.waitForExistence(timeout: 10) {
                field.tap()
                field.typeText("TEST CONTENT 来自原生客户端的评论")
                Thread.sleep(forTimeInterval: 1)
                shoot("05-composer")
            }
        }
    }
}

/// The accessibility walk, and what it is and is not evidence of.
///
/// **It is a tool check.** It reads the accessibility tree the app publishes:
/// whether each control is an element at all, whether it has a label, whether
/// the label says something, whether the traversal order matches reading order,
/// and whether the core path can be completed by addressing elements rather
/// than screen coordinates.
///
/// **It is not VoiceOver.** XCUITest's `tap()` is a synthesised touch at the
/// element's centre; VoiceOver's activation is a different path through UIKit,
/// its traversal is driven by the rotor and by swipe gestures, and none of that
/// runs here. An element can be perfectly labelled and still be unreachable by
/// swipe, or reachable and announced as nonsense. Acceptance 6.1/6.1b/6.1c ask
/// for "只用 VoiceOver 手势，不看屏幕" — that needs a person with a device and
/// the screen curtain on, and nothing in this file substitutes for it.
///
/// What this catches is the class of defect that makes the human test pointless
/// before it starts: a control that is not an accessibility element, a label
/// that is empty or is the raw identifier, an action only reachable by tapping
/// a region that publishes no element at all.
final class AccessibilityWalkUITests: XCTestCase {
    private let outputDirectory = "/tmp/petnote-a11y"

    override func setUp() {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(
            atPath: outputDirectory, withIntermediateDirectories: true
        )
    }

    /// Appearance and text size are set from outside with `simctl ui`, not from
    /// a launch argument, because `-UIUserInterfaceStyle` only affects the
    /// process and the acceptance items are about the device setting. The tag
    /// is passed in so the artefacts say which run they came from.
    private var tag: String {
        ProcessInfo.processInfo.environment["PETNOTE_A11Y_TAG"] ?? "default"
    }

    private func signedIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-petnote-start-signed-out"]
        app.launch()
        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 15))
        let email = app.textFields["login.email"]
        email.tap(); email.typeText("accept-a@example.com")
        let password = app.secureTextFields["login.password"]
        password.tap(); password.typeText("Passw0rd!x")
        app.buttons["login.submit"].tap()
        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 40))
        waitForQuietUI(app)
        return app
    }

    private func shoot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(tag)-\(name).png"))
    }

    /// Every element that is on screen, in the order the tree reports, with the
    /// facts a screen reader would use.
    private func dump(_ app: XCUIApplication, _ screen: String) -> [String] {
        let window = app.windows.firstMatch.frame
        var lines: [String] = []
        for type in [XCUIElement.ElementType.button, .staticText, .textField, .secureTextField, .image] {
            for element in app.descendants(matching: type).allElementsBoundByIndex {
                guard element.exists, !element.frame.isEmpty, window.intersects(element.frame) else { continue }
                let id = element.identifier.isEmpty ? "-" : element.identifier
                lines.append("\(screen)\t\(type.rawValue)\tid=\(id)\tlabel=\(element.label)\tframe=\(element.frame)")
            }
        }
        return lines
    }

    func testTheCorePathIsWalkableByElementAndEverythingIsLabelled() {
        let app = signedIn()
        var report: [String] = ["tag=\(tag)"]
        var unlabelled: [String] = []

        // --- Feed -----------------------------------------------------------
        //
        // Existence, not hittability. At AX5 one post card is taller than the
        // screen, so the first card's like/comment row sits below the fold and
        // `isHittable` is false — which is a fact about the layout, not a
        // defect, and must not abort the walk before it has recorded anything.
        let firstLike = app.buttons.matching(identifier: "post.like").firstMatch
        XCTAssertTrue(firstLike.waitForExistence(timeout: 30), "the feed never produced a post")
        report.append("firstLike hittable=\(firstLike.isHittable) frame=\(firstLike.frame)")
        Thread.sleep(forTimeInterval: 3)
        shoot("01-feed")
        report += dump(app, "feed")

        // Every control we own must say what it is. An unlabelled button is
        // announced as its class name, which is the single most common reason a
        // VoiceOver run stops being possible.
        for button in app.buttons.allElementsBoundByIndex
        where button.exists && !button.identifier.isEmpty && !button.frame.isEmpty {
            if button.label.trimmingCharacters(in: .whitespaces).isEmpty {
                unlabelled.append("feed button \(button.identifier)")
            }
            // A label that is just the identifier is a label nobody wrote.
            if button.label == button.identifier {
                unlabelled.append("feed button \(button.identifier) is labelled with its own identifier")
            }
        }

        // The card body opens the post. Is that an *element*?
        //
        // It is a `.contentShape` plus `.onTapGesture` on a VStack whose
        // children are themselves elements, so there may be nothing focusable
        // that carries the action — in which case the only way into a post
        // without sight is the Comments button, and "open this post" is not
        // available at all. Recorded either way; this is a fact about the tree,
        // not a judgement.
        let cardText = app.staticTexts.matching(identifier: "post.text").firstMatch
        report.append("post.text isButton=\(cardText.elementType == .button) "
                      + "exists=\(cardText.exists) label=\(cardText.label)")

        // --- Feed -> detail, by element ------------------------------------
        let comments = app.buttons.matching(identifier: "post.comments").firstMatch
        XCTAssertFalse(comments.label.isEmpty, "the way into a post has no label")
        comments.tap()
        XCTAssertTrue(waitForExistence(of: app.navigationBars["Post"], in: app, timeout: 30),
                      "could not reach the detail screen by activating a labelled element")
        Thread.sleep(forTimeInterval: 3)
        shoot("02-detail")
        report += dump(app, "detail")

        // --- Composer -------------------------------------------------------
        let field = app.textFields["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no composer element")
        report.append("composer.field label=\(field.label) value=\(field.value as? String ?? "-")")
        field.tap()
        field.typeText("TEST CONTENT a11y walk")
        Thread.sleep(forTimeInterval: 1)
        shoot("03-composer")
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.label.isEmpty, "the send button has no label")
        report.append("composer.send label=\(send.label) enabled=\(send.isEnabled)")

        // --- Back, by element ----------------------------------------------
        let back = app.navigationBars["Post"].buttons.element(boundBy: 0)
        report.append("back label=\(back.label) frame=\(back.frame)")
        XCTAssertFalse(back.label.isEmpty, "the back button has no label")
        back.tap()
        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 20),
                      "could not get back by activating a labelled element")
        shoot("04-back")

        // --- Geometry under whatever text size this run uses ----------------
        //
        // Two things are checkable without eyes: a control that has shrunk
        // below the minimum, and content that has been pushed outside the
        // window horizontally. Truncation is not one of them — a truncated
        // label reports its full text — so it stays a human check.
        let window = app.windows.firstMatch.frame
        var tooSmall: [String] = []
        var overflowing: [String] = []
        // What the size check actually looked at.
        //
        // Without this the check is the exact failure this whole audit is
        // about: at AX5 the only identified button on screen is the navigation
        // bar's, which is excluded by rule, so `tooSmall` comes back empty
        // because **nothing was measured** — and an empty list reads like a
        // pass. The same shape as a video ceiling test that never creates a
        // player. So the names of the controls that were checked are recorded,
        // and an empty set fails.
        var checked: [String] = []
        let barIDs = Set(app.navigationBars.buttons.allElementsBoundByIndex
            .filter { $0.exists }.map { $0.identifier })
        for button in app.buttons.allElementsBoundByIndex
        where button.exists && !button.identifier.isEmpty && !button.frame.isEmpty
            && window.intersects(button.frame) && !barIDs.contains(button.identifier) {
            checked.append(button.identifier)
            if button.frame.height < 44 {
                tooSmall.append("\(button.identifier)=\(button.frame.height)pt")
            }
        }
        for element in app.staticTexts.allElementsBoundByIndex
        where element.exists && !element.frame.isEmpty && window.intersects(element.frame) {
            if element.frame.minX < window.minX - 0.5 || element.frame.maxX > window.maxX + 0.5 {
                overflowing.append("\(element.identifier.isEmpty ? element.label : element.identifier)"
                                   + "=\(element.frame)")
            }
        }
        report.append("controlsChecked=\(checked.joined(separator: ","))")
        report.append("tooSmall=\(tooSmall.joined(separator: ","))")
        report.append("overflowingHorizontally=\(overflowing.joined(separator: ","))")
        report.append("unlabelled=\(unlabelled.joined(separator: ","))")

        try? report.joined(separator: "\n")
            .write(toFile: "\(outputDirectory)/\(tag)-walk.txt", atomically: true, encoding: .utf8)
        for line in report { print("A11Y \(line)") }

        XCTAssertTrue(unlabelled.isEmpty, "unlabelled controls: \(unlabelled)")
        XCTAssertFalse(
            checked.isEmpty,
            "the 44pt check measured nothing — an empty tooSmall list here means "
                + "no control was on screen, not that every control is big enough"
        )
        XCTAssertTrue(tooSmall.isEmpty, "controls under 44pt at this text size: \(tooSmall)")
        XCTAssertTrue(overflowing.isEmpty, "content pushed outside the window: \(overflowing)")
    }
}
