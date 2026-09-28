import XCTest

/// What the tests for search, the social lists, pet deletion, the composer's
/// draft and password recovery need from the emulators beyond `EmulatorAdmin`
/// and `JourneyAdmin`.
///
/// Three kinds of thing, kept apart on purpose:
///
///   - **Fixtures.** Documents written straight into Firestore with
///     `Bearer owner`, which the rules never see. They stand for "somebody
///     else already did this" — another person follows the pet, another
///     person has two pets. Nothing a test is *about* is written this way: the
///     action under test always goes through the screens.
///   - **Reads.** Whole collections, structured queries and the Auth
///     emulator's out-of-band codes: the server's half of every assertion.
///   - **A callable called as a person.** The one place a test asks the server
///     something the app never lets a person ask. The app offers no Delete on
///     a pet with two owners, so the only way to show that the screen and the
///     server agree is to ask `deletePetCallable` directly and be refused.
///
/// Loopback only, like `EmulatorAdmin`: the hosts and the project are
/// constants, and `Bearer owner` is the emulator's own protocol, which a real
/// backend does not implement.
enum ServerFixtures {
    static let documentsURL =
        "\(EmulatorAdmin.firestore)/v1/projects/\(EmulatorAdmin.projectID)/databases/(default)/documents"
    /// `firebase.json` puts the functions emulator on 5101, and so does
    /// `AppEnvironment.functionsPort`. A v2 callable with no region set is
    /// served from us-central1.
    static let functionsURL = "http://127.0.0.1:5101/\(EmulatorAdmin.projectID)/us-central1"

    struct Response {
        let status: Int
        let json: Any?
        let text: String
    }

    struct Document {
        /// The full resource name: `projects/…/documents/pets/p1/family/u1`.
        let name: String
        let fields: [String: Any]

        var id: String { String(name.split(separator: "/").last ?? "") }

        /// The document that holds the collection this one is in — the pet,
        /// for `pets/{pet}/family/{user}`.
        var parentID: String? {
            let parts = name.split(separator: "/")
            return parts.count >= 3 ? String(parts[parts.count - 3]) : nil
        }
    }

    // MARK: - Transport

    /// The answer, written on URLSession's queue and read after the
    /// semaphore. Locked even so: it is touched from two threads, and an
    /// unlocked record is how a test double crashed CI with SIGSEGV.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<(Int, Data), Error>?

        func set(_ value: Result<(Int, Data), Error>) {
            lock.lock()
            outcome = value
            lock.unlock()
        }

        func get() -> Result<(Int, Data), Error>? {
            lock.lock()
            defer { lock.unlock() }
            return outcome
        }
    }

    /// One HTTP exchange, with its status code.
    ///
    /// The status is handed back rather than judged here, because one caller
    /// is *hoping* for a refusal: a 400 from `deletePetCallable` is the result
    /// that test exists to see, and a transport that threw on it would hide
    /// the difference between "refused" and "could not ask".
    static func send(
        _ method: String, _ url: String, body: [String: Any]? = nil, bearer: String? = nil
    ) throws -> Response {
        guard let target = URL(string: url) else { throw failure("bad url \(url)") }
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.timeoutInterval = 20
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                answer.set(.failure(error))
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                answer.set(.success((status, data ?? Data())))
            }
            done.signal()
        }.resume()
        // A blocking wait, as in EmulatorAdmin: XCTest's methods are
        // synchronous and this is bookkeeping, not what is being measured.
        _ = done.wait(timeout: .now() + 25)

        guard let outcome = answer.get() else { throw failure("timed out: \(method) \(url)") }
        let (status, data) = try outcome.get()
        return Response(
            status: status,
            json: try? JSONSerialization.jsonObject(with: data),
            text: String(data: data, encoding: .utf8) ?? ""
        )
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "ServerFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Fixtures

    /// Creates or replaces one document, and throws if the emulator says no.
    /// A fixture that did not land turns every assertion after it into a
    /// statement about nothing.
    static func write(_ path: String, _ fields: [String: Any]) throws {
        let response = try send(
            "PATCH", "\(documentsURL)/\(path)", body: ["fields": fields.mapValues(encode)], bearer: "owner"
        )
        guard response.status == 200 else {
            throw failure("the emulator refused \(path): HTTP \(response.status) \(response.text.prefix(300))")
        }
    }

    /// A Swift value as a Firestore REST value. Bool before Int, so `true`
    /// is written as a boolean and not as 1.
    static func encode(_ value: Any) -> [String: Any] {
        switch value {
        case let text as String: return ["stringValue": text]
        case let flag as Bool: return ["booleanValue": flag]
        case let whole as Int: return ["integerValue": String(whole)]
        case let real as Double: return ["doubleValue": real]
        case let date as Date: return ["timestampValue": ISO8601DateFormatter().string(from: date)]
        case let map as [String: Any]: return ["mapValue": ["fields": map.mapValues(encode)]]
        case let list as [Any]: return ["arrayValue": ["values": list.map(encode)]]
        default: return ["nullValue": NSNull()]
        }
    }

    /// The notifications the server's triggers wrote for this person. A
    /// follow tells the pet's owners; those documents are ours to remove.
    static func deleteNotifications(for uid: String) {
        for name in (try? JourneyAdmin.documentNames(in: "notifications", field: "userId", equals: uid)) ?? [] {
            EmulatorAdmin.deleteComment(documentName: name)
        }
    }

    // MARK: - Reads

    /// Every document directly in one collection — `pets/p1/followers`.
    static func documents(in collectionPath: String) throws -> [Document] {
        let response = try send("GET", "\(documentsURL)/\(collectionPath)?pageSize=300", bearer: "owner")
        guard response.status == 200 else {
            throw failure("could not list \(collectionPath): HTTP \(response.status) \(response.text.prefix(300))")
        }
        let rows = ((response.json as? [String: Any])?["documents"] as? [[String: Any]]) ?? []
        return rows.compactMap(document(from:))
    }

    static func ids(in collectionPath: String) throws -> Set<String> {
        Set(try documents(in: collectionPath).map(\.id))
    }

    /// A structured query with admin rights.
    ///
    /// The status is checked, and a body that is not an array is a failure:
    /// Firestore answers a rejected query with an *object*, and reading that
    /// as "no rows" is how four counting assertions once stayed green over a
    /// query that never ran (see `EmulatorAdmin.get`).
    static func query(_ structuredQuery: [String: Any]) throws -> [Document] {
        let response = try send(
            "POST", "\(documentsURL):runQuery", body: ["structuredQuery": structuredQuery], bearer: "owner"
        )
        guard response.status == 200, let rows = response.json as? [[String: Any]] else {
            throw failure("the query was refused: HTTP \(response.status) \(response.text.prefix(300))")
        }
        // A query that matches nothing still answers with one row: the read
        // time, and no document.
        return rows.compactMap { ($0["document"] as? [String: Any]).flatMap(document(from:)) }
    }

    private static func document(from row: [String: Any]) -> Document? {
        guard let name = row["name"] as? String else { return nil }
        return Document(name: name, fields: row["fields"] as? [String: Any] ?? [:])
    }

    /// The pets this person is in the family of: the collection-group read
    /// the app's own "pets of a user" makes.
    static func petIDs(ownedBy uid: String) throws -> Set<String> {
        let rows = try query([
            "from": [["collectionId": "family", "allDescendants": true]],
            "where": ["fieldFilter": [
                "field": ["fieldPath": "userId"], "op": "EQUAL", "value": ["stringValue": uid],
            ]],
            "limit": 100,
        ])
        return Set(rows.compactMap(\.parentID))
    }

    struct Tag: Equatable {
        let name: String
        let postCount: Int
    }

    private static func tags(from rows: [Document]) -> [Tag] {
        rows.compactMap { row in
            guard let name = string(row.fields, "name")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return Tag(name: name, postCount: max(0, int(row.fields, "postCount") ?? 0))
        }
    }

    /// `hashtags` whose name starts with `prefix`, in name order — the query
    /// `FirestoreSearchRepository.tags(prefix:limit:)` runs.
    static func tags(startingWith prefix: String, limit: Int) throws -> [Tag] {
        let rows = try query([
            "from": [["collectionId": "hashtags"]],
            "where": ["compositeFilter": ["op": "AND", "filters": [
                ["fieldFilter": [
                    "field": ["fieldPath": "name"], "op": "GREATER_THAN_OR_EQUAL",
                    "value": ["stringValue": prefix],
                ]],
                ["fieldFilter": [
                    "field": ["fieldPath": "name"], "op": "LESS_THAN_OR_EQUAL",
                    "value": ["stringValue": prefix + "\u{f8ff}"],
                ]],
            ]]],
            "orderBy": [["field": ["fieldPath": "name"], "direction": "ASCENDING"]],
            "limit": limit,
        ])
        return tags(from: rows)
    }

    /// The most used tags — `popularTags(limit:)`.
    static func popularTags(limit: Int) throws -> [Tag] {
        tags(from: try query([
            "from": [["collectionId": "hashtags"]],
            "orderBy": [["field": ["fieldPath": "postCount"], "direction": "DESCENDING"]],
            "limit": limit,
        ]))
    }

    /// Posts carrying `tag`, newest first — `posts(taggedWith:limit:)`.
    static func posts(taggedWith tag: String, limit: Int) throws -> [Document] {
        try query([
            "from": [["collectionId": "posts"]],
            "where": ["fieldFilter": [
                "field": ["fieldPath": "tags"], "op": "ARRAY_CONTAINS", "value": ["stringValue": tag],
            ]],
            "orderBy": [["field": ["fieldPath": "createdAt"], "direction": "DESCENDING"]],
            "limit": limit,
        ]).filter(isDisplayablePost)
    }

    /// Posts since `date`, newest first — `posts(since:limit:)`.
    static func posts(since date: Date, limit: Int) throws -> [Document] {
        try query([
            "from": [["collectionId": "posts"]],
            "where": ["fieldFilter": [
                "field": ["fieldPath": "createdAt"], "op": "GREATER_THAN_OR_EQUAL",
                "value": ["timestampValue": ISO8601DateFormatter().string(from: date)],
            ]],
            "orderBy": [["field": ["fieldPath": "createdAt"], "direction": "DESCENDING"]],
            "limit": limit,
        ]).filter(isDisplayablePost)
    }

    /// Pets by follower count, most first — `petsByFollowers(limit:)`. Pets
    /// with no usable name are dropped, as `PetDecoder.pet` drops them.
    static func petsByFollowers(limit: Int) throws -> [Document] {
        try query([
            "from": [["collectionId": "pets"]],
            "orderBy": [["field": ["fieldPath": "followerCount"], "direction": "DESCENDING"]],
            "limit": limit,
        ]).filter { petName($0) != nil }
    }

    /// `PetDecoder.pet`'s one requirement.
    static func petName(_ pet: Document) -> String? {
        guard let name = string(pet.fields, "name")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    /// `PostDecoder.post`'s two requirements: an author and a creation time.
    private static func isDisplayablePost(_ post: Document) -> Bool {
        guard let author = string(post.fields, "authorId"), !author.isEmpty else { return false }
        return (post.fields["createdAt"] as? [String: Any])?["timestampValue"] != nil
    }

    // MARK: - Field values

    static func string(_ fields: [String: Any], _ key: String) -> String? {
        (fields[key] as? [String: Any])?["stringValue"] as? String
    }

    /// Counters arrive as `integerValue` — a string — or, once a trigger has
    /// done arithmetic on them, occasionally as `doubleValue`.
    static func int(_ fields: [String: Any], _ key: String) -> Int? {
        guard let value = fields[key] as? [String: Any] else { return nil }
        if let text = value["integerValue"] as? String { return Int(text) }
        if let real = value["doubleValue"] as? Double { return Int(real) }
        return nil
    }

    static func strings(_ fields: [String: Any], _ key: String) -> [String] {
        let values = ((fields[key] as? [String: Any])?["arrayValue"] as? [String: Any])?["values"] as? [Any] ?? []
        return values.compactMap { ($0 as? [String: Any])?["stringValue"] as? String }
    }

    // MARK: - Auth emulator

    struct OobCode {
        let email: String
        let requestType: String
        let code: String
    }

    /// The out-of-band codes the Auth emulator has issued for `email`.
    ///
    /// The emulator sends no mail. What it would have sent — the code, the
    /// link, and whether it was a password reset or a verification — it keeps
    /// here, and this is the only place the test can see that a request from
    /// the app reached it.
    static func oobCodes(for email: String) throws -> [OobCode] {
        let response = try send(
            "GET", "\(EmulatorAdmin.auth)/emulator/v1/projects/\(EmulatorAdmin.projectID)/oobCodes"
        )
        guard response.status == 200 else {
            throw failure("the Auth emulator would not list its codes: HTTP \(response.status) \(response.text.prefix(300))")
        }
        let rows = ((response.json as? [String: Any])?["oobCodes"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let address = row["email"] as? String,
                  address.caseInsensitiveCompare(email) == .orderedSame else { return nil }
            return OobCode(
                email: address,
                requestType: row["requestType"] as? String ?? "",
                code: row["oobCode"] as? String ?? ""
            )
        }
    }

    /// An ID token for a password account, from the Auth emulator.
    static func idToken(email: String, password: String) throws -> String {
        let response = try send(
            "POST",
            "\(EmulatorAdmin.auth)/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake-api-key",
            body: ["email": email, "password": password, "returnSecureToken": true]
        )
        guard response.status == 200,
              let token = (response.json as? [String: Any])?["idToken"] as? String else {
            throw failure("could not sign in \(email): HTTP \(response.status) \(response.text.prefix(300))")
        }
        return token
    }

    /// A callable, called the way the Firebase SDK calls one — `{"data": …}`
    /// with the person's ID token — and answered as it answers: `{"result"}`
    /// with 200, or `{"error": {"status"}}` with the code's HTTP status
    /// (FAILED_PRECONDITION is a 400).
    static func call(_ name: String, _ data: [String: Any], idToken: String) throws -> Response {
        try send("POST", "\(functionsURL)/\(name)", body: ["data": data], bearer: idToken)
    }
}

// MARK: - Waiting, and places in the app several of these tests start from

extension XCTestCase {
    /// Polls until `condition` holds, for server state a trigger or a callable
    /// writes after the screen has already moved on. Returns whether it held;
    /// the caller says what it was waiting for.
    func serverEventually(timeout: TimeInterval = 30, _ condition: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return try condition()
    }

    @discardableResult
    func waitUntilLabel(of element: XCUIElement, equals expected: String, timeout: TimeInterval = 20) -> Bool {
        let reached = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element)
        return XCTWaiter().wait(for: [reached], timeout: timeout) == .completed
    }

    @discardableResult
    func waitUntilValue(of element: XCUIElement, equals expected: String, timeout: TimeInterval = 20) -> Bool {
        let reached = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: element)
        return XCTWaiter().wait(for: [reached], timeout: timeout) == .completed
    }

    /// Home → the search button in the feed's bar. Returns the search field.
    @discardableResult
    func openSearchFromHome(
        _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIElement {
        let home = app.tabBars.buttons["Home"]
        XCTAssertTrue(waitUntilHittable(home, in: app, timeout: 20), "no Home tab", file: file, line: line)
        home.tap()
        let search = app.buttons["feed.search"]
        XCTAssertTrue(waitUntilHittable(search, in: app, timeout: 20), "no search on the feed", file: file, line: line)
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(
            waitUntilHittable(field, in: app, timeout: 20),
            "no search field\n\(app.debugDescription)", file: file, line: line
        )
        return field
    }

    /// Types a query and presses the keyboard's Search key, as a person does.
    func submitSearch(_ field: XCUIElement, _ text: String) {
        field.tap()
        field.typeText(text + "\n")
    }

    /// Taps a result that may be under the keyboard.
    ///
    /// The results below the first section sit where the keyboard is while
    /// the field has focus. Its own Search key is the way a person puts it
    /// away; pressing it runs the same search again, and the wait covers the
    /// moment the list is replaced by its spinner and comes back.
    func tapResult(
        _ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(waitForExistence(of: element, in: app, timeout: 30),
                      "no such result\n\(app.debugDescription)", file: file, line: line)
        if !element.isHittable {
            let key = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] %@", "search")).firstMatch
            if key.exists { key.tap() }
        }
        XCTAssertTrue(waitUntilHittable(element, in: app, timeout: 20),
                      "the result never became tappable\n\(app.debugDescription)", file: file, line: line)
        element.tap()
    }

    /// Profile → one of the signed-in person's pets.
    func openOwnPet(
        _ app: XCUIApplication, petID: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let profile = app.tabBars.buttons["Profile"]
        XCTAssertTrue(waitUntilHittable(profile, in: app, timeout: 20), "no Profile tab", file: file, line: line)
        profile.tap()
        let row = app.buttons["profile.pet.\(petID)"]
        XCTAssertTrue(waitUntilHittable(row, in: app, timeout: 30),
                      "the pet is not in My pets\n\(app.debugDescription)", file: file, line: line)
        row.tap()
        XCTAssertTrue(waitForExistence(of: app.staticTexts["pet.name"], in: app, timeout: 30),
                      "the pet's page did not open", file: file, line: line)
    }
}
