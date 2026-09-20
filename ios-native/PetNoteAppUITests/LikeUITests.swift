import XCTest

/// Does tapping the heart actually like the post — everywhere at once.
///
/// Three things have to agree and each of them has, at some point in this
/// prototype's history, been right while another was wrong:
///
///   1. **the button**, whose accessibility label is `Like` or `Unlike`;
///   2. **the number on screen**, which is the button's accessibility value and
///      is *derived* — the server's count plus whatever this client has done
///      that the aggregate has not caught up with;
///   3. **the emulator**, where the like is a document under
///      `posts/{id}/likes/{uid}` and the count is a separate integer moved
///      afterwards by a Cloud Functions trigger.
///
/// Checking only the first two is how a heart that turned red with no write
/// behind it passed for working. So this reads the backend from inside the
/// test, over the emulator's REST API, in the same run and about the same post.
///
/// **A like document is evidence of a like regardless of `counted`.**
/// `onLikeCreated` flips that field to `true` in the same transaction that
/// moves `likeCount`, so "no document with `counted: false`" means the trigger
/// has already run at least as often as not — it is not evidence that no like
/// was ever written. Existence is the question; `counted` is never asked.
final class LikeUITests: XCTestCase {
    private static let project = "petnote-test"
    private static let firestore =
        "http://127.0.0.1:8088/v1/projects/petnote-test/databases/(default)/documents"
    private static let identityToolkit =
        "http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/projects/petnote-test"

    private let account = "accept-a@example.com"
    private let password = "Passw0rd!x"

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Reading the emulator

    /// One request, answered or not. Returns nil for any non-200, which is how
    /// "the document is not there" arrives.
    private func json(
        _ urlString: String,
        method: String = "GET",
        body: String? = nil
    ) -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // The emulator accepts `owner` as a privileged bearer token, which is
        // what makes it possible to read another account's documents here.
        // Nothing outside the emulator will answer to it.
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")

        var parsed: [String: Any]?
        var status = 0
        var transportError: Error?
        let answered = expectation(description: "\(method) \(urlString)")
        URLSession.shared.dataTask(with: request) { data, response, error in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            transportError = error
            if let data {
                parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            answered.fulfill()
        }.resume()
        wait(for: [answered], timeout: 20)

        if let transportError {
            XCTFail("""
                could not reach the emulator at \(urlString): \
                \(transportError.localizedDescription). Every backend assertion below \
                would otherwise pass by not being made.
                """)
            return nil
        }
        return status == 200 ? parsed : nil
    }

    /// The uid behind an email, asked of the auth emulator rather than hardcoded
    /// — a reseed changes every uid and nothing would say so.
    private func uid(forEmail email: String) -> String? {
        guard let response = json(
            "\(Self.identityToolkit)/accounts:query", method: "POST", body: "{}"
        ) else { return nil }
        let users = response["userInfo"] as? [[String: Any]] ?? []
        return users.first { ($0["email"] as? String) == email }?["localId"] as? String
    }

    /// The aggregate the trigger maintains. Absent means the field is not there,
    /// which for a seeded post would itself be a finding.
    private func backendLikeCount(of postID: String) -> Int? {
        guard let document = json("\(Self.firestore)/posts/\(postID)"),
              let fields = document["fields"] as? [String: Any],
              let count = fields["likeCount"] as? [String: Any],
              let value = count["integerValue"] as? String else { return nil }
        return Int(value)
    }

    /// Whether the like document exists. `counted` is deliberately not read:
    /// see this class's documentation.
    private func backendLikeExists(postID: String, uid: String) -> Bool {
        json("\(Self.firestore)/posts/\(postID)/likes/\(uid)") != nil
    }

    /// Polls the backend, because `likeCount` is moved by a trigger *after* the
    /// write returns. Returns whether it got there, so the caller can say what
    /// it actually saw.
    @discardableResult
    private func backendSettles(
        within seconds: TimeInterval = 20,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }

    // MARK: - Reading the screen

    private func signedIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-petnote-start-signed-out"]
        app.launch()
        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 15))
        let email = app.textFields["login.email"]
        email.tap(); email.typeText(account)
        let password = app.secureTextFields["login.password"]
        password.tap(); password.typeText(self.password)
        app.buttons["login.submit"].tap()
        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 40))
        waitForQuietUI(app)
        return app
    }

    private func likeButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "post.like").firstMatch
    }

    /// The number the button is announcing, out of "N likes".
    private func shownCount(_ app: XCUIApplication) -> Int? {
        guard let value = likeButton(app).value as? String,
              let digits = value.split(separator: " ").first else { return nil }
        return Int(digits)
    }

    /// Which post the first row is. The seed writes the index into every post's
    /// text so the run can name the document it touched.
    ///
    /// The prefix comes from the seed manifest rather than being spelled out
    /// here. Each seed run writes into its own namespace — that is what stops
    /// a previous run's deletions from corrupting this one's counts — so a
    /// literal `ios-post-%03d` would now name a document from no run at all,
    /// or worse, from an abandoned one.
    private func firstPostID(_ app: XCUIApplication) -> String? {
        let text = app.staticTexts.matching(identifier: "post.text").firstMatch
        guard text.waitForExistence(timeout: 20) else { return nil }
        guard let range = text.label.range(of: #"\[#(\d+)\]"#, options: .regularExpression),
              let index = Int(text.label[range].dropFirst(2).dropLast()) else { return nil }
        guard let manifest = try? EmulatorAdmin.seedManifest() else {
            XCTFail("No seed manifest; run functions/scripts/seed-ios-native.mjs")
            return nil
        }
        return manifest.post(index: index)
    }

    /// Taps the heart, after waiting for it to be tappable *again*.
    ///
    /// Not paranoia: the feed's rows resize as their images arrive, and a
    /// button that was hittable when the test looked is not necessarily
    /// hittable a second later. XCUITest reported `Computed hit point {-1, -1}`
    /// and carried on, so the tap silently did nothing and the failure landed
    /// on the assertion after it, describing the wrong thing.
    private func tapLike(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            waitUntilHittable(likeButton(app), in: app, timeout: 30),
            "the like button is not tappable", file: file, line: line
        )
        likeButton(app).tap()
    }

    /// Pull to refresh, then confirm the first row is still the post this test
    /// is talking about. The emulator is shared, and a post written by another
    /// run would quietly become row one and move every assertion onto it.
    private func refresh(
        _ app: XCUIApplication, stillShowing postID: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        app.swipeDown()
        waitForQuietUI(app, quietFor: 1, timeout: 10)
        XCTAssertEqual(
            firstPostID(app), postID,
            "the first row is a different post now; this run cannot be reconciled",
            file: file, line: line
        )
    }

    private func waitForLabel(
        _ expected: String, on app: XCUIApplication, timeout: TimeInterval = 15
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if likeButton(app).label == expected { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return likeButton(app).label == expected
    }

    // MARK: - The test

    /// Like, then unlike, checking all three at every step and putting the post
    /// back where it was found.
    func testTheButtonTheNumberAndTheEmulatorAgreeThroughALikeAndAnUnlike() throws {
        let uid = try XCTUnwrap(
            uid(forEmail: account), "no uid for \(account); is the auth emulator seeded?"
        )
        let app = signedIn()
        let like = likeButton(app)
        XCTAssertTrue(waitUntilHittable(like, in: app, timeout: 30), "no like button")
        let postID = try XCTUnwrap(firstPostID(app), "could not tell which post the first row is")
        print("MEASURED target=\(postID) uid=\(uid)")

        // --- at rest: the three have to already agree -----------------------
        let startLabel = like.label
        let startShown = try XCTUnwrap(shownCount(app), "the button announced no number")
        let startBackendCount = try XCTUnwrap(
            backendLikeCount(of: postID), "\(postID) has no likeCount field"
        )
        let startBackendLiked = backendLikeExists(postID: postID, uid: uid)
        print("""
            MEASURED start: label=\(startLabel) shown=\(startShown) \
            backendCount=\(startBackendCount) backendLiked=\(startBackendLiked)
            """)

        XCTAssertEqual(
            startShown, startBackendCount,
            "the number on screen and the aggregate disagree before anything was tapped"
        )
        XCTAssertEqual(
            startLabel, startBackendLiked ? "Unlike" : "Like",
            "the heart and the like document disagree before anything was tapped"
        )

        // --- like ------------------------------------------------------------
        let wantLiked = !startBackendLiked
        let afterFirst = startBackendCount + (wantLiked ? 1 : -1)
        tapLike(app)

        XCTAssertTrue(
            waitForLabel(wantLiked ? "Unlike" : "Like", on: app),
            "the button did not change state; it still says \(likeButton(app).label)"
        )
        XCTAssertFalse(
            app.staticTexts["feed.likeError"].exists,
            "a like failure was reported: \(app.staticTexts["feed.likeError"].label)"
        )
        XCTAssertEqual(
            shownCount(app), afterFirst,
            "the number on screen did not follow the tap"
        )

        XCTAssertTrue(
            backendSettles { self.backendLikeExists(postID: postID, uid: uid) == wantLiked },
            """
            the like document under posts/\(postID)/likes/\(uid) is \
            \(backendLikeExists(postID: postID, uid: uid) ? "present" : "absent") — the tap \
            changed the screen and not the backend
            """
        )
        XCTAssertTrue(
            backendSettles { self.backendLikeCount(of: postID) == afterFirst },
            """
            the aggregate settled at \(backendLikeCount(of: postID).map(String.init) ?? "nothing") \
            and the screen says \(afterFirst)
            """
        )

        // The aggregate has now moved. The screen must not move again with it:
        // that would be this client's own change counted twice.
        XCTAssertEqual(
            shownCount(app), afterFirst,
            "the number moved a second time when the trigger ran — counted twice"
        )

        // --- and back --------------------------------------------------------
        tapLike(app)

        XCTAssertTrue(
            waitForLabel(startLabel, on: app),
            "the button did not come back to \(startLabel)"
        )
        XCTAssertEqual(
            shownCount(app), startShown,
            "the number did not come back: \(startShown) → \(shownCount(app).map(String.init) ?? "nothing")"
        )
        XCTAssertTrue(
            backendSettles { self.backendLikeExists(postID: postID, uid: uid) == startBackendLiked },
            "the like document did not come back to where it started"
        )
        XCTAssertTrue(
            backendSettles { self.backendLikeCount(of: postID) == startBackendCount },
            """
            the aggregate did not come back: started at \(startBackendCount), \
            now \(backendLikeCount(of: postID).map(String.init) ?? "nothing")
            """
        )
        XCTAssertFalse(
            app.staticTexts["feed.likeError"].exists,
            "a like failure was reported: \(app.staticTexts["feed.likeError"].label)"
        )
    }

    /// A refresh taken while the trigger has not caught up must not lose the
    /// like or count it twice — the case the whole `unreflectedDelta` mechanism
    /// exists for, driven through the real UI rather than a fake.
    ///
    /// The refresh is fired immediately after the tap, which is when the like
    /// document exists and the aggregate usually does not yet. It is not
    /// guaranteed to land in that window — the emulator's trigger is quick —
    /// so what this asserts is the invariant that has to hold either way: after
    /// everything settles, the screen, the button and the backend agree.
    func testARefreshRightAfterALikeNeitherLosesItNorCountsItTwice() throws {
        let uid = try XCTUnwrap(uid(forEmail: account))
        let app = signedIn()
        let like = likeButton(app)
        XCTAssertTrue(waitUntilHittable(like, in: app, timeout: 30), "no like button")
        let postID = try XCTUnwrap(firstPostID(app))

        let startLabel = like.label
        let startBackendLiked = backendLikeExists(postID: postID, uid: uid)
        let startBackendCount = try XCTUnwrap(backendLikeCount(of: postID))
        let wantLiked = !startBackendLiked
        let afterTap = startBackendCount + (wantLiked ? 1 : -1)
        print("MEASURED target=\(postID) start=\(startBackendCount) liked=\(startBackendLiked)")

        tapLike(app)
        XCTAssertTrue(
            waitForLabel(wantLiked ? "Unlike" : "Like", on: app),
            "the button did not change state; it still says \(likeButton(app).label)"
        )

        // Pull to refresh, hard on the heels of the tap.
        refresh(app, stillShowing: postID)

        XCTAssertTrue(
            backendSettles { self.backendLikeCount(of: postID) == afterTap },
            """
            the aggregate settled at \(backendLikeCount(of: postID).map(String.init) ?? "nothing"), \
            expected \(afterTap)
            """
        )
        // One more refresh, now that the backend has finished moving, so the
        // screen is reading a settled world.
        refresh(app, stillShowing: postID)

        XCTAssertEqual(
            likeButton(app).label, wantLiked ? "Unlike" : "Like",
            "the refresh lost the like"
        )
        XCTAssertEqual(
            shownCount(app), afterTap,
            "the screen and the settled aggregate disagree after a refresh"
        )

        // Put it back.
        tapLike(app)
        XCTAssertTrue(waitForLabel(startLabel, on: app))
        XCTAssertTrue(
            backendSettles { self.backendLikeCount(of: postID) == startBackendCount },
            "left the post at \(backendLikeCount(of: postID).map(String.init) ?? "nothing"), not \(startBackendCount)"
        )
    }
}
