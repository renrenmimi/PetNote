import XCTest

/// Talks to the Firebase emulators directly, from the test process.
///
/// Two things need this and cannot be done through the app:
///
///   - **Proving a comment exists.** A row on screen proves the app drew a
///     row. The acceptance criterion is that a comment was *written*, and the
///     only place that can be answered is the server. A previous test counted
///     a combined accessibility row plus the `Text` inside it as two comments
///     while the server held one; reading the server makes that class of
///     mistake impossible rather than merely unlikely.
///   - **Revoking a session.** §6.9 starts with the server taking the session
///     away, which by definition cannot be asked for from inside the app.
///
/// Everything here is scoped to the emulator on loopback. There is no path
/// from any of it to a real project: the host and project are constants, and
/// the admin calls are the emulator's own `Bearer owner` protocol, which a
/// real backend does not implement.
enum EmulatorAdmin {
    static let projectID = "petnote-test"
    static let firestore = "http://127.0.0.1:8088"
    static let auth = "http://127.0.0.1:9099"

    /// Accounts this run created, so they can be removed again. The shared
    /// emulator is seeded once for everyone; adding is allowed, leaving things
    /// behind is not.
    private static let createdUIDs = UIDBox()

    final class UIDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
        func drain() -> [String] {
            lock.lock(); defer { ids = []; lock.unlock() }
            return ids
        }
    }

    // MARK: - The seed manifest

    /// What the current seed run created.
    ///
    /// Tests used to name documents directly — `ios-post-001` and so on. That
    /// stopped being possible when each seed run started writing into its own
    /// namespace, and it was a bad idea before that: a hardcoded id is exactly
    /// what let a test keep passing against data left behind by a run nobody
    /// remembered, including one whose own self-checks had failed.
    struct SeedManifest {
        let runId: String
        let postIdPrefix: String
        /// Named posts — "manyComments", "brokenVideo", "textOnly" and so on.
        let landmarks: [String: String]

        func post(_ landmark: String) -> String? { landmarks[landmark] }
        /// The document id for an index, matching the seed's own numbering.
        func post(index: Int) -> String { postIdPrefix + String(format: "%03d", index) }
    }

    /// Read once per test process and then reused.
    ///
    /// `seedRuns/current` is a moving target: a reseed replaces it, and two
    /// suites running side by side would otherwise disagree about which run
    /// they are testing — one of them halfway through. Pinning it at first
    /// use means every assertion in a process refers to the same dataset, and
    /// a reseed during a run shows up as tests failing against data that is
    /// gone rather than as tests quietly changing their subject.
    private static let pinned = ManifestBox()

    final class ManifestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SeedManifest?
        func resolve(_ make: () throws -> SeedManifest) throws -> SeedManifest {
            lock.lock(); defer { lock.unlock() }
            if let value { return value }
            let fresh = try make()
            value = fresh
            return fresh
        }
    }

    /// The manifest this process is pinned to.
    static func seedManifest() throws -> SeedManifest {
        try pinned.resolve { try readCurrentManifest() }
    }

    private static func readCurrentManifest() throws -> SeedManifest {
        let url = "\(firestore)/v1/projects/\(projectID)/databases/(default)/documents/seedRuns/current"
        let document = try get(url, owner: true)
        guard let fields = document["fields"] as? [String: Any],
              let prefix = (fields["postIdPrefix"] as? [String: Any])?["stringValue"] as? String,
              let runId = (fields["runId"] as? [String: Any])?["stringValue"] as? String
        else {
            throw NSError(domain: "EmulatorAdmin", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "No seed manifest at seedRuns/current. Run functions/scripts/seed-ios-native.mjs; "
                    + "it writes the manifest only when its self-checks pass."
            ])
        }

        var landmarks: [String: String] = [:]
        if let map = (fields["landmarks"] as? [String: Any])?["mapValue"] as? [String: Any],
           let entries = map["fields"] as? [String: Any] {
            for (key, value) in entries {
                if let text = (value as? [String: Any])?["stringValue"] as? String {
                    landmarks[key] = text
                }
            }
        }
        return SeedManifest(runId: runId, postIdPrefix: prefix, landmarks: landmarks)
    }

    // MARK: - Transport

    private static func get(_ url: String, owner: Bool) throws -> [String: Any] {
        guard let target = URL(string: url) else {
            throw NSError(domain: "EmulatorAdmin", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bad url \(url)"])
        }
        var request = URLRequest(url: target)
        if owner { request.setValue("Bearer owner", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 20

        // The status code is checked, not just the body.
        //
        // Firestore answers a rejected query with a JSON *object* describing
        // the error, and a successful one with an array. Callers that only
        // understand the array shape silently read a rejection as "no
        // documents" — so a query with a bogus operator came back as zero
        // results and four assertions that count documents stayed green.
        // A backend check that cannot fail is not a backend check.
        var result: Result<Data, Error>?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(data: data ?? Data(), encoding: .utf8)?.prefix(300) ?? ""
                result = .failure(NSError(domain: "EmulatorAdmin", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey:
                        "emulator refused the request: HTTP \(http.statusCode)\n\(body)"
                ]))
            } else {
                result = .success(data ?? Data())
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 25)

        guard let result else {
            throw NSError(domain: "EmulatorAdmin", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "timed out reading \(url)"])
        }
        let data = try result.get()
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func post(_ url: String, body: [String: Any], owner: Bool) throws -> [String: Any] {
        guard let target = URL(string: url) else {
            throw NSError(domain: "EmulatorAdmin", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bad url \(url)"])
        }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if owner { request.setValue("Bearer owner", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        // The status code is checked, not just the body.
        //
        // Firestore answers a rejected query with a JSON *object* describing
        // the error, and a successful one with an array. Callers that only
        // understand the array shape silently read a rejection as "no
        // documents" — so a query with a bogus operator came back as zero
        // results and four assertions that count documents stayed green.
        // A backend check that cannot fail is not a backend check.
        var result: Result<Data, Error>?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(data: data ?? Data(), encoding: .utf8)?.prefix(300) ?? ""
                result = .failure(NSError(domain: "EmulatorAdmin", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey:
                        "emulator refused the request: HTTP \(http.statusCode)\n\(body)"
                ]))
            } else {
                result = .success(data ?? Data())
            }
            done.signal()
        }.resume()
        // A blocking wait, deliberately: XCTest's test methods are synchronous
        // and this is an out-of-band administrative call, not part of what is
        // being measured.
        _ = done.wait(timeout: .now() + 25)

        switch result {
        case .success(let data):
            let json = try? JSONSerialization.jsonObject(with: data)
            if let object = json as? [String: Any] { return object }
            if let array = json as? [Any] { return ["array": array] }
            return [:]
        case .failure(let error):
            throw error
        case nil:
            throw NSError(domain: "EmulatorAdmin", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "timed out calling \(url)"])
        }
    }

    // MARK: - Comments, read straight from Firestore

    /// Every comment in the database whose text is exactly `text`, as documents.
    ///
    /// A collection-group query, so the caller does not have to know which post
    /// the app happened to open. An exact match rather than a prefix: the point
    /// is to count, and a prefix match would fold a reply and its quote into
    /// one another.
    static func commentDocumentIDs(withExactText text: String) throws -> [String] {
        let body: [String: Any] = [
            "structuredQuery": [
                "from": [["collectionId": "comments", "allDescendants": true]],
                "where": [
                    "fieldFilter": [
                        "field": ["fieldPath": "text"],
                        "op": "EQUAL",
                        "value": ["stringValue": text],
                    ]
                ],
                "limit": 50,
            ]
        ]
        let response = try post(
            "\(firestore)/v1/projects/\(projectID)/databases/(default)/documents:runQuery",
            body: body, owner: false
        )
        guard let rows = response["array"] as? [Any] else { return [] }
        return rows.compactMap { row in
            guard let entry = row as? [String: Any],
                  let document = entry["document"] as? [String: Any],
                  let name = document["name"] as? String else { return nil }
            return name
        }
    }

    /// Deletes one comment document. Returns whether the server agreed.
    ///
    /// **`Bearer owner` is required and its absence is silent.** Reads go
    /// through without it, so this looked like it worked; the rules refuse the
    /// delete with a 403 that a fire-and-forget request never notices, and four
    /// comments were left in the shared emulator before the status code was
    /// looked at. Hence the return value, and the check in `deleteComments`.
    @discardableResult
    static func deleteComment(documentName: String) -> Bool {
        guard let url = URL(string: "\(firestore)/v1/\(documentName)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        var ok = false
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 25)
        return ok
    }

    /// Removes every comment with this text, and says what is left.
    ///
    /// The seed is shared with the other agents' runs. Adding to it is allowed;
    /// leaving rows behind changes what the next run sees, so the caller is
    /// given the chance to fail rather than to assume.
    @discardableResult
    static func deleteComments(withExactText text: String) -> [String] {
        for name in (try? commentDocumentIDs(withExactText: text)) ?? [] {
            deleteComment(documentName: name)
        }
        return (try? commentDocumentIDs(withExactText: text)) ?? []
    }

    /// The post with the most comments, as (id, text).
    ///
    /// Looked up rather than hardcoded so the paging tests describe what they
    /// need — "a post with enough comments to page" — instead of a position in
    /// the feed. The position was what broke them: the second card is below the
    /// fold, so indexing into the visible `post.comments` buttons found nothing.
    static func postWithMostComments() throws -> (id: String, text: String) {
        let body: [String: Any] = [
            "structuredQuery": [
                "from": [["collectionId": "posts"]],
                "orderBy": [[
                    "field": ["fieldPath": "commentCount"],
                    "direction": "DESCENDING",
                ]],
                "limit": 1,
            ]
        ]
        let response = try post(
            "\(firestore)/v1/projects/\(projectID)/databases/(default)/documents:runQuery",
            body: body, owner: false
        )
        guard let rows = response["array"] as? [Any],
              let entry = rows.first as? [String: Any],
              let document = entry["document"] as? [String: Any],
              let name = document["name"] as? String,
              let fields = document["fields"] as? [String: Any],
              let textField = fields["text"] as? [String: Any],
              let text = textField["stringValue"] as? String else {
            throw NSError(domain: "EmulatorAdmin", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "no posts with comments in the emulator"
            ])
        }
        return (String(name.split(separator: "/").last ?? ""), text)
    }

    // MARK: - Accounts

    /// Creates a verified account and returns its uid. Registered for cleanup.
    @discardableResult
    static func createVerifiedAccount(email: String, password: String) throws -> String {
        // Start from a clean slate: a previous run that died before tearDown
        // would otherwise leave an account this one cannot create.
        deleteAccount(email: email)
        let signUp = try post(
            "\(auth)/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key",
            body: ["email": email, "password": password, "returnSecureToken": true],
            owner: false
        )
        guard let uid = signUp["localId"] as? String else {
            throw NSError(domain: "EmulatorAdmin", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "could not create \(email): \(signUp)"
            ])
        }
        _ = try post(
            "\(auth)/identitytoolkit.googleapis.com/v1/projects/\(projectID)/accounts:update",
            body: ["localId": uid, "emailVerified": true], owner: true
        )
        createdUIDs.add(uid)
        return uid
    }

    /// Revokes a session the way §6.9 describes: from the server, with the app
    /// none the wiser until it next asks.
    ///
    /// Disabling rather than deleting, because the uid has to survive — the
    /// place the person was is only given back to the same account, so a test
    /// that deleted and recreated would be testing a different person.
    static func setAccountDisabled(uid: String, _ disabled: Bool) throws {
        _ = try post(
            "\(auth)/identitytoolkit.googleapis.com/v1/projects/\(projectID)/accounts:update",
            body: ["localId": uid, "disableUser": disabled], owner: true
        )
    }

    static func deleteAccount(uid: String) {
        _ = try? post(
            "\(auth)/identitytoolkit.googleapis.com/v1/accounts:delete",
            body: ["localId": uid], owner: true
        )
    }

    static func deleteAccount(email: String) {
        guard let listed = try? post(
            "\(auth)/identitytoolkit.googleapis.com/v1/projects/\(projectID)/accounts:query?key=fake",
            body: [:], owner: true
        ), let users = listed["userInfo"] as? [[String: Any]] else { return }
        for user in users where (user["email"] as? String) == email {
            if let uid = user["localId"] as? String { deleteAccount(uid: uid) }
        }
    }

    /// Removes only what this run added. Never touches the seeded accounts.
    static func cleanUpCreatedAccounts() {
        for uid in createdUIDs.drain() { deleteAccount(uid: uid) }
    }
}
