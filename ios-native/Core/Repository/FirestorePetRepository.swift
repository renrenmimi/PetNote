import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OSLog

/// Pets: read straight from Firestore, write only through the callables.
///
/// Not a style choice — `firestore.rules` line 393 is
///
///     match /pets/{petId} {
///       allow read: if true;
///       allow create: if false;
///       allow update: if false;
///       allow delete: if false;
///       …
///     }
///
/// so a direct write is refused, and going around the callables would skip
/// every gate behind them: the ban check, the account-deletion tombstone, the
/// rate limit, the five-pet cap counted inside a transaction, the family-based
/// authority check, and the "are you the last owner?" test that stands between
/// one person and everybody else's shared history.
///
/// Check-ins are the one **read** that goes through a callable, for a reason
/// worth not undoing: the `checkins` collection group is closed because, left
/// open, it answered "every check-in matching a filter" — a person's whole
/// movement timeline, to an unauthenticated caller, servable from an index
/// that exists. Closing only the `userId` path would have been theatre, since
/// `pets/{petId}` is world-readable and carries `ownerId`.
///
/// An actor because it owns the `DocumentSnapshot`s the opaque page cursors
/// stand for, the same arrangement as `FirestoreFeedRepository`.
actor FirestorePetRepository: PetRepository {
    private let db: Firestore
    private let functions: Functions
    private let environment: AppEnvironment
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "pet")

    /// Cursor → the document to resume after. Cleared whenever a fresh first
    /// page is requested, so it cannot grow without bound across a session.
    private var resumePoints: [PageCursor: DocumentSnapshot] = [:]

    init(
        db: Firestore = .firestore(),
        functions: Functions = .functions(),
        environment: AppEnvironment = .current
    ) {
        self.db = db
        self.functions = functions
        self.environment = environment
    }

    // MARK: - Reads

    func pet(id: String) async throws -> Pet? {
        guard let validID = DeepLink.validDocumentID(id) else { return nil }
        let document = try await db.collection("pets").document(validID).getDocument()
        guard document.exists, let data = document.data() else { return nil }
        return PetDecoder.pet(id: document.documentID, from: data)
    }

    func family(petID: String) async throws -> [PetFamilyMember] {
        guard let validID = DeepLink.validDocumentID(petID) else { return [] }
        let snapshot = try await db.collection("pets").document(validID)
            .collection("family")
            .order(by: "joinedAt")
            .limit(to: PetOwnership.familyReadLimit)
            .getDocuments()
        let members = snapshot.documents.compactMap {
            PetDecoder.familyMember(id: $0.documentID, from: $0.data())
        }
        if members.count != snapshot.documents.count {
            // An undecodable family document is not cosmetic: `memberCount` is
            // what decides whether this pet may be deleted, and a dropped row
            // understates it. Loud, even though the read still returns.
            log.error("dropped \(snapshot.documents.count - members.count) family document(s)")
        }
        return members
    }

    func posts(petID: String, after cursor: PageCursor?, limit: Int) async throws -> Page<Post> {
        guard let validID = DeepLink.validDocumentID(petID) else { return .empty }
        if cursor == nil { resumePoints.removeAll() }

        var query: Query = db.collection("posts")
            .whereField("petId", isEqualTo: validID)
            .order(by: "createdAt", descending: true)
            .limit(to: limit)
        if let cursor {
            guard let resume = resumePoints[cursor] else {
                // A cursor this repository did not issue, or one from a
                // session that has been torn down. Starting over beats
                // guessing.
                log.error("unknown pet-posts cursor; restarting from the first page")
                return try await posts(petID: petID, after: nil, limit: limit)
            }
            query = query.start(afterDocument: resume)
        }

        let snapshot = try await query.getDocuments()
        let posts = snapshot.documents.compactMap {
            PostDecoder.post(id: $0.documentID, from: $0.data())
        }

        // `hasMore` is "the page came back full", exactly as the web client
        // has it, and exactly as the feed repository does.
        var next: PageCursor?
        if snapshot.documents.count == limit, let last = snapshot.documents.last {
            let token = PageCursor()
            resumePoints[token] = last
            next = token
        }
        return Page(items: posts, next: next)
    }

    func checkins(petID: String, limit: Int) async throws -> [PetCheckin] {
        guard let validID = DeepLink.validDocumentID(petID) else { return [] }
        let payload: [String: Any] = ["petId": validID, "limitCount": limit]
        let data = try await call(Callables.getPetCheckins, payload, as: .read)
        guard let rows = data["checkins"] as? [[String: Any]] else {
            // The call succeeded and the shape is not what the contract says.
            // A read, so this is safe to report as a failure rather than as an
            // unknown outcome.
            log.error("getPetCheckinsCallable returned an unexpected shape")
            throw PetError.transport("checkins-shape")
        }
        return rows.compactMap(PetDecoder.checkin(from:))
    }

    // MARK: - Writes

    func create(_ draft: PetDraft) async throws -> String {
        var payload: [String: Any] = [
            "name": draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            "species": draft.species.rawValue,
            "breed": draft.breed.trimmingCharacters(in: .whitespacesAndNewlines),
            "gender": draft.gender.rawValue,
            "bio": draft.bio.trimmingCharacters(in: .whitespacesAndNewlines),
            "avatarUrl": draft.avatarURL,
            "relationship": draft.relationship.rawValue,
        ]
        if draft.relationship == .other,
           let custom = draft.customRelationship?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            payload["customRelationship"] = custom
        }
        if let birthday = draft.birthday {
            payload.merge(Self.birthdayFields(for: birthday)) { current, _ in current }
        }

        let data = try await call(Callables.createPet, payload, as: .create)
        guard let id = data["id"] as? String, !id.isEmpty else {
            // The call succeeded but we cannot point at the pet it made.
            // Unknown, not success: there may now be a pet, and a retry would
            // make a second one.
            log.error("createPetCallable returned an unexpected shape")
            throw PetError.outcomeUnknown
        }
        return id
    }

    func update(petID: String, changes: PetChanges) async throws {
        guard let validID = DeepLink.validDocumentID(petID) else { throw PetError.petNotFound }
        var payload: [String: Any] = ["petId": validID]
        if let name = changes.name {
            payload["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let species = changes.species { payload["species"] = species.rawValue }
        if let breed = changes.breed {
            payload["breed"] = breed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let gender = changes.gender { payload["gender"] = gender.rawValue }
        if let bio = changes.bio {
            payload["bio"] = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let avatarURL = changes.avatarURL { payload["avatarUrl"] = avatarURL }

        switch changes.birthday {
        case .unchanged:
            break
        case .set(let date):
            payload.merge(Self.birthdayFields(for: date)) { current, _ in current }
        case .cleared:
            // Explicit nulls, all three. The callable branches on the *keys*
            // being present and then on `birthdayMillis` being unusable, which
            // is what turns them into `FieldValue.delete()`. Omitting them
            // would mean "leave the birthday alone", and there would again be
            // no way to undo one.
            payload["birthdayMillis"] = NSNull()
            payload["birthdayMonth"] = NSNull()
            payload["birthdayDay"] = NSNull()
        }

        // Guarded here as well as in the editor: the callable answers
        // `invalid-argument` for an update with no supported fields, and
        // spending a round trip and a rate-limit slot to be told that is
        // waste.
        guard payload.count > 1 else {
            throw PetError.rejected("Nothing was changed.")
        }
        _ = try await call(Callables.updatePet, payload, as: .update)
    }

    func delete(petID: String) async throws -> PetDeletion {
        guard let validID = DeepLink.validDocumentID(petID) else { throw PetError.petNotFound }
        let data = try await call(Callables.deletePet, ["petId": validID], as: .delete)
        return PetDeletion(resumed: (data["resumed"] as? Bool) ?? false)
    }

    // MARK: - Calling

    /// Which callable is being answered for, because the server reuses two
    /// status codes across three different meanings.
    enum Operation: Sendable {
        case create
        case update
        case delete
        case read
    }

    /// Every callable goes through `CallableClient`, never through
    /// `functions.httpsCallable(_:).call(_:)` directly.
    ///
    /// Not a style preference — the direct form does not compile under
    /// `SWIFT_STRICT_CONCURRENCY = complete`. `[String: Any]` is not
    /// `Sendable`, and a dictionary built inside this actor belongs to this
    /// actor, so handing it to a `@concurrent` method is a data race the
    /// compiler is right about. `CallableClient` takes the payload as
    /// `sending`, which says the caller gives it up and has the compiler check
    /// that it did.
    ///
    /// The payload is therefore built at each call site and passed straight
    /// through. It must not be stored on the way.
    private func call(
        _ name: String, _ payload: sending [String: Any], as operation: Operation
    ) async throws -> [String: Any] {
        // Known in advance for a device pointed at a local emulator: the
        // Functions SDK will not attach an auth token to a plaintext request
        // bound for a non-loopback host, so the request never leaves. Refused
        // here rather than sent and misreported as a sign-in problem.
        guard environment.supportsCallables else {
            log.error("callables are unreachable from this build; refusing to send \(name, privacy: .public)")
            throw PetError.transport(CallableTransport.unavailable)
        }
        do {
            return try await CallableClient.call(name, payload, functions: functions)
        } catch {
            let nsError = error as NSError
            log.error("""
                \(name, privacy: .public) failed: \
                domain=\(nsError.domain, privacy: .public) code=\(nsError.code) \
                desc=\(nsError.localizedDescription, privacy: .public)
                """)
            throw Self.map(error, for: operation)
        }
    }

    /// Detail strings carried by `PetError.transport`.
    ///
    /// `unavailable` and the SDK's plaintext-refusal message come from
    /// `CallableTransport`, which already holds both facts for the upload path.
    /// `offline` is this file's own because the pet callables draw a line the
    /// upload path does not have to: a request that never left the device
    /// created nothing and is safe to repeat, and `createPetCallable` has no
    /// idempotency key — so "certain failure" and "unknown outcome" have to
    /// stay separable here.
    enum Transport {
        /// The request never left the device, so nothing was created and
        /// repeating it cannot duplicate anything.
        static let offline = "offline"
        /// This build cannot reach the callables at all.
        static let unavailable = CallableTransport.unavailable
    }

    /// The SDK's own words when it refuses to attach tokens. Matched because
    /// the code it throws — `unauthenticated` — is the same one a genuinely
    /// signed-out caller gets, and the two need opposite handling.
    private static let plaintextTokenRefusal = CallableTransport.plaintextTokenRefusal

    /// URL errors that mean nothing was ever put on the wire.
    ///
    /// Explicit rather than "any NSURLError", and the exclusions are the
    /// point: `networkConnectionLost` (-1005), `timedOut` (-1001) and
    /// `cancelled` (-999) are all *ambiguous* — the request may have been
    /// delivered and only the answer lost — and for `createPetCallable`, which
    /// has no idempotency key, treating an ambiguous failure as "nothing
    /// happened" is how somebody ends up with two pets and one of their five
    /// slots gone.
    private static let neverSentURLErrorCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorDataNotAllowed,
        NSURLErrorCallIsActive,
        NSURLErrorSecureConnectionFailed,
    ]

    /// Maps a callable failure onto the gates in functions/src/pets.ts.
    ///
    /// The operation has to be passed in because the server overloads two
    /// codes:
    ///
    ///   - **`failed-precondition`** is "this account has been deleted"
    ///     (every callable), "Maximum 5 pets allowed" (create), and "this pet
    ///     has other owners" (delete);
    ///   - **`permission-denied`** is "banned" (every callable) and "cannot
    ///     update/delete this pet" (the family-authority check).
    ///
    /// Message matching is used only where the code alone cannot separate
    /// them, and the operation narrows it first so a wording change on the
    /// server degrades to a sensible case rather than to the wrong one.
    static func map(_ error: Error, for operation: Operation) -> PetError {
        if let already = error as? PetError { return already }
        let nsError = error as NSError

        guard nsError.domain == FunctionsErrorDomain,
              let code = FunctionsErrorCode(rawValue: nsError.code) else {
            // The Functions SDK only rewrites two kinds of failure into its
            // own domain, so a plain "not connected to the internet" arrives
            // here in NSURLErrorDomain. It is not an unknown outcome: the
            // request never went out.
            if nsError.domain == NSURLErrorDomain,
               neverSentURLErrorCodes.contains(nsError.code) {
                return .transport(Transport.offline)
            }
            return .outcomeUnknown
        }
        let message = nsError.localizedDescription.lowercased()

        switch code {
        case .unauthenticated:
            if message.contains(plaintextTokenRefusal) {
                return .transport(Transport.unavailable)
            }
            return .notSignedIn

        case .permissionDenied:
            if message.contains("banned") { return .banned }
            // Everything else the pet callables raise with this code is the
            // family-authority check. There is no block-based denial on a pet.
            return .notAnOwner

        case .failedPrecondition:
            // Both halves of `assertCallerAccountActive` refuse with this code
            // before any pet-specific check runs (functions/src/
            // notifications.ts:112-156): `assertActorNotDeleting` while a
            // deletion is in progress — which `deleteUserAccount` leaves set,
            // Auth intact, when a cleanup step fails — and the tombstone after
            // it. Both have to be recognised here, or a deleting account is
            // told it already has five pets.
            if message.contains("account has been deleted")
                || message.contains("account deletion is in progress") {
                return .accountDeleted
            }
            switch operation {
            case .create:
                return .petLimitReached
            case .delete:
                return .petHasOtherOwners
            case .update, .read:
                return .rejected(Self.refusalWording)
            }

        case .notFound:
            return .petNotFound

        case .resourceExhausted:
            return .rateLimited

        case .invalidArgument, .outOfRange:
            return .rejected(Self.refusalWording)

        case .deadlineExceeded, .unavailable, .cancelled, .aborted, .internal:
            // No answer, or an answer we cannot trust. For a create this is
            // the branch that must never auto-retry.
            return .outcomeUnknown

        default:
            // The numeric code, not the SDK's message: that text is not ours
            // to show and is only ever used for logs.
            return .transport("functions/\(code.rawValue)")
        }
    }

    /// One wording for every content refusal, because the server's own message
    /// is not written for a person and is not ours to show.
    private static let refusalWording =
        "That was not accepted. Check the name, breed and bio and try again."

    // MARK: - Birthday

    /// The three fields a birthday is sent as.
    ///
    /// **Month and day are the viewer's *local* components, on purpose.** The
    /// picker hands back local midnight on the chosen day; deriving the pair
    /// from UTC would lose a day for anyone east of Greenwich (a UTC+14 user
    /// picking "1 June" produces an instant whose UTC fields say 31 May). The
    /// server only derives them itself when the client does not send them, and
    /// its own comment says the client's are preferred for exactly this
    /// reason.
    ///
    /// `birthdayMillis` still goes along, because the pet document keeps the
    /// legacy timestamp for the "Born: …" line.
    static func birthdayFields(
        for date: Date, calendar: Calendar = .current
    ) -> [String: Any] {
        let parts = calendar.dateComponents([.month, .day], from: date)
        var fields: [String: Any] = [
            "birthdayMillis": Int(date.timeIntervalSince1970 * 1000),
        ]
        if let month = parts.month, let day = parts.day {
            fields["birthdayMonth"] = month
            fields["birthdayDay"] = day
        }
        return fields
    }
}
