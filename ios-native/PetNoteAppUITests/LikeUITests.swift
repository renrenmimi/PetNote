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
    private let other = "accept-b@example.com"
    private let password = "Passw0rd!x"

    /// Posts and likes this run added, removed again in tearDown.
    ///
    /// The seeded data is shared with the other agents' runs and is not ours
    /// to change. Adding is allowed; leaving things behind moves what the next
    /// run sees, and a post left at the top of the feed moves it for everyone
    /// at once.
    private var temporaryPosts: [String] = []
    private var temporaryLikes: [(post: String, uid: String)] = []

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        for like in temporaryLikes {
            _ = json("\(Self.firestore)/posts/\(like.post)/likes/\(like.uid)", method: "DELETE")
        }
        for post in temporaryPosts {
            _ = json("\(Self.firestore)/posts/\(post)", method: "DELETE")
        }
        let leftBehind = temporaryPosts.filter { json("\(Self.firestore)/posts/\($0)") != nil }
        temporaryLikes = []
        temporaryPosts = []
        // Failing on purpose, as the comment tests do: a run that cannot clean
        // up after itself has changed the dataset every other run is reading.
        XCTAssertTrue(leftBehind.isEmpty, "posts left in the shared emulator: \(leftBehind)")
        super.tearDown()
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

    /// The aggregate the trigger maintains — or 0 when the field is not there.
    ///
    /// **Absent is normal and is not zero-by-accident.** No script writes these
    /// aggregates any more: `onLikeCreated` creates the field the first time
    /// somebody likes the post, so a post nobody has liked simply has no
    /// `likeCount`, exactly as the decoder assumes. Treating that as a missing
    /// value made every assertion below unrunnable against most of the seed —
    /// and treating it as a *failure* would report the seed as broken for
    /// being correct. `nil` now means only one thing: there is no such post.
    private func backendLikeCount(of postID: String) -> Int? {
        guard let document = json("\(Self.firestore)/posts/\(postID)"),
              let fields = document["fields"] as? [String: Any] else { return nil }
        guard let count = fields["likeCount"] as? [String: Any],
              let value = count["integerValue"] as? String else { return 0 }
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
    /// Polls until the backend agrees, or the deadline passes.
    ///
    /// The default is generous on purpose. The aggregate is maintained by a
    /// trigger running in the functions emulator, which competes for CPU with
    /// everything else on the machine; at a load average of 28 a wait that is
    /// comfortable when the machine is idle expires while the trigger is still
    /// queued. That produces "the aggregate is 1, expected 2" — a statement
    /// about the machine wearing the words of a product defect.
    ///
    /// Waiting longer costs nothing when the machine is quiet: this returns as
    /// soon as the condition holds.
    private func backendSettles(
        within seconds: TimeInterval = 60,
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

    private func signedIn(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-petnote-start-signed-out"] + extraArguments
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
        // A held pull, not a flick. This used to be a bare `swipeDown()`, and
        // a flick at the top of a List does not necessarily start
        // `.refreshable` at all — which would have left every assertion after
        // it describing a screen that had never been reloaded.
        pullToRefresh(app)
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

    // MARK: - Posts this run owns

    /// A post of our own, placed a few rows down the feed.
    ///
    /// Two tests below need a post they may delete and a post nobody else's
    /// assertions are about, and the seeded 210 are neither. `createdAt` is
    /// set between two seeded posts rather than to "now" for the sake of the
    /// other agents: the feed is ordered newest first, and a post written at
    /// "now" becomes row one for every run sharing this emulator — including
    /// the ones whose first assertion is which post row one is.
    private func createTemporaryPost(label: String) -> (id: String, text: String)? {
        guard let manifest = try? EmulatorAdmin.seedManifest() else {
            XCTFail("no seed manifest; cannot place a post relative to this run's data")
            return nil
        }
        guard let above = createdAt(ofPost: manifest.post(index: 2)),
              let below = createdAt(ofPost: manifest.post(index: 3)) else {
            XCTFail("could not read the seeded posts this one has to sit between")
            return nil
        }
        let between = Date(
            timeIntervalSince1970: (above.timeIntervalSince1970 + below.timeIntervalSince1970) / 2
        )

        let id = "a3-like-\(label)-\(UUID().uuidString.prefix(8))"
        let text = "TEST CONTENT a3 \(label) \(Int(Date().timeIntervalSince1970 * 1000))"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // The author is a real seeded account: `onPostWritten` maintains
        // aggregates from it, and pointing at a uid that does not exist would
        // be asking the trigger to do arithmetic on a missing document.
        let body = """
            {"fields":{\
            "authorId":{"stringValue":"\(uid(forEmail: account) ?? "")"},\
            "authorName":{"stringValue":"Accept A"},\
            "text":{"stringValue":"\(text)"},\
            "createdAt":{"timestampValue":"\(formatter.string(from: between))"}}}
            """
        guard json("\(Self.firestore)/posts?documentId=\(id)", method: "POST", body: body) != nil else {
            XCTFail("could not create the temporary post \(id)")
            return nil
        }
        temporaryPosts.append(id)
        return (id, text)
    }

    private func createdAt(ofPost id: String) -> Date? {
        guard let document = json("\(Self.firestore)/posts/\(id)"),
              let fields = document["fields"] as? [String: Any],
              let stamp = fields["createdAt"] as? [String: Any],
              let raw = stamp["timestampValue"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        }()
    }

    /// Writes a like as somebody else, the way another person's phone would.
    ///
    /// `counted: false`, because that is what the rules require of a client and
    /// what `onLikeCreated` flips when it moves the count. A like written with
    /// the field already true would be a like the trigger declines to count,
    /// which is not what another person's like looks like.
    private func likeAsAnotherAccount(postID: String, uid otherUID: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = """
            {"fields":{\
            "userId":{"stringValue":"\(otherUID)"},\
            "postId":{"stringValue":"\(postID)"},\
            "createdAt":{"timestampValue":"\(formatter.string(from: Date()))"},\
            "counted":{"booleanValue":false}}}
            """
        XCTAssertNotNil(
            json("\(Self.firestore)/posts/\(postID)/likes?documentId=\(otherUID)",
                 method: "POST", body: body),
            "could not write \(otherUID)'s like on \(postID)"
        )
        temporaryLikes.append((post: postID, uid: otherUID))
    }

    /// Scrolls until a post's text and its own action row are both on screen.
    @discardableResult
    private func scrollToPost(_ app: XCUIApplication, withText text: String) -> Bool {
        let target = app.staticTexts.matching(identifier: "post.text")
            .containing(NSPredicate(format: "label == %@", text)).firstMatch
        // A swipe budget and a deadline, because the two run out for different
        // reasons: the budget bounds how far down the list to look, the
        // deadline bounds how long to wait for a row that exists but has not
        // been laid out yet. Under load the second one is what bites — the
        // post is there and the feed has not finished drawing it, and a
        // count-only loop reports "the post went missing from the feed".
        let deadline = Date().addingTimeInterval(60)
        var swipes = 0
        while swipes < 15, Date() < deadline {
            dismissSavePasswordSheetIfPresent(app)
            if target.exists, target.isHittable,
               let like = likeButton(app, forPostWithText: text), like.isHittable {
                return true
            }
            if target.exists {
                // On screen but not settled: wait rather than scroll past it.
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            app.swipeUp()
            swipes += 1
        }
        return false
    }

    /// The like button belonging to one particular card.
    ///
    /// By geometry, because the cards are siblings in the tree and nothing
    /// links a button to the text above it: the first `post.like` below this
    /// card's text is this card's, since the next card's text comes after its
    /// own action row. Indexing into the visible buttons instead is what
    /// previously moved an assertion onto whatever card happened to be on
    /// screen.
    private func likeButton(_ app: XCUIApplication, forPostWithText text: String) -> XCUIElement? {
        let target = app.staticTexts.matching(identifier: "post.text")
            .containing(NSPredicate(format: "label == %@", text)).firstMatch
        guard target.exists else { return nil }
        let top = target.frame.minY
        return app.buttons.matching(identifier: "post.like").allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty && $0.frame.minY > top }
            .min { $0.frame.minY < $1.frame.minY }
    }

    private func shownCount(of button: XCUIElement) -> Int? {
        guard let value = button.value as? String,
              let digits = value.split(separator: " ").first else { return nil }
        return Int(digits)
    }

    // MARK: - 5A.8 Five taps in a row

    /// Five taps, then the button, the number and the server have to agree.
    ///
    /// An odd number of taps from a known start ends on the opposite intent,
    /// and the count must have moved by exactly one — not five, not zero, and
    /// never below zero. The unit test asserts the same thing over fakes with
    /// the taps genuinely interleaved; what this adds is that the real
    /// repository, the real rules and the real trigger produce one document
    /// and one increment out of it.
    ///
    /// XCUITest cannot promise how close together five `tap()`s land, so this
    /// does not claim to reproduce a particular interleaving. It claims what
    /// 5A.8 actually asks: after five, everything agrees.
    func testFiveTapsInARowLeaveTheButtonTheNumberAndTheServerAgreeing() throws {
        let uid = try XCTUnwrap(uid(forEmail: account), "no uid for \(account)")
        let app = signedIn()
        let like = likeButton(app)
        XCTAssertTrue(waitUntilHittable(like, in: app, timeout: 30), "no like button")
        let postID = try XCTUnwrap(firstPostID(app), "could not tell which post the first row is")

        let startLabel = like.label
        let startShown = try XCTUnwrap(shownCount(app), "the button announced no number")
        let startCount = try XCTUnwrap(backendLikeCount(of: postID), "\(postID) is not in the emulator")
        let startLiked = backendLikeExists(postID: postID, uid: uid)
        print("MEASURED 5A.8 target=\(postID) label=\(startLabel) shown=\(startShown) backend=\(startCount) liked=\(startLiked)")
        XCTAssertEqual(startShown, startCount, "screen and aggregate disagree before the first tap")

        for _ in 0..<5 { likeButton(app).tap() }

        let wantLiked = !startLiked
        let expected = startCount + (wantLiked ? 1 : -1)
        XCTAssertTrue(
            waitForLabel(wantLiked ? "Unlike" : "Like", on: app, timeout: 30),
            "after five taps the button says \(likeButton(app).label), not \(wantLiked ? "Unlike" : "Like")"
        )
        XCTAssertTrue(
            backendSettles(within: 60) { self.backendLikeExists(postID: postID, uid: uid) == wantLiked },
            "five taps left the like document \(backendLikeExists(postID: postID, uid: uid) ? "present" : "absent")"
        )
        XCTAssertTrue(
            backendSettles(within: 60) { self.backendLikeCount(of: postID) == expected },
            """
            five taps moved the aggregate to \
            \(backendLikeCount(of: postID).map(String.init) ?? "nothing"), expected \(expected)
            """
        )
        let ended = try XCTUnwrap(shownCount(app), "the button stopped announcing a number")
        XCTAssertEqual(ended, expected, "the number on screen is not what the server holds")
        XCTAssertGreaterThanOrEqual(ended, 0, "the count went negative")
        XCTAssertFalse(app.staticTexts["feed.likeError"].exists,
                       "five taps reported a failure: \(app.staticTexts["feed.likeError"].label)")

        // Put it back.
        tapLike(app)
        XCTAssertTrue(waitForLabel(startLabel, on: app, timeout: 30))
        XCTAssertTrue(
            backendSettles(within: 60) { self.backendLikeCount(of: postID) == startCount },
            "left \(postID) at \(backendLikeCount(of: postID).map(String.init) ?? "nothing"), not \(startCount)"
        )
    }

    // MARK: - 5A.9 A post that is no longer there

    /// The post is deleted on the server while it is on screen, and then its
    /// heart is tapped.
    ///
    /// The old web client turned the heart red and incremented the number with
    /// no write behind it. What has to happen instead: the row goes, the
    /// person is told, and nothing is written — which is checked at the
    /// server, because "no like appeared on screen" is also what a silently
    /// dropped write looks like.
    func testLikingAPostThatWasDeletedSaysSoAndWritesNothing() throws {
        let uid = try XCTUnwrap(uid(forEmail: account))
        let temporary = try XCTUnwrap(createTemporaryPost(label: "deleted"))
        let app = signedIn()

        XCTAssertTrue(scrollToPost(app, withText: temporary.text),
                      "the post this test created never appeared in the feed")
        let heart = try XCTUnwrap(likeButton(app, forPostWithText: temporary.text),
                                  "found the post but not its like button")
        XCTAssertEqual(heart.label, "Like", "the temporary post started out liked")

        // Gone, from under the screen that is still showing it.
        XCTAssertNotNil(json("\(Self.firestore)/posts/\(temporary.id)", method: "DELETE"),
                        "could not delete the post")
        XCTAssertNil(json("\(Self.firestore)/posts/\(temporary.id)"), "the post is still there")

        heart.tap()

        let banner = app.staticTexts["feed.likeError"]
        XCTAssertTrue(waitForExistence(of: banner, in: app, timeout: 30),
                      "liking a deleted post said nothing at all")
        XCTAssertEqual(banner.label, "That post no longer exists.")

        // The row goes with it: a card for a post that does not exist is a
        // second tap waiting to happen.
        let gone = Date().addingTimeInterval(20)
        var stillThere = true
        while Date() < gone {
            stillThere = app.staticTexts.matching(identifier: "post.text")
                .containing(NSPredicate(format: "label == %@", temporary.text)).firstMatch.exists
            if !stillThere { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertFalse(stillThere, "the deleted post is still in the list")

        // Nothing was written. The rules would have refused it anyway — a like
        // requires its post to exist — and the repository checks first, so
        // this is belt and braces on purpose: both have been wrong before.
        XCTAssertNil(json("\(Self.firestore)/posts/\(temporary.id)/likes/\(uid)"),
                     "a like was written against a post that does not exist")

        // And the feed still works afterwards. *Some* card's heart has to be
        // usable, not the first one in the tree: this test scrolled down to
        // reach its own post, so the first `post.like` is a card above the
        // fold — which exists, is not hittable, and is not a defect.
        let usable = backendSettles(within: 60) {
            app.buttons.matching(identifier: "post.like").allElementsBoundByIndex
                .contains { $0.exists && $0.isHittable }
        }
        XCTAssertTrue(usable, "the feed stopped responding after a post was dropped from it")
    }

    // MARK: - 5A.10 A like request that is never answered

    /// The deadline, on the real screen.
    ///
    /// **Why this test had to exist.** 5A.10 was signed off on a `FeedViewModel`
    /// unit test that hands the model a fake whose `like` never returns. That
    /// test is correct and it is not evidence about the app: it never
    /// constructs a view, never touches `FirestoreLikeRepository`, and never
    /// writes anything, so it cannot say what a person sees or what the server
    /// is left holding. Those are the two questions 5A.10 asks.
    ///
    /// **The fault is injected, because it cannot be provoked.** A reachable
    /// server answers or refuses; an unreachable one refuses quickly. Neither
    /// is "the request landed and no answer ever came", which is the case the
    /// 12-second deadline was written for. `-petnote-like-lose-response` makes
    /// `FirestoreLikeRepository.like` do the write for real and then never
    /// return — see that type's `Fault`. It is compiled only into a debug
    /// build; `PetNoteAppTests/ReleaseHygieneTests` is what keeps that true.
    ///
    /// **The deadline is not shortened for the test.** There is no injection
    /// point for `likeDeadline` above `FeedViewModel`, and adding one would
    /// mean this test proved a number the app does not ship. So it waits out
    /// the real twelve seconds, and the elapsed time is asserted to be more
    /// than eight — a banner that appeared instantly would mean the request
    /// had failed, which is a different outcome with different words.
    ///
    /// What has to be true afterwards, and each of these has a way of being
    /// wrong on its own:
    ///
    ///   1. the write really landed — otherwise there is nothing to have
    ///      written twice and the rest of the test proves nothing;
    ///   2. the screen stops waiting and says it does not know, rather than
    ///      keeping an optimistic like nothing will ever confirm;
    ///   3. the intent falls back to the last state the server was *known* to
    ///      hold, which here is "not liked" — the app must not claim the write
    ///      succeeded when it never heard that it had;
    ///   4. nothing was written a second time, checked at the emulator: one
    ///      document, one `likeCount`, and a `createTime` that did not move;
    ///   5. a refresh finds the truth, so the honest "I do not know" is
    ///      recoverable rather than permanent.
    func testALikeRequestThatIsNeverAnsweredRecoversWithoutWritingTwice() throws {
        let uid = try XCTUnwrap(uid(forEmail: account), "no uid for \(account)")
        let temporary = try XCTUnwrap(createTemporaryPost(label: "never-answered"))

        // Absent `likeCount` is normal and reads as 0; nil would mean no post.
        XCTAssertEqual(backendLikeCount(of: temporary.id), 0,
                       "the post this test created already has likes")
        XCTAssertFalse(backendLikeExists(postID: temporary.id, uid: uid),
                       "this account has already liked the post this test created")

        let app = signedIn(extraArguments: [Self.loseLikeResponse])
        XCTAssertTrue(scrollToPost(app, withText: temporary.text),
                      "the post this test created never appeared in the feed")
        let heart = try XCTUnwrap(likeButton(app, forPostWithText: temporary.text),
                                  "found the post but not its like button")
        XCTAssertEqual(heart.label, "Like", "the temporary post started out liked")
        XCTAssertEqual(shownCount(of: heart), 0, "the temporary post started out counted")

        let tappedAt = Date()
        XCTAssertTrue(waitUntilHittable(heart, in: app, timeout: 30),
                      "the like button is not tappable")
        heart.tap()
        // Registered before anything is asserted: from here on the server may
        // be holding a like, and a run that fails halfway must still not leave
        // one behind in the shared emulator.
        temporaryLikes.append((post: temporary.id, uid: uid))

        // (1) Optimistic while the request is outstanding — a heart that did
        //     not fill would mean the tap never reached the model.
        XCTAssertTrue(waitForLabel("Unlike", ofPostWithText: temporary.text, in: app, timeout: 10),
                      "the heart did not fill while the request was in flight")

        // (1) And the write really happened. If the fault had swallowed the
        //     write as well, everything below would pass by being vacuous.
        XCTAssertTrue(
            backendSettles(within: 25) { self.backendLikeExists(postID: temporary.id, uid: uid) },
            "the injected fault was supposed to lose the answer, not the write"
        )
        let createTimeWhenWritten = try XCTUnwrap(
            likeCreateTime(postID: temporary.id, uid: uid),
            "the like document has no createTime to compare against later"
        )

        // (2) Still waiting, six seconds in.
        //
        //     Asserted separately from the elapsed time below, because elapsed
        //     time alone does not distinguish the two outcomes: the backend
        //     polling above can take seconds of its own, and a banner that had
        //     appeared instantly would still be "more than eight seconds after
        //     the tap" by the time anything looked. A banner before the
        //     deadline means the request *failed*, which carries different
        //     words and a different conclusion about the count.
        let banner = app.staticTexts["feed.likeError"]
        while Date().timeIntervalSince(tappedAt) < 6 {
            XCTAssertFalse(
                banner.exists,
                "the screen gave up \(Date().timeIntervalSince(tappedAt))s after the tap; "
                + "the deadline is 12s and the request had not failed, it was unanswered"
            )
            Thread.sleep(forTimeInterval: 0.5)
        }

        // And then it does stop waiting, in its own words.
        XCTAssertTrue(
            waitForExistence(of: banner, in: app, timeout: 45),
            "the deadline passed and the screen said nothing; it is still showing a like "
            + "that nothing will ever confirm"
        )
        let waited = Date().timeIntervalSince(tappedAt)
        print("MEASURED 5A.10 like deadline: banner \(String(format: "%.1f", waited))s after the tap")
        XCTAssertEqual(banner.label, "Could not confirm that. Pull down to refresh.",
                       "an unanswered request must not be reported as a failure")
        XCTAssertGreaterThan(
            waited, 8,
            "the banner arrived after \(waited)s, far inside the 12s deadline — that is a "
            + "request that failed, not one that was never answered"
        )

        // (3) The intent goes back to the last thing the server was known to
        //     hold. "Known" is the operative word: the like is on the server,
        //     but this client was never told so, and claiming otherwise would
        //     be the same guess that the deadline exists to stop.
        XCTAssertTrue(
            waitForLabel("Like", ofPostWithText: temporary.text, in: app, timeout: 15),
            "the heart stayed filled after the deadline, on the strength of an answer "
            + "that never came"
        )
        let afterDeadline = try XCTUnwrap(likeButton(app, forPostWithText: temporary.text))
        XCTAssertEqual(shownCount(of: afterDeadline), 0,
                       "the count kept a +1 for a write this client cannot confirm")

        // (4) Nothing was written twice. Three readings, because each one alone
        //     has a hole: a second `create` on the same path is refused by the
        //     rules and would leave the count alone, a delete-and-recreate
        //     would leave the count alone too but move `createTime`, and a
        //     second document under a different id would move neither.
        XCTAssertEqual(
            likeDocumentCount(ofPost: temporary.id), 1,
            "the likes subcollection of \(temporary.id) does not hold exactly one document"
        )
        XCTAssertEqual(
            likeCreateTime(postID: temporary.id, uid: uid), createTimeWhenWritten,
            "the like document was created again after the deadline passed"
        )
        XCTAssertTrue(
            backendSettles(within: 25) { self.backendLikeCount(of: temporary.id) == 1 },
            "likeCount settled at \(backendLikeCount(of: temporary.id).map(String.init) ?? "nothing")"
            + ", not 1 — the trigger counted the like a number of times other than once"
        )

        // (5) The instruction in the banner is the one that works.
        pullToRefresh(app)
        XCTAssertTrue(scrollToPost(app, withText: temporary.text),
                      "the post went missing from the feed after a refresh")
        XCTAssertTrue(
            waitForLabel("Unlike", ofPostWithText: temporary.text, in: app, timeout: 30),
            "a refresh did not adopt the like the server has been holding all along"
        )
        XCTAssertTrue(
            waitForCount(1, ofPostWithText: temporary.text, in: app, timeout: 30),
            "the refreshed count is "
            + "\(likeButton(app, forPostWithText: temporary.text).flatMap(shownCount(of:)).map(String.init) ?? "unreadable")"
            + ", not the 1 the server holds"
        )

        // And the refresh did not produce a second write of its own.
        XCTAssertEqual(likeDocumentCount(ofPost: temporary.id), 1,
                       "a second like document appeared while the feed was being refreshed")
        XCTAssertEqual(backendLikeCount(of: temporary.id), 1,
                       "likeCount moved again after the screen had already converged")
    }

    /// The launch flag that makes `FirestoreLikeRepository.like` write and then
    /// never return. Spelled once, here, so the flag and its only user move
    /// together.
    private static let loseLikeResponse = "-petnote-like-lose-response"

    /// How many like documents the post holds, from the server.
    ///
    /// The subcollection rather than the one document at `likes/{uid}`: a
    /// duplicate write that used a different document id would leave that one
    /// untouched and still double the count when the trigger ran.
    private func likeDocumentCount(ofPost postID: String) -> Int {
        guard let listing = json("\(Self.firestore)/posts/\(postID)/likes") else { return 0 }
        return (listing["documents"] as? [Any])?.count ?? 0
    }

    /// The server's own creation stamp for a like document.
    ///
    /// `createTime`, not the `createdAt` field: the field is written by the
    /// client and a rewrite would carry the same value, while `createTime` is
    /// the server's and moves only if the document is genuinely new.
    /// `updateTime` is no use for this — `onLikeCreated` flips `counted` in
    /// the same transaction that moves the count, so it moves every time,
    /// whether or not anybody wrote twice.
    private func likeCreateTime(postID: String, uid: String) -> String? {
        json("\(Self.firestore)/posts/\(postID)/likes/\(uid)")?["createTime"] as? String
    }

    /// The accessibility label of one particular card's heart, waited for.
    ///
    /// By card rather than `likeButton(app)`: this test scrolls down to its own
    /// post, so the first `post.like` in the tree belongs to a card above the
    /// fold and would answer for the wrong post.
    private func waitForLabel(
        _ expected: String, ofPostWithText text: String,
        in app: XCUIApplication, timeout: TimeInterval = 15
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if likeButton(app, forPostWithText: text)?.label == expected { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return likeButton(app, forPostWithText: text)?.label == expected
    }

    // MARK: - Somebody else moved the count

    /// Another account likes and unlikes the same post, and this client has to
    /// end up agreeing with the server both times.
    ///
    /// This is the case `likeCount` cannot answer on its own: one integer does
    /// not say whose write it contains, so a stranger's like moves it by
    /// exactly as much as our own unconfirmed one would. The bounded offset is
    /// what stops that being permanent, and this drives it through the real
    /// UI — a pull to refresh, on a post whose count really did change
    /// underneath us.
    func testACountMovedByAnotherAccountIsAdoptedOnRefresh() throws {
        let mine = try XCTUnwrap(uid(forEmail: account), "no uid for \(account)")
        let theirs = try XCTUnwrap(uid(forEmail: other), "no uid for \(other)")
        let temporary = try XCTUnwrap(createTemporaryPost(label: "stranger"))
        let app = signedIn()

        XCTAssertTrue(scrollToPost(app, withText: temporary.text), "the post never appeared")
        var heart = try XCTUnwrap(likeButton(app, forPostWithText: temporary.text))
        XCTAssertEqual(shownCount(of: heart), 0, "a post nobody has liked did not start at zero")
        XCTAssertEqual(backendLikeCount(of: temporary.id), 0, "the aggregate did not start at zero")

        // Somebody else likes it.
        likeAsAnotherAccount(postID: temporary.id, uid: theirs)
        XCTAssertTrue(
            backendSettles(within: 60) { self.backendLikeCount(of: temporary.id) == 1 },
            "the trigger never counted the other account's like"
        )

        pullToRefresh(app)
        XCTAssertTrue(scrollToPost(app, withText: temporary.text), "the post vanished on refresh")
        if !waitForCount(1, ofPostWithText: temporary.text, in: app) {
            // Two very different faults look identical from here, so ask the
            // other way before saying which one it is: a cold start reads
            // everything again and cannot be confused with a gesture that
            // failed to trigger a reload.
            let afterRefresh = likeButton(app, forPostWithText: temporary.text)
                .flatMap(shownCount(of:))
            relaunchAndSignIn(app)
            _ = scrollToPost(app, withText: temporary.text)
            let afterRelaunch = likeButton(app, forPostWithText: temporary.text)
                .flatMap(shownCount(of:))
            XCTFail("""
                the other account's like did not reach the screen. After a pull to \
                refresh the card said \(afterRefresh.map(String.init) ?? "nothing"); after a \
                cold start it said \(afterRelaunch.map(String.init) ?? "nothing"); the server \
                holds \(backendLikeCount(of: temporary.id).map(String.init) ?? "nothing"). \
                A cold start that says 1 means the refresh did not read; a cold start that \
                also says 0 means the client will not adopt the server's count at all.
                """)
        }
        heart = try XCTUnwrap(likeButton(app, forPostWithText: temporary.text))
        XCTAssertEqual(heart.label, "Like", "somebody else's like filled in our heart")

        // Now our own, on top of theirs.
        heart = try XCTUnwrap(likeButton(app, forPostWithText: temporary.text))
        heart.tap()
        XCTAssertTrue(waitForCount(2, ofPostWithText: temporary.text, in: app),
                      "our like did not add to theirs")
        XCTAssertTrue(
            backendSettles(within: 60) { self.backendLikeCount(of: temporary.id) == 2 },
            "the aggregate is \(backendLikeCount(of: temporary.id).map(String.init) ?? "nothing"), expected 2"
        )
        XCTAssertTrue(backendLikeExists(postID: temporary.id, uid: mine), "our like was never written")
        temporaryLikes.append((post: temporary.id, uid: mine))

        // And they take theirs back.
        XCTAssertNotNil(
            json("\(Self.firestore)/posts/\(temporary.id)/likes/\(theirs)", method: "DELETE"),
            "could not remove the other account's like"
        )
        XCTAssertTrue(
            backendSettles(within: 60) { self.backendLikeCount(of: temporary.id) == 1 },
            "the trigger never took the other account's like off the count"
        )

        // This is the case the aggregate cannot answer, and the one the bound
        // exists for. Our own like is confirmed but the count has not caught
        // up with it yet, so we hold a +1; their unlike then moves the count
        // back down by exactly as much, so it reads the same as before and
        // "has it caught up?" can never answer yes. The offset is therefore
        // *not* dropped on the first read, by design — it is given up after
        // `unconfirmedReadLimit` (3) of them, server wins.
        //
        // So convergence is what is asserted, with the documented bound as the
        // deadline, and the number of reads it took is printed. One refresh
        // showing 2 is the design; still showing 2 after four is the defect.
        var reads = 0
        var settled = false
        for _ in 0..<4 {
            reads += 1
            pullToRefresh(app)
            XCTAssertTrue(scrollToPost(app, withText: temporary.text),
                          "the post vanished on refresh \(reads)")
            if waitForCount(1, ofPostWithText: temporary.text, in: app, timeout: 5) {
                settled = true
                break
            }
        }
        print("MEASURED convergence after a stranger's unlike: \(reads) refresh(es), settled=\(settled)")
        XCTAssertTrue(
            settled,
            "the screen kept a like that was taken away: after \(reads) refreshes it says "
                + "\(likeButton(app, forPostWithText: temporary.text).flatMap(shownCount(of:)).map(String.init) ?? "nothing")"
                + ", the server says 1"
        )
        heart = try XCTUnwrap(likeButton(app, forPostWithText: temporary.text))
        XCTAssertEqual(heart.label, "Unlike", "our own like was lost when theirs went away")
    }

    // MARK: - §4.4 The next account inherits none of this

    /// One account likes a post; the next account must see the server's state
    /// and nothing of the first account's.
    ///
    /// The count is the half that hides. A filled heart belonging to somebody
    /// else is obvious, but an unconfirmed +1 left over from the previous
    /// person looks exactly like a number — and the worst case is quiet: the
    /// aggregate already contains the like, so the leftover offset shows the
    /// next person one more than the truth with nothing on screen to
    /// contradict it.
    ///
    /// On a post this test made, so the answer is not "whatever the seed
    /// happened to leave on post one".
    func testTheNextAccountSeesNoneOfThePreviousAccountsLikeState() throws {
        let mine = try XCTUnwrap(uid(forEmail: account), "no uid for \(account)")
        let temporary = try XCTUnwrap(createTemporaryPost(label: "switch"))
        let app = signedIn()

        XCTAssertTrue(scrollToPost(app, withText: temporary.text), "the post never appeared")
        let heart = try XCTUnwrap(likeButton(app, forPostWithText: temporary.text))
        XCTAssertEqual(shownCount(of: heart), 0)
        heart.tap()
        temporaryLikes.append((post: temporary.id, uid: mine))

        XCTAssertTrue(waitForCount(1, ofPostWithText: temporary.text, in: app),
                      "our own like never showed")
        XCTAssertTrue(
            backendSettles(within: 60) { self.backendLikeCount(of: temporary.id) == 1 },
            "the aggregate never caught up, so this test cannot tell a leftover offset from a real count"
        )

        // Out, and in as somebody else. Two taps now: sign-out moved from the
        // navigation bar into the account menu, so reaching it is part of the
        // flow rather than one control on screen.
        signOutFromAccountMenu(app)
        typeCredentials(app, email: other, password: password)
        XCTAssertTrue(reachedFeed(app), "did not reach the feed as \(other)")
        waitForQuietUI(app)

        XCTAssertTrue(scrollToPost(app, withText: temporary.text),
                      "the post is not in the second account's feed")
        let afterSwitch = try XCTUnwrap(likeButton(app, forPostWithText: temporary.text))
        XCTAssertEqual(
            afterSwitch.label, "Like",
            "the previous account's filled heart survived the switch"
        )
        XCTAssertEqual(
            shownCount(of: afterSwitch), 1,
            "the second account is shown \(shownCount(of: afterSwitch).map(String.init) ?? "nothing") "
                + "likes where the server holds 1 — the previous account's optimistic offset is still here"
        )
    }

    /// Waits for one card's announced number to settle on `expected`.
    ///
    /// The button is looked up again on every poll. An element taken from
    /// `allElementsBoundByIndex` is bound to a position in the tree, and a
    /// refresh rebuilds that tree — so a held reference goes on answering for
    /// whatever is at that position afterwards, which is how a stale reading
    /// outlives the thing it was read from.
    private func waitForCount(
        _ expected: Int,
        ofPostWithText text: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 25
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let button = likeButton(app, forPostWithText: text),
               shownCount(of: button) == expected { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return likeButton(app, forPostWithText: text).flatMap(shownCount(of:)) == expected
    }

    /// A real pull-to-refresh, from wherever the list happens to be.
    ///
    /// Two things had to be true and neither was. The list has to be at the
    /// **top**, because a downward drag anywhere else only scrolls; and the
    /// gesture has to be a **pull**, held, rather than a flick. `swipeDown()`
    /// is a flick, and ten of them in a row moved the list to the top and
    /// refreshed nothing — which this test then reported as the app failing to
    /// adopt a change it had never been asked to go and look for.
    private func pullToRefresh(_ app: XCUIApplication) {
        for _ in 0..<8 { app.swipeDown() }
        waitForQuietUI(app, quietFor: 1, timeout: 15)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.8)
        waitForQuietUI(app, quietFor: 1, timeout: 20)
    }

    /// The same question asked the hard way: a cold start reads everything
    /// again, so it cannot be confused with a gesture that did nothing.
    private func relaunchAndSignIn(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments = ["-petnote-start-signed-out"]
        app.launch()
        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 20))
        typeCredentials(app, email: account, password: password)
        XCTAssertTrue(reachedFeed(app), "did not reach the feed after relaunching")
        waitForQuietUI(app)
    }
}
