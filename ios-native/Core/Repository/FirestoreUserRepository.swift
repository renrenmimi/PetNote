import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OSLog

// MARK: - Temporary shared-layer definitions
//
// Three things in this file belong to the shared layer and are here only
// because the shared layer does not have them yet. Every one of them is listed
// in the handover so the coordinator can move it, and none of them is a second
// copy of something that already exists:
//
//   - `UserProfile`          → `Core/Model/User.swift`
//   - `UserRepository`       → the repository protocol file
//
// They are `TEMP-SHARED` marked so a grep finds both at once.
//
// The callable names used to be a third entry here. They are not any more:
// `Core/Backend/Callables.swift` is the registry now, and
// `CallableNameTests` reconciles it against what `functions/src` actually
// exports — so a misspelled name is a red test rather than a runtime
// `not-found` that looks like a backend being down.
//
// Two names are **deliberately absent** from that registry and must stay
// absent: `requestPasswordResetCodeCallable` and
// `confirmPasswordResetCodeCallable`. The OTP reset path is off in
// production — the three secrets it needs do not exist there — so password
// recovery goes through Firebase's own emailed link. See
// `ForgotPasswordModel`.

/// TEMP-SHARED: the user document, as the app reads it.
///
/// Mirrors `UserProfile` in src/services/users.ts, minus the fields no screen
/// in this batch reads (counters, pinned post, location). Adding those is a
/// shared-layer change, not one to make here.
struct UserProfile: Sendable, Equatable, Identifiable {
    let id: String
    var displayName: String
    var avatarURL: String
    var bio: String
    var onboardingComplete: Bool

    /// The avatar an account has before it has chosen one.
    ///
    /// Same URL the server's `getDefaultAvatar` builds
    /// (functions/src/shared.ts:822) and the same one the web client writes.
    /// Computing it differently here would give one person two different
    /// "default" faces depending on which client last wrote their profile.
    static func defaultAvatarURL(forUID uid: String) -> String {
        "https://api.dicebear.com/7.x/thumbs/svg?seed=\(uid)"
    }

    /// Decodes a `users/{uid}` document.
    ///
    /// Every field is optional on the wire and none of them is optional here.
    /// A profile mid-repair legitimately has an empty `displayName` — the web
    /// client's profile listener repairs exactly that case — so decoding must
    /// not fail on it, and the screens decide what to show for an empty name.
    static func decode(id: String, from data: [String: Any]) -> UserProfile {
        UserProfile(
            id: id,
            displayName: (data["displayName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            avatarURL: (data["avatarUrl"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            bio: data["bio"] as? String ?? "",
            // Absent means false: a document written before this field existed
            // describes an account that has not been through onboarding.
            onboardingComplete: data["onboardingComplete"] as? Bool ?? false
        )
    }

    /// What to show for this account's picture, falling back the way the web
    /// client's Avatar component does.
    var resolvedAvatarURL: String {
        avatarURL.isEmpty ? Self.defaultAvatarURL(forUID: id) : avatarURL
    }
}

/// What `updateUserProfileCallable` plus the Auth mirror actually did.
///
/// Two results, not one, and not a thrown error for the second — this is the
/// shape src/services/users.ts arrived at after the single-result version cost
/// somebody their avatar. The callable is the durable write; the Auth record is
/// a mirror used for `displayName`/`photoURL` fallbacks before the profile
/// loads. When the mirror fails the profile *is* saved, and reporting that as a
/// failed save sent the caller into a rollback that deleted the image the saved
/// profile had already started pointing at.
struct ProfileUpdateResult: Sendable, Equatable {
    /// False means: saved, but this device's cached identity may lag until the
    /// next sign-in.
    let authMirrored: Bool
}

/// What `ensureUserProfileCallable` settled on.
///
/// The server may not use the name that was asked for: it retries with a
/// numeric suffix when the reservation is taken, and it keeps an existing
/// profile's name over the requested one. The caller has to be told which name
/// the account actually has.
struct EnsuredProfile: Sendable, Equatable {
    let displayName: String
    let avatarURL: String
}

/// TEMP-SHARED: the protocol belongs beside the other repository protocols.
///
/// **Reads go to Firestore, writes go through callables** — with one
/// deliberate exception, `completeOnboarding`, documented on the method.
protocol UserRepository: Sendable {
    /// Reads `users/{uid}`. Nil when the document does not exist, which is a
    /// real state: an account exists from the moment Auth creates it, and its
    /// profile document is written a moment later.
    func profile(uid: String) async throws -> UserProfile?

    /// `ensureUserProfileCallable`. Idempotent on the server: it returns the
    /// existing profile rather than overwriting one.
    func ensureProfile(
        displayName: String?, avatarURL: String?, bio: String?, onboardingComplete: Bool
    ) async throws -> EnsuredProfile

    /// `checkDisplayNameAvailabilityCallable`, returning the `taken` half.
    func isDisplayNameTaken(_ displayName: String) async throws -> Bool

    /// `updateUserProfileCallable`, then the Auth mirror.
    func updateProfile(
        displayName: String?, avatarURL: String?, bio: String?
    ) async throws -> ProfileUpdateResult

    /// Marks onboarding finished.
    func completeOnboarding(uid: String) async throws

    /// A name nobody is using, for an account that has not chosen one.
    func generateUniqueDisplayName() async -> String
}

/// What can go wrong on the profile paths, in terms a screen can act on.
///
/// Separate from `AuthError`, which is about credentials. The two are reached
/// by different calls and need different words: "that name is taken" and "that
/// password is wrong" have nothing to do with each other.
enum ProfileError: Error, Sendable, Equatable {
    case notSignedIn
    /// The name lost a race, or belongs to somebody else. The server checks
    /// this inside the transaction, so a client-side availability check going
    /// stale between the check and the save lands here.
    case displayNameTaken
    /// The server refused the content: length, shape, an untrusted avatar host.
    /// Carries the words to show and is never worth repeating unchanged.
    case rejected(String)
    case banned
    case rateLimited
    case offline
    /// The request went out and no answer came back. **Not auto-retried**:
    /// `updateUserProfileCallable` has no idempotency key, and a display-name
    /// change that did commit would fail its own retry as "taken" — by itself.
    case outcomeUnknown
    case transport(String)

    var message: String {
        switch self {
        case .notSignedIn:
            String(localized: "Sign in to change your profile.")
        case .displayNameTaken:
            String(localized: "That name is already taken.")
        case .rejected(let reason):
            reason
        case .banned:
            String(localized: "This account cannot change its profile.")
        case .rateLimited:
            String(localized: "Too many changes just now. Wait a moment and try again.")
        case .offline:
            String(localized: "No connection. Check your network and try again.")
        case .outcomeUnknown:
            String(localized: "We could not confirm whether that saved. Reopen this screen to check.")
        case .transport:
            String(localized: "Something went wrong saving your profile. Try again.")
        }
    }

    /// Whether this failure proves the write did not happen.
    ///
    /// The question is not academic. A profile picture is uploaded to
    /// Cloudinary *before* the profile write, so when the write fails there is
    /// an image sitting on a paid CDN that nothing references. Deleting it is
    /// right only when we know for certain the profile does not point at it:
    ///
    ///   - the server **answered with a refusal** — it never ran the
    ///     transaction, so nothing committed;
    ///   - the request **never left the device** — same conclusion.
    ///
    /// `outcomeUnknown` and `transport` are the two where it may have
    /// committed, and for those the orphan stays. An unreferenced image costs
    /// storage; a saved profile pointing at a deleted image is unrecoverable,
    /// and that is the mistake the web client's EditProfile was written to
    /// avoid.
    var provesNothingCommitted: Bool {
        switch self {
        case .notSignedIn, .displayNameTaken, .rejected, .banned, .rateLimited, .offline: true
        case .outcomeUnknown, .transport: false
        }
    }

    /// Whether sending the same request again is a sensible offer.
    ///
    /// `outcomeUnknown` is false on purpose: see the case's own note.
    var isRetryable: Bool {
        switch self {
        case .offline, .rateLimited, .transport: true
        case .notSignedIn, .displayNameTaken, .rejected, .banned, .outcomeUnknown: false
        }
    }
}

// MARK: - Display names

/// The display-name rule, in one place.
///
/// Mirrors the server's `normalizeDisplayName` (functions/src/users.ts:38):
/// trimmed, 2–30 characters, **any script**. The web client used to enforce
/// ASCII-only and a letter first, which rejected names the backend accepts —
/// the comment in src/services/users.ts records that being removed, and
/// re-inventing it here would bring it back for Chinese names.
enum DisplayNameRule {
    static let minLength = 2
    static let maxLength = 30
    /// `VALIDATION_LIMITS.bio` on the server.
    static let maxBioLength = 150

    enum Problem: Equatable, Sendable {
        case tooShort
        case tooLong

        var message: String {
            switch self {
            case .tooShort: String(localized: "Name must be at least 2 characters.")
            case .tooLong: String(localized: "Name must be 30 characters or fewer.")
            }
        }
    }

    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nil when the name is fine.
    static func problem(with raw: String) -> Problem? {
        let normalized = normalize(raw)
        // Counted in Characters, not UTF-16: the server counts JavaScript
        // string length, which is UTF-16 units, and the two disagree on
        // emoji and on some CJK. Erring shorter here means the client refuses
        // a name the server would have taken, which is a worse-message
        // problem; erring longer means the server rejects a name the client
        // called valid, which is a failed save after a spinner. Neither is
        // free, and the failed save is the one that wastes a round trip.
        if normalized.count < minLength { return .tooShort }
        if normalized.utf16.count > maxLength { return .tooLong }
        return nil
    }

    static func isValid(_ raw: String) -> Bool { problem(with: raw) == nil }

    /// Whether two names are the same name as far as the reservation is
    /// concerned. The server keys reservations on `displayNameLower`, so
    /// changing only the case of your own name is not a change and must not be
    /// checked for availability — it would come back taken, by you.
    static func isSameName(_ a: String, _ b: String) -> Bool {
        normalize(a).lowercased() == normalize(b).lowercased()
    }
}

/// The random names an account gets before it picks one.
///
/// Same two word lists and the same shape as src/utils/randomName.ts, so the
/// two clients produce names from one namespace rather than two.
enum RandomDisplayName {
    static let adjectives = [
        "Happy", "Cute", "Fluffy", "Brave", "Sweet", "Lucky", "Sunny", "Cozy",
        "Gentle", "Playful", "Jolly", "Merry", "Bubbly", "Cheerful", "Sparkly",
    ]
    static let animals = [
        "Panda", "Kitten", "Bunny", "Puppy", "Fox", "Bear", "Otter", "Hamster",
        "Parrot", "Koala", "Penguin", "Dolphin", "Hedgehog", "Owl", "Corgi",
    ]

    static func make() -> String {
        let adjective = adjectives.randomElement() ?? "Happy"
        let animal = animals.randomElement() ?? "Panda"
        return "\(adjective)\(animal)\(Int.random(in: 10...99))"
    }

    /// The last-resort name, after the availability check has said "taken"
    /// ten times. Same construction as the web client's: a fresh random name
    /// with the tail of the current millisecond clock, clipped to the limit.
    static func makeWithTimeBreaker(now: Date = Date()) -> String {
        let millis = String(Int(now.timeIntervalSince1970 * 1000))
        let breaker = String(millis.suffix(4))
        return String("\(make())\(breaker)".prefix(DisplayNameRule.maxLength))
    }
}

// MARK: - Firestore + callables

/// The user profile, read from Firestore and written through callables.
///
/// The one direct write is `completeOnboarding`; its own comment says why.
actor FirestoreUserRepository: UserRepository {
    private let db: Firestore
    private let environment: AppEnvironment
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "profile")

    /// No `Functions` here on purpose: `CallableClient` owns that, and the
    /// payload it takes is `sending` — a dictionary built inside this actor
    /// has to be handed over rather than kept, which is the whole reason the
    /// shared client exists.
    init(
        db: Firestore = .firestore(),
        environment: AppEnvironment = .current
    ) {
        self.db = db
        self.environment = environment
    }

    // MARK: Reads

    func profile(uid: String) async throws -> UserProfile? {
        guard let validID = DeepLink.validDocumentID(uid) else { return nil }
        do {
            let snapshot = try await db.collection("users").document(validID).getDocument()
            guard snapshot.exists, let data = snapshot.data() else { return nil }
            return UserProfile.decode(id: snapshot.documentID, from: data)
        } catch {
            log.error("profile read failed: \(error.localizedDescription, privacy: .public)")
            throw Self.map(error)
        }
    }

    // MARK: Writes

    func ensureProfile(
        displayName: String?, avatarURL: String?, bio: String?, onboardingComplete: Bool
    ) async throws -> EnsuredProfile {
        do {
            return try await callEnsure(
                displayName: displayName, avatarURL: avatarURL,
                bio: bio, onboardingComplete: onboardingComplete
            )
        } catch let error as ProfileError where error.isRetryable || error == .outcomeUnknown {
            // One retry after a second, which is what createUserProfile in
            // src/services/users.ts does. The call is idempotent server-side,
            // so repeating it cannot create a second profile — and the profile
            // is what every later screen depends on existing.
            //
            // `outcomeUnknown` is retried here and only here: an existing
            // profile is returned rather than written again
            // (functions/src/users.ts:309-321), so an attempt that did commit
            // answers its own retry. It also keeps the 503 retry this had
            // before `.unavailable` stopped mapping to `.offline`.
            log.info("ensureUserProfile failed once; retrying after a second")
            try await Task.sleep(for: .seconds(1))
            return try await callEnsure(
                displayName: displayName, avatarURL: avatarURL,
                bio: bio, onboardingComplete: onboardingComplete
            )
        }
    }

    /// Takes the fields rather than a built payload, so the dictionary is
    /// constructed **inside** the call and handed straight over. `CallableClient`
    /// takes it as `sending`; a payload built once and passed twice — which is
    /// what the retry above would need — is precisely the shared value the
    /// compiler refuses.
    private func callEnsure(
        displayName: String?, avatarURL: String?, bio: String?, onboardingComplete: Bool
    ) async throws -> EnsuredProfile {
        try requireReachableCallables()
        do {
            // Absent, not null. `ensureUserProfileCallable` reads `"x" in data`
            // for some fields and `typeof` for others, and NSNull crosses the
            // wire as a present value of the wrong type.
            var payload: [String: Any] = ["onboardingComplete": onboardingComplete]
            if let displayName { payload["displayName"] = displayName }
            if let avatarURL { payload["avatarUrl"] = avatarURL }
            if let bio { payload["bio"] = bio }

            let data = try await CallableClient.call(Callables.ensureUserProfile, payload)
            guard let displayName = data["displayName"] as? String,
                  let avatarURL = data["avatarUrl"] as? String
            else {
                // The call succeeded and we cannot say what the profile is.
                // Not reported as success: the caller uses the returned name.
                log.error("ensureUserProfileCallable returned an unexpected shape")
                throw ProfileError.outcomeUnknown
            }
            return EnsuredProfile(displayName: displayName, avatarURL: avatarURL)
        } catch let error as ProfileError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    func isDisplayNameTaken(_ displayName: String) async throws -> Bool {
        let normalized = DisplayNameRule.normalize(displayName)
        // The server throws `invalid-argument` for an empty name. Asking is
        // a wasted round trip and a confusing error; an empty name is not a
        // name somebody else has.
        guard !normalized.isEmpty else { return false }
        try requireReachableCallables()
        do {
            let data = try await CallableClient.call(
                Callables.checkDisplayNameAvailability, ["displayName": normalized]
            )
            guard let taken = data["taken"] as? Bool else {
                log.error("checkDisplayNameAvailabilityCallable returned an unexpected shape")
                throw ProfileError.outcomeUnknown
            }
            return taken
        } catch let error as ProfileError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    func updateProfile(
        displayName: String?, avatarURL: String?, bio: String?
    ) async throws -> ProfileUpdateResult {
        guard displayName != nil || avatarURL != nil || bio != nil else {
            // The server answers `invalid-argument` for this. Saying so here
            // keeps a no-op save from looking like a server fault.
            throw ProfileError.rejected(String(localized: "There is nothing to save."))
        }
        try requireReachableCallables()

        do {
            // Built inline and handed over. Only the keys that are present are
            // sent: the callable distinguishes an absent key from a null one,
            // and sending all three would clear a bio nobody edited.
            var payload: [String: Any] = [:]
            if let displayName { payload["displayName"] = displayName }
            if let avatarURL { payload["avatarUrl"] = avatarURL }
            if let bio { payload["bio"] = bio }
            try await CallableClient.callIgnoringResult(Callables.updateUserProfile, payload)
        } catch let error as ProfileError {
            throw error
        } catch {
            throw Self.map(error)
        }

        // Past this line the durable write has committed. Nothing below may
        // throw: see `ProfileUpdateResult`.
        return ProfileUpdateResult(authMirrored: await mirrorToAuthRecord(
            displayName: displayName, avatarURL: avatarURL
        ))
    }

    /// Copies the name and picture onto the Firebase Auth record.
    ///
    /// Returns whether it worked; never throws. The Auth record is only used
    /// for the fallbacks shown before the profile document loads.
    private func mirrorToAuthRecord(displayName: String?, avatarURL: String?) async -> Bool {
        // `Auth.auth()` is read here rather than held as a property: the SDK
        // object is not Sendable, and the current user is a moving target that
        // must be sampled at the moment it is used, not at construction.
        guard let user = Auth.auth().currentUser else { return false }
        let request = user.createProfileChangeRequest()
        if let displayName { request.displayName = displayName }
        if let avatarURL { request.photoURL = URL(string: avatarURL) }
        do {
            try await request.commitChanges()
            return true
        } catch {
            log.error("auth mirror failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The one direct Firestore write on this line.
    ///
    /// `completeOnboarding` in src/services/users.ts writes
    /// `{ onboardingComplete: true }` with `merge: true`, and the rules allow
    /// exactly that: `isAllowedUserUpdate` permits `['location',
    /// 'onboardingComplete']` and nothing else, so there is no callable to go
    /// through and inventing one would be a backend change this batch is not
    /// allowed to make.
    ///
    /// `setData(merge:)` rather than `updateData` on purpose, matching the web
    /// client: `updateData` fails when the document does not exist, and the
    /// one moment this is called is the moment right after signing up.
    func completeOnboarding(uid: String) async throws {
        guard let validID = DeepLink.validDocumentID(uid) else {
            throw ProfileError.rejected(String(localized: "That account id is not usable."))
        }
        do {
            try await db.collection("users").document(validID)
                .setData(["onboardingComplete": true], merge: true)
        } catch {
            log.error("completeOnboarding failed: \(error.localizedDescription, privacy: .public)")
            throw Self.map(error)
        }
    }

    func generateUniqueDisplayName() async -> String {
        // Ten tries, then a name with the clock in it — the same budget and
        // the same fallback as generateUniqueUsername. A failed *check* ends
        // the loop rather than being retried: an offline device would
        // otherwise spend ten round trips discovering it is offline, and the
        // server assigns a unique name for an empty request anyway.
        for _ in 0..<10 {
            let candidate = RandomDisplayName.make()
            do {
                if try await isDisplayNameTaken(candidate) == false { return candidate }
            } catch {
                return candidate
            }
        }
        return RandomDisplayName.makeWithTimeBreaker()
    }

    // MARK: Failures

    /// Refuses a call this build cannot make, rather than sending it.
    ///
    /// A device pointed at a local emulator cannot attach credentials to a
    /// plaintext request to a non-loopback host, so every callable comes back
    /// `unauthenticated` — which reads as "you are signed out" and sends
    /// somebody to sign in again for something that is not about them.
    private func requireReachableCallables() throws {
        guard environment.supportsCallables else {
            log.error("callables are unreachable from this build; refusing to send")
            throw ProfileError.transport(Self.callablesUnavailable)
        }
    }

    static let callablesUnavailable = "callables-unavailable"

    /// The SDKs' own error domains, re-exported.
    ///
    /// Not indirection for its own sake: the unit-test target does not link
    /// FirebaseFunctions or FirebaseFirestore, so a test that wants to hand
    /// `map` a realistic failure would otherwise have to write the domain
    /// string out by hand — and a mapping tested against a domain the SDK no
    /// longer uses is a mapping that is not tested at all.
    static let callableErrorDomain = FunctionsErrorDomain
    static let firestoreErrorDomain = FirestoreErrorDomain

    /// Callable and Firestore failures → something a screen can say.
    ///
    /// Static and pure so it can be checked without a Firebase app behind it:
    /// the mapping is the part that decides whether somebody is told "that
    /// name is taken" or "something went wrong", and it is not observable from
    /// the outside once it is wrong.
    static func map(_ error: Error) -> ProfileError {
        if let profileError = error as? ProfileError { return profileError }
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                 NSURLErrorDataNotAllowed:
                // The request never left the device, so it certainly did not
                // commit and is safe to repeat.
                return .offline
            case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCancelled:
                // The request may have been delivered and only the answer
                // lost. Repeating it is not safe — a display-name change that
                // did commit fails its own retry as "taken", by the person who
                // made it. Same split as `FirestoreCommentRepository.map`.
                return .outcomeUnknown
            default:
                return .transport("url-\(nsError.code)")
            }
        }

        let message = (nsError.userInfo[NSLocalizedDescriptionKey] as? String)
            ?? nsError.localizedDescription

        guard let code = FunctionsErrorCode(rawValue: nsError.code),
              nsError.domain == FunctionsErrorDomain
        else {
            // Firestore's own domain, for the direct read and the one direct
            // write. Code 7 is PERMISSION_DENIED, 14 UNAVAILABLE.
            if nsError.domain == FirestoreErrorDomain {
                switch nsError.code {
                case FirestoreErrorCode.permissionDenied.rawValue:
                    return .rejected(String(localized: "You are not allowed to change that."))
                case FirestoreErrorCode.unavailable.rawValue:
                    return .offline
                default:
                    return .transport("firestore-\(nsError.code)")
                }
            }
            return .transport("\(nsError.domain)-\(nsError.code)")
        }

        switch code {
        case .unauthenticated:
            return .notSignedIn
        case .alreadyExists:
            // `assertDisplayNameAvailable` throws this, and it is the only
            // thing that does.
            return .displayNameTaken
        case .permissionDenied:
            // The callable refuses a banned account and a tombstoned one with
            // this code. The words differ, so the message is carried through.
            return message.lowercased().contains("ban") ? .banned : .rejected(message)
        case .invalidArgument, .failedPrecondition, .outOfRange:
            return .rejected(message)
        case .resourceExhausted:
            return .rateLimited
        case .deadlineExceeded, .aborted, .cancelled, .unavailable:
            // `.unavailable` is **not** `.offline`. From `call()` it is an
            // HTTP 503 that came back (FunctionsError `init(httpStatusCode:)`),
            // so the request left the device and the handler may have run —
            // and `.offline` is the one answer that licenses deleting a
            // freshly uploaded avatar. The pet, post and comment mappers all
            // read it as unknown; this one had read it as "never sent".
            return .outcomeUnknown
        default:
            return .transport("functions-\(nsError.code)")
        }
    }
}
