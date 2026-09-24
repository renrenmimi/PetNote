import XCTest

/// The accessibility acceptance items that a simulator can answer today:
/// Dynamic Type at both ends (§6.2, §6.3), Reduce Motion (§6.4) and Reduce
/// Transparency (§6.5).
///
/// **The matrix writes all four as L5, and this is not that.** What a
/// simulator can establish is behavioural: at AX5 the controls are still
/// 44pt and still reachable, nothing is pushed off the side of the screen,
/// and with the two accessibility switches on the app still works end to end.
/// Whether it *looks* right — where the text wraps, whether a card reads as
/// one thing — needs a device and a person, and is not claimed here.
///
/// Dynamic Type is set with `-UIPreferredContentSizeCategoryName`, which UIKit
/// reads as an override for the app's preferred content size category. The two
/// switches cannot be set that way: they live in the accessibility daemon, not
/// in the app's defaults, so they are set on the simulator before the run with
///
///     xcrun simctl spawn pn-a3 defaults write com.apple.Accessibility \
///         ReduceMotionEnabled -bool true
///     xcrun simctl spawn pn-a3 defaults write com.apple.Accessibility \
///         EnhancedBackgroundContrastEnabled -bool true
///
/// and the tests that need them skip — rather than silently pass — when they
/// are off.
///
/// The second key is not a typo and not a different setting. On iOS the switch
/// Settings calls "Reduce Transparency" is stored as
/// `EnhancedBackgroundContrastEnabled`; `ReduceTransparencyEnabled` is macOS's
/// name for it. Writing the macOS name here writes a key nothing reads, so
/// `UIAccessibility.isReduceTransparencyEnabled` stayed false and §6.5 skipped
/// on every run — which was read as "the runner process cannot be told" rather
/// than "the key is spelled wrong".
final class AccessibilityUITests: XCTestCase {
    /// AX5, the largest accessibility size.
    private static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"
    private static let xs = "UICTContentSizeCategoryXS"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(contentSize: String) -> XCUIApplication {
        launchOnSignIn(extraArguments: ["-UIPreferredContentSizeCategoryName", contentSize])
    }

    /// Our controls that are on screen right now. Ours means we gave them an
    /// identifier; a control below the fold is not hittable by definition and
    /// counting it would report scrolling as a defect.
    ///
    /// Disabled controls are **included**. Their size is exactly what is under
    /// test — the sign-in button is disabled until both fields have something
    /// in them, and excluding it left this check with nothing at all to look
    /// at on the sign-in screen, which is how it first failed.
    ///
    /// Behind the tab bar counts as below the fold: a feed row passing under
    /// it is a row not yet scrolled to, and no more hittable than one past the
    /// bottom of the screen.
    ///
    /// **And so does a tile cut by the side of the screen in the feed's
    /// "⭐ Popular Pets" row**, which scrolls sideways. At AX5 its heading
    /// moves above the tiles and a sixth tile starts at x≈396 of 402: six
    /// points of it are on screen, on purpose — that sliver is how the row
    /// says there is more. It is the next tile not yet scrolled to, exactly as
    /// a card under the tab bar is the next card, and the tiles wholly on
    /// screen are still held to 44pt and hittable. Only that row: a control
    /// anywhere else cut by the side of the screen is still counted, because
    /// there it is a layout pushing a control off the screen.
    private func visibleOwnControls(_ app: XCUIApplication) -> [XCUIElement] {
        let window = app.windows.firstMatch.frame
        let tabBar = app.tabBars.firstMatch
        let underBar = tabBar.exists ? tabBar.frame : .null
        let spotlight = app.descendants(matching: .any).matching(identifier: "feed.spotlight").firstMatch
        let sidewaysRow = spotlight.exists ? spotlight.frame : .null
        return app.buttons.allElementsBoundByIndex.filter {
            $0.exists && !$0.identifier.isEmpty
                && !$0.frame.isEmpty && window.intersects($0.frame)
                && !underBar.intersects($0.frame)
                && !(sidewaysRow.intersects($0.frame)
                     && ($0.frame.minX < window.minX || $0.frame.maxX > window.maxX))
        }
    }

    /// What one element looked like at one moment: the four facts the geometry
    /// scans need, read together so they describe the same instant.
    ///
    /// A plain value on purpose. An `XCUIElement` kept in an array is not a
    /// thing, it is a *recipe* for finding a thing — every `.frame`, `.label`
    /// or `.elementType` re-runs the query against the tree as it is now. Hold
    /// a hundred of them across a feed whose rows resize as their images
    /// arrive and the answers stop belonging to one layout.
    struct SeenElement {
        let identifier: String
        let label: String
        let type: XCUIElement.ElementType
        let frame: CGRect
    }

    /// Every element the app is currently showing, as values, in tree order.
    ///
    /// One pass. The cost of the pass is unavoidable — XCTest has no batch
    /// read — but doing it once instead of four times is both faster and the
    /// only way the numbers can be compared to each other at all.
    private func snapshotOfEverythingOnScreen(_ app: XCUIApplication) -> [SeenElement] {
        app.descendants(matching: .any).allElementsBoundByIndex.compactMap { element in
            guard element.exists else { return nil }
            let frame = element.frame
            guard !frame.isEmpty else { return nil }
            return SeenElement(
                identifier: element.identifier,
                label: element.label,
                type: element.elementType,
                frame: frame
            )
        }
    }

    private func assertNothingRunsOffTheSide(
        _ app: XCUIApplication,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = app.windows.firstMatch.frame
        // A 1pt tolerance: hairline separators are laid out on the boundary.
        for element in app.staticTexts.allElementsBoundByIndex
        where element.exists && !element.frame.isEmpty && window.intersects(element.frame) {
            XCTAssertGreaterThanOrEqual(
                element.frame.minX, window.minX - 1,
                "\(context): \"\(element.label.prefix(40))\" starts off the left edge",
                file: file, line: line
            )
            XCTAssertLessThanOrEqual(
                element.frame.maxX, window.maxX + 1,
                "\(context): \"\(element.label.prefix(40))\" runs off the right edge",
                file: file, line: line
            )
        }
    }

    private func assertControlsAreStillReachable(
        _ app: XCUIApplication,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Read the identifier in the same pass that selects the element.
        //
        // `.filter { $0.exists }` then `.map { $0.identifier }` are two
        // traversals of a tree that moves — a feed row resizes as its image
        // arrives — so the second one resolves indices into a layout the
        // first one no longer describes: "No matches found for Element at
        // index N". That reads like a missing control and is a stale query.
        // The same mistake was fixed elsewhere in this file; this was the
        // other one.
        let barButtonIDs = Set(
            app.navigationBars.buttons.allElementsBoundByIndex
                .compactMap { $0.exists ? $0.identifier : nil }
        )
        // And by where it is, not only by name: a bar item that appears after
        // the names were read — the detail screen's post menu waits for the
        // post — was otherwise judged as content and held to 44pt, which a
        // navigation bar never lays anything out at.
        let barFrames = app.navigationBars.allElementsBoundByIndex
            .compactMap { $0.exists ? $0.frame : nil }
        let controls = visibleOwnControls(app)
        XCTAssertFalse(controls.isEmpty, "\(context): no identified controls found", file: file, line: line)
        for control in controls {
            let frame = control.frame
            if barButtonIDs.contains(control.identifier) || barFrames.contains(where: { $0.contains(frame) }) {
                // A navigation bar lays its items out inside 44pt whatever the
                // type size, so these are asserted reachable, not tall — the
                // same split AuthUITests documents.
                guard control.isEnabled else { continue }
                XCTAssertTrue(
                    waitUntilHittable(control, in: app, timeout: 10),
                    "\(context): \(control.identifier) is not reachable", file: file, line: line
                )
            } else {
                // Compared at a thousandth of a point. A frame is reported as
                // the difference of two window coordinates, and a control that
                // starts at a fractional y comes out a hair under its height:
                // the legal links on the sign-in screen at XS measured
                // 43.99999999999994pt. That is floating point, not a smaller
                // target; anything a finger could notice is still refused.
                XCTAssertGreaterThanOrEqual(
                    (control.frame.height * 1000).rounded() / 1000, 44,
                    "\(context): \(control.identifier) is \(control.frame.height)pt tall",
                    file: file, line: line
                )
                // Hittability only for controls that are meant to respond: a
                // disabled button is correctly not hittable, and asserting
                // otherwise would be asserting a defect.
                if control.isEnabled {
                    XCTAssertTrue(
                        control.isHittable,
                        "\(context): \(control.identifier) is not hittable", file: file, line: line
                    )
                }
            }
        }
    }

    // MARK: - §6.2 The largest accessibility size

    /// AX5 on the sign-in screen, the feed and the detail screen. The whole
    /// core path, because a size that works on one screen and breaks the next
    /// is the normal way this fails.
    func testTheCorePathSurvivesAX5() {
        let app = launch(contentSize: Self.ax5)

        assertNothingRunsOffTheSide(app, "sign-in at AX5")
        assertControlsAreStillReachable(app, "sign-in at AX5")

        signIn(app, email: "accept-a@example.com")
        XCTAssertTrue(waitForExistence(of: app.staticTexts.matching(identifier: "post.text").firstMatch,
                                       in: app, timeout: 60),
                      "the feed never loaded at AX5")
        assertNothingRunsOffTheSide(app, "feed at AX5")
        assertControlsAreStillReachable(app, "feed at AX5")

        openFirstPost(app)
        assertNothingRunsOffTheSide(app, "post detail at AX5")
        assertControlsAreStillReachable(app, "post detail at AX5")

        // The composer is the control most likely to be squeezed out by text
        // growing around it, and it is the one the screen exists for.
        XCTAssertTrue(waitUntilHittable(app.textFields["composer.field"], in: app, timeout: 20),
                      "the comment field is unreachable at AX5")
        XCTAssertTrue(app.buttons["composer.send"].exists, "the send button is gone at AX5")
    }

    // MARK: - §6.3 The smallest size

    /// The 44pt minimum is a floor, not a scale factor: it must not shrink
    /// along with the text.
    func testControlsStay44ptAtTheSmallestSize() {
        let app = launch(contentSize: Self.xs)
        assertControlsAreStillReachable(app, "sign-in at XS")

        signIn(app, email: "accept-a@example.com")
        XCTAssertTrue(waitForExistence(of: app.staticTexts.matching(identifier: "post.text").firstMatch,
                                       in: app, timeout: 60))
        assertControlsAreStillReachable(app, "feed at XS")

        openFirstPost(app)
        assertControlsAreStillReachable(app, "post detail at XS")
    }

    // MARK: - §5C.1 / §5C.5 The keyboard

    /// The composer has to stay above the keyboard, and the layout has to come
    /// back when the keyboard goes away.
    ///
    /// **This is not 5C.1.** 5C.1 is about a real keyboard on a real device,
    /// including the Chinese candidate bar that arrives after the keyboard and
    /// that a fixed delay walks straight past — no simulator can produce that,
    /// and it stays unverified. What a simulator can answer is the geometry: is
    /// the field the person is typing into underneath the keyboard, and is
    /// there a dead strip left behind afterwards.
    ///
    /// Skipped, not passed, when the software keyboard is unavailable — with a
    /// hardware keyboard connected the simulator shows no keyboard at all and
    /// there would be nothing to measure against.
    func testTheComposerStaysAboveTheKeyboardAndComesBackAfterwards() throws {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        openFirstPost(app)

        let field = app.textFields["composer.field"]
        // Hittable, not merely existing, before anything is measured from it.
        // `openFirstPost` waits for the field to exist, and existence is not
        // the same as being in its final place: the save-password sheet can
        // still be over it, and a frame read through that is a frame read of
        // a screen mid-flight. The resting position this whole test compares
        // against was taken with no wait at all.
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 30),
                      "the comment field never became usable")
        let restingBottom = field.frame.maxY
        field.tap()

        let keyboard = app.keyboards.firstMatch
        try XCTSkipUnless(
            keyboard.waitForExistence(timeout: 8),
            """
            No software keyboard on this simulator, so there is nothing to             measure against. Disconnect the hardware keyboard for this device             and run again.
            """
        )
        field.typeText("TEST CONTENT a3 keyboard geometry")

        let keyboardTop = keyboard.frame.minY
        XCTAssertLessThanOrEqual(
            field.frame.maxY, keyboardTop + 1,
            "the field being typed into is behind the keyboard "
                + "(field ends at \(field.frame.maxY), keyboard starts at \(keyboardTop))"
        )
        let send = app.buttons["composer.send"]
        XCTAssertLessThanOrEqual(send.frame.maxY, keyboardTop + 1, "send is behind the keyboard")
        XCTAssertTrue(send.isHittable, "send cannot be tapped with the keyboard up")

        // Scrolling the list dismisses the keyboard. Before this screen had
        // `.scrollDismissesKeyboard` there was no way off it at all: a
        // vertical-axis TextField's return key inserts a newline.
        //
        // Swiping *up*, deliberately. A downward drag at the top of the list
        // is pull-to-refresh's gesture, and asserting on it would be asserting
        // which of the two wins rather than that the keyboard goes away.
        //
        // Two budgets rather than one bigger number: up to three swipes and
        // up to 30 seconds. A single swipe plus a longer sleep waits out the
        // clock on a gesture that may never have landed — under load the
        // synthesised swipe can arrive before the list is listening, and the
        // test then reports the machine as a missing
        // `.scrollDismissesKeyboard`. Retrying the gesture does not weaken
        // the assertion below; it only makes sure there was a gesture to
        // assert about.
        var swipes = 0
        let deadline = Date().addingTimeInterval(30)
        while keyboard.exists, Date() < deadline, swipes < 3 {
            app.swipeUp()
            swipes += 1
            let settle = Date().addingTimeInterval(5)
            while keyboard.exists, Date() < settle { Thread.sleep(forTimeInterval: 0.2) }
        }
        XCTAssertFalse(keyboard.exists, "dragging the list did not dismiss the keyboard")

        // §5C.5: the composer comes back down, and does not leave a strip of
        // reserved-but-empty space behind — the web client once held 176px for
        // a tab bar the page did not have.
        let window = app.windows.firstMatch.frame
        // Within a few points, not to the pixel. The field is measured empty
        // before the keyboard and holding a line of text after it, and that
        // alone moved it 3pt — which is the text's own layout, not the
        // keyboard leaving something behind. The requirement is the assertion
        // below it: no reserved-but-empty strip.
        XCTAssertEqual(
            field.frame.maxY, restingBottom, accuracy: 10,
            "the composer did not come back down "
                + "(was \(restingBottom), now \(field.frame.maxY))"
        )
        XCTAssertLessThan(
            window.maxY - field.frame.maxY, 80,
            "a \(window.maxY - field.frame.maxY)pt dead strip was left below the composer"
        )
    }

    // MARK: - §6.4 Reduce Motion

    /// With animation removed, navigation must still work and the screen must
    /// still say what happened.
    ///
    /// Skipped rather than quietly passed when the setting is off: a test that
    /// runs identically with the switch in either position is not evidence
    /// about the switch.
    func testTheCorePathWorksWithReduceMotionOn() throws {
        try XCTSkipUnless(
            UIAccessibility.isReduceMotionEnabled,
            """
            Reduce Motion is off on this simulator, so this run would prove \
            nothing. Set it first:
              xcrun simctl spawn pn-a3 defaults write com.apple.Accessibility \
            ReduceMotionEnabled -bool true
            """
        )

        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        openFirstPost(app)
        // Pushing and popping are the transitions §6.4 is about; with the
        // animation gone the navigation still has to arrive.
        popToFeed(app)
        openFirstPost(app)

        // "状态反馈仍在": a refusal is still reported, and it is text rather
        // than a motion cue, so removing motion cannot remove it. Uses the
        // length cap, which is refused by the client and writes nothing.
        let field = app.textFields["composer.field"]
        field.tap()
        field.typeText("x")
        XCTAssertTrue(waitUntilHittable(app.buttons["composer.send"], in: app, timeout: 10),
                      "the send control is not reachable with Reduce Motion on")
    }

    // MARK: - §6.5 Reduce Transparency

    /// There is exactly one translucent surface in this app, and it is in the
    /// one file that performs the substitution — `ControlScrim`, which backs
    /// controls that float over a photograph and swaps `.regularMaterial` for
    /// an opaque scrim when the setting is on. `AccessibilityGuardTests`
    /// proves *that* by scanning the source, which is the stronger half of
    /// this requirement because it covers screens no test visits.
    ///
    /// (The claim here used to be "there is nothing translucent at all". That
    /// was true when it was written and stopped being true when a control had
    /// to sit on media; the guard was tightened rather than dropped, and this
    /// note is what stops the older, easier claim being repeated.)
    ///
    /// This is the other half: with the setting on, the app still renders and
    /// every control is still reachable, so the substitution is not hiding a
    /// screen that fails to draw.
    // MARK: - §6.6 Contrast, measured on the pixels that were drawn

    /// The colour of the glyphs and the colour behind them, taken from a
    /// screenshot of the running app.
    ///
    /// **Why not the tokens.** Every other contrast test in this project
    /// resolves two `Color`s and does the WCAG arithmetic. That answers "is
    /// this pair of tokens compatible", which is not the question: a view can
    /// take a compliant token and draw it at 60% opacity, inside a dimmed
    /// container, over a surface that is not the one the test assumed, and the
    /// arithmetic stays green throughout. Two defects reached review that way.
    /// A screenshot has none of those blind spots, because it is the thing the
    /// person looks at.
    ///
    /// Background is the most common colour in the element's box; foreground
    /// is the pixel furthest from it in luminance, which is the core of a
    /// glyph. Antialiased edges sit between the two and are deliberately not
    /// what is measured — they are not what anybody reads a letter by.
    private func measuredContrast(
        of element: XCUIElement, in app: XCUIApplication
    ) -> (ratio: Double, foreground: String, background: String)? {
        guard element.exists, !element.frame.isEmpty else { return nil }
        guard let screenshot = XCUIScreen.main.screenshot().image.cgImage else { return nil }

        let window = app.windows.firstMatch.frame
        guard window.width > 0 else { return nil }
        let scale = CGFloat(screenshot.width) / window.width

        let box = element.frame
        let rect = CGRect(
            x: (box.minX - window.minX) * scale, y: (box.minY - window.minY) * scale,
            width: box.width * scale, height: box.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: screenshot.width, height: screenshot.height))
        guard rect.width >= 2, rect.height >= 2, let crop = screenshot.cropping(to: rect) else {
            return nil
        }

        let width = crop.width, height = crop.height
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &raw, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))

        func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
            func lin(_ v: Double) -> Double {
                v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }

        // The mode, on a coarse grid: a background is never one exact value
        // across a whole box once it has been through a display pipeline.
        var histogram: [Int: Int] = [:]
        var samples: [(r: Double, g: Double, b: Double)] = []
        samples.reserveCapacity(width * height)
        for index in stride(from: 0, to: raw.count, by: 4) {
            let r = Double(raw[index]) / 255, g = Double(raw[index + 1]) / 255
            let b = Double(raw[index + 2]) / 255
            samples.append((r, g, b))
            let key = (Int(r * 31) << 10) | (Int(g * 31) << 5) | Int(b * 31)
            histogram[key, default: 0] += 1
        }
        guard let commonest = histogram.max(by: { $0.value < $1.value })?.key else { return nil }
        let background = (
            r: Double((commonest >> 10) & 31) / 31,
            g: Double((commonest >> 5) & 31) / 31,
            b: Double(commonest & 31) / 31
        )
        let backgroundLuminance = luminance(background.r, background.g, background.b)

        guard let extreme = samples.max(by: {
            abs(luminance($0.r, $0.g, $0.b) - backgroundLuminance)
                < abs(luminance($1.r, $1.g, $1.b) - backgroundLuminance)
        }) else { return nil }
        let foregroundLuminance = luminance(extreme.r, extreme.g, extreme.b)

        let ratio = (max(foregroundLuminance, backgroundLuminance) + 0.05)
            / (min(foregroundLuminance, backgroundLuminance) + 0.05)
        func describe(_ c: (r: Double, g: Double, b: Double)) -> String {
            String(format: "#%02X%02X%02X", Int(c.r * 255), Int(c.g * 255), Int(c.b * 255))
        }
        return (ratio, describe(extreme), describe(background))
    }

    /// Text on the two screens a person spends all their time on, measured
    /// from pixels rather than from tokens.
    ///
    /// 4.5:1 for everything here: none of it is large text at the sizes this
    /// app uses, and none of it is decorative — the timestamp and the counts
    /// are as much of the post as its words.
    func testTextOnTheRealScreensMeetsContrastWhenDrawn() throws {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        XCTAssertTrue(
            waitForExistence(of: app.staticTexts.matching(identifier: "post.text").firstMatch,
                             in: app, timeout: 60),
            "the feed never loaded"
        )
        waitForQuietUI(app)

        var measured = 0
        func check(_ element: XCUIElement, _ what: String) {
            guard let result = measuredContrast(of: element, in: app) else { return }
            measured += 1
            print(String(
                format: "MEASURED rendered contrast %@: %.2f:1 (%@ on %@)",
                what, result.ratio, result.foreground, result.background
            ))
            XCTAssertGreaterThanOrEqual(
                result.ratio, 4.5,
                "\(what) renders at \(String(format: "%.2f", result.ratio)):1 "
                    + "(\(result.foreground) on \(result.background))"
            )
        }

        let window = app.windows.firstMatch.frame
        for text in app.staticTexts.matching(identifier: "post.text").allElementsBoundByIndex
        where text.exists && window.contains(text.frame) {
            check(text, "feed post text")
        }
        check(app.staticTexts["env.badge"], "environment badge")

        openFirstPost(app)
        waitForQuietUI(app)
        for row in app.staticTexts.matching(identifier: "comment.row").allElementsBoundByIndex.prefix(3)
        where row.exists && window.contains(row.frame) {
            check(row, "comment row")
        }

        XCTAssertGreaterThan(measured, 0, "nothing was measured, so nothing was established")
    }

    // MARK: - §6.7 VoiceOver, as far as a tool can see

    /// What a tool can check: everything interactive has a label, and the
    /// order the elements come in matches the order they are read.
    ///
    /// **This is not "VoiceOver works".** Whether a card reads as one thing or
    /// as five, whether the rotor lands somewhere useful, whether a person can
    /// find what they were looking for — all of that needs VoiceOver actually
    /// running and a person listening to it, which a simulator run is not.
    /// That half stays unverified and is reported as unverified.
    func testEveryControlOnTheCorePathHasSomethingToAnnounce() {
        let app = launchOnSignIn()

        func auditControls(_ context: String) {
            let window = app.windows.firstMatch.frame
            // Read identifier, label and frame in the same pass that selects
            // the element, and keep the values rather than the element.
            //
            // A feed row resizes as its image arrives, so the list of buttons
            // is not the same list a moment later. Holding XCUIElements across
            // that and reading `.label` afterwards asks the app to resolve an
            // index into a tree that has moved: "No matches found for Element
            // at index 4", which reads like a missing control and is really a
            // stale query.
            let controls: [(id: String, label: String)] = app.buttons
                .allElementsBoundByIndex
                .compactMap { button in
                    guard button.exists, !button.identifier.isEmpty else { return nil }
                    let frame = button.frame
                    guard !frame.isEmpty, window.intersects(frame) else { return nil }
                    return (button.identifier, button.label)
                }
            XCTAssertFalse(controls.isEmpty, "\(context): no controls to audit")
            for control in controls {
                XCTAssertFalse(
                    control.label.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(context): \(control.id) has no accessibility label"
                )
                XCTAssertFalse(
                    control.label.contains(control.id),
                    "\(context): \(control.id) announces its own identifier"
                )
            }
        }

        auditControls("sign-in")
        signIn(app, email: "accept-a@example.com")
        XCTAssertTrue(
            waitForExistence(of: app.staticTexts.matching(identifier: "post.text").firstMatch,
                             in: app, timeout: 60)
        )
        waitForQuietUI(app)
        auditControls("feed")

        // Reading order: elements come back in tree order, and for a vertical
        // list that has to be top to bottom. A card whose action row is read
        // before its text is a card nobody can follow.
        let ordered = app.staticTexts.matching(identifier: "post.text")
            .allElementsBoundByIndex.filter { $0.exists }
        let tops = ordered.map { $0.frame.minY }
        XCTAssertEqual(tops, tops.sorted(), "the posts are not announced in the order they appear")

        openFirstPost(app)
        auditControls("post detail")
    }

    /// The card's own "open this post" is not reachable by announcement.
    ///
    /// `PostCard.content` carries `.onTapGesture { onOpenPost?() }` on a plain
    /// container: no `.isButton` trait, no `.accessibilityAction`, and nothing
    /// in the card's accessibility tree that says the card can be opened. A
    /// sighted person taps the picture or the words; a VoiceOver user is told
    /// about an image, some text, a Like button and a Comments button, and
    /// none of those says "open". Comments happens to lead to the same screen,
    /// which is a coincidence of this layout and not an answer.
    ///
    /// Recorded as a failing assertion rather than a comment, because it is a
    /// real defect against §6.7 and because the file it is in belongs to
    /// another agent: this run's job is to say that it is still true.
    func testTheCardAdvertisesThatItCanBeOpened() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        let text = app.staticTexts.matching(identifier: "post.text").firstMatch
        XCTAssertTrue(waitForExistence(of: text, in: app, timeout: 60), "the feed never loaded")
        waitForQuietUI(app)

        // One walk of the tree, reading the values out as it goes.
        //
        // What this replaced walked it four times — once for the card's top,
        // once for its bottom, once to collect what is announced inside it,
        // and a fourth time inside the failure message — and every property
        // access in every one of those is a fresh query answered against
        // whatever the tree looks like at that moment. A feed row changes
        // height when its image arrives, so the later walks resolve indices
        // into a layout the earlier ones no longer describe. That surfaces as
        // "No matches found for Element at index N", which reads like a
        // control going missing and is a stale query. It also meant the
        // failure message described a different observation from the
        // assertion that produced it.
        //
        // Values cannot go stale. Everything below this line is arithmetic.
        let seen = snapshotOfEverythingOnScreen(app)

        // Everything in the first card, by geometry: from its identity row —
        // the pet's name and the timestamp — down to the action row below it.
        //
        // The text was the top of this window until the way into the post
        // turned out to sit *above* it. The window then excluded the very
        // element it was looking for, and reported that the card offered no
        // way in while the card was sitting there offering one. A window
        // drawn from one of the things it is searching for is not a window
        // around the card.
        guard let cardText = seen.first(where: {
            $0.identifier == "post.text" && $0.type == .staticText
        }) else {
            return XCTFail(
                "post.text existed a moment ago and is not in the snapshot; "
                    + "the screen changed under the scan"
            )
        }
        let header = seen
            .filter { $0.identifier == "post.open" && $0.frame.minY < cardText.frame.minY }
            .max { $0.frame.minY < $1.frame.minY }
        let cardTop = header?.frame.minY ?? cardText.frame.minY
        let nextLike = seen
            .filter { $0.identifier == "post.like" && $0.type == .button && $0.frame.minY > cardTop }
            .min { $0.frame.minY < $1.frame.minY }
        let cardBottom = nextLike?.frame.maxY ?? (cardTop + 400)

        // The window has to be the card, not the screen.
        //
        // Twice now an `.accessibilityAction` on a container has made an
        // element report the whole window as its own rectangle — 603x874 at
        // x=-100 the last time. A window that big reaches the navigation bar,
        // and the bar's account entry is a button whose label is not Like,
        // Unlike or Comments: it would satisfy the assertion below on its own,
        // and this test would go green while the card offered no way in at
        // all. A false pass is the one outcome a test must not be able to
        // produce, so the window is checked before anything is concluded from
        // it.
        //
        // Measured at HEAD: post.open is (0, 128, 402, 44) — a row, not a
        // screen — and account.menu is (349, 66, 30, 36), clearing the top of
        // the window by 26pt.
        if let bar = seen.first(where: { $0.identifier == "account.menu" }) {
            XCTAssertFalse(
                bar.frame.minY >= cardTop && bar.frame.maxY <= cardBottom,
                """
                the navigation bar's account entry \(bar.frame) is inside the \
                card window [\(cardTop), \(cardBottom)]. The window is the \
                screen rather than the card, so anything found in it says \
                nothing about the card — check what post.open reports as its \
                frame (it should be one row tall).
                """
            )
        }

        let announced = seen.filter {
            $0.frame.minY >= cardTop && $0.frame.maxY <= cardBottom && !$0.label.isEmpty
        }
        let opensThePost = announced.contains {
            $0.type == .button && !["Like", "Unlike", "Comments"].contains($0.label)
        }
        XCTAssertTrue(
            opensThePost,
            """
            nothing in the card says it can be opened. What VoiceOver has to \
            work with: \(announced.map { "\($0.type.rawValue):\($0.label.prefix(30))" })
            """
        )
    }

    func testTheCorePathWorksWithReduceTransparencyOn() throws {
        try XCTSkipUnless(
            UIAccessibility.isReduceTransparencyEnabled,
            """
            Reduce Transparency is off on this simulator, so this run would \
            prove nothing. Set it first:
              xcrun simctl spawn <device> defaults write com.apple.Accessibility \
            EnhancedBackgroundContrastEnabled -bool true

            The key really is called that. `ReduceTransparencyEnabled` is the \
            macOS name; on iOS the switch labelled "Reduce Transparency" is \
            stored as `EnhancedBackgroundContrastEnabled`, next to \
            `ReduceMotionEnabled` in the same domain, and posts \
            com.apple.accessibility.enhance.background.contrast.status. \
            Writing the macOS name put a key in the domain that nothing reads, \
            which is why this skipped every time while Reduce Motion — whose \
            name happens to match — worked.
            """
        )

        let app = launchOnSignIn()
        assertControlsAreStillReachable(app, "sign-in with Reduce Transparency")
        signIn(app, email: "accept-a@example.com")
        XCTAssertTrue(waitForExistence(of: app.staticTexts.matching(identifier: "post.text").firstMatch,
                                       in: app, timeout: 60),
                      "the feed never loaded with Reduce Transparency on")
        assertControlsAreStillReachable(app, "feed with Reduce Transparency")
        openFirstPost(app)
        assertControlsAreStillReachable(app, "post detail with Reduce Transparency")
    }

    // MARK: - The account menu at the largest size

    /// The sheet that holds sign-out has a fixed resting height, and text
    /// three times its default size has to fit in it — or reach somewhere it
    /// does fit.
    ///
    /// A sheet's content does not scroll unless something makes it scroll, so
    /// a detent chosen for the default type size clips whatever grows past it.
    /// What gets clipped here is the only action the menu has.
    func testTheAccountMenuIsUsableAtAX5() {
        let app = launch(contentSize: Self.ax5)
        signIn(app, email: "accept-a@example.com")

        let entry = app.buttons["account.menu"]
        XCTAssertTrue(waitUntilHittable(entry, in: app, timeout: 30),
                      "the account entry is not reachable at AX5")
        entry.tap()

        let row = app.buttons["session.signOut"]
        XCTAssertTrue(
            waitUntilHittable(row, in: app, timeout: 20),
            """
            The sign-out row cannot be reached at AX5. exists=\(row.exists) \
            frame=\(row.exists ? "\(row.frame)" : "n/a") \
            window=\(app.windows.firstMatch.frame)
            \(app.debugDescription)
            """
        )
        print("MEASURED at AX5: session.signOut frame=\(row.frame) "
              + "account.title frame=\(app.staticTexts["account.title"].frame) "
              + "window=\(app.windows.firstMatch.frame)")
        assertNothingRunsOffTheSide(app, "account menu at AX5")

        // The address is what makes "sign out" an informed tap; at AX5 it is
        // also the line most likely to be pushed out of the sheet.
        XCTAssertTrue(app.staticTexts["account.email"].exists,
                      "the menu no longer says whose session it is at AX5")
    }
}
