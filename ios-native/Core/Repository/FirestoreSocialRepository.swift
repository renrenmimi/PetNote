import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OSLog

/// Follows, followers, other people's profiles, and the pets on them.
///
/// Reads go straight to Firestore. The two follow writes go through
/// `followPetCallable` / `unfollowPetCallable`: `users/{uid}/followingPets`
/// refuses a client create outright, and the callable is what refuses a follow
/// from one of the pet's own owners — the check that keeps `followerCount`
/// honest. `pets/*/followers` is a server-written mirror and is read-only.
///
/// The rules *do* let the owner delete their own `followingPets` document, and
/// the web client never uses that: it unfollows through the callable. So does
/// this, so there is one path and the server's gates stay in front of it.
actor FirestoreSocialRepository: SocialRepository {
    private let db: Firestore
    private let functions: Functions
    private let environment: AppEnvironment
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "social")

    /// Cursor → the document to resume after, for the followers list. Cleared
    /// on every first page so it cannot grow across a session.
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

    // MARK: - Follow writes

    func follow(petID: String) async throws {
        guard let validID = DeepLink.validDocumentID(petID) else { throw SocialError.petNotFound }
        try requireCallables(Callables.followPet)
        do {
            try await CallableClient.callIgnoringResult(
                Callables.followPet, ["petId": validID], functions: functions
            )
        } catch {
            log.error("followPet failed: \(String(describing: error), privacy: .public)")
            throw Self.mapCallable(error)
        }
    }

    func unfollow(petID: String) async throws {
        guard let validID = DeepLink.validDocumentID(petID) else { throw SocialError.petNotFound }
        try requireCallables(Callables.unfollowPet)
        do {
            try await CallableClient.callIgnoringResult(
                Callables.unfollowPet, ["petId": validID], functions: functions
            )
        } catch {
            log.error("unfollowPet failed: \(String(describing: error), privacy: .public)")
            throw Self.mapCallable(error)
        }
    }

    // MARK: - Follow reads

    func isFollowing(petID: String, viewerID: String) async throws -> Bool {
        guard let pet = DeepLink.validDocumentID(petID),
              let viewer = DeepLink.validDocumentID(viewerID) else { return false }
        return try await read {
            try await db.collection("users").document(viewer)
                .collection("followingPets").document(pet)
                .getDocument().exists
        }
    }

    func followedPetIDs(among petIDs: [String], viewerID: String) async throws -> Set<String> {
        guard let viewer = DeepLink.validDocumentID(viewerID) else { return [] }
        let valid = petIDs.compactMap(DeepLink.validDocumentID)
        var followed: Set<String> = []
        for batch in IDBatches.make(valid) {
            let snapshot = try await read {
                try await db.collection("users").document(viewer)
                    .collection("followingPets")
                    .whereField(FieldPath.documentID(), in: batch)
                    .getDocuments()
            }
            for document in snapshot.documents { followed.insert(document.documentID) }
        }
        return followed
    }

    func followedPets(viewerID: String, limit: Int) async throws -> [FollowedPet] {
        guard let viewer = DeepLink.validDocumentID(viewerID) else { return [] }
        let snapshot = try await read {
            try await db.collection("users").document(viewer)
                .collection("followingPets")
                .order(by: "followedAt", descending: true)
                .limit(to: limit)
                .getDocuments()
        }
        return snapshot.documents.compactMap {
            SocialDecoder.followedPet(id: $0.documentID, from: $0.data())
        }
    }

    func followers(petID: String, after cursor: PageCursor?, limit: Int) async throws -> Page<PetFollower> {
        guard let pet = DeepLink.validDocumentID(petID) else { return .empty }
        if cursor == nil { resumePoints.removeAll() }

        var query: Query = db.collection("pets").document(pet)
            .collection("followers")
            .order(by: "followedAt", descending: true)
            .limit(to: limit)
        if let cursor {
            guard let resume = resumePoints[cursor] else {
                log.error("unknown followers cursor; restarting from the first page")
                return try await followers(petID: petID, after: nil, limit: limit)
            }
            query = query.start(afterDocument: resume)
        }
        let finalQuery = query
        let snapshot = try await read { try await finalQuery.getDocuments() }
        let followers = snapshot.documents.compactMap {
            SocialDecoder.follower(id: $0.documentID, from: $0.data())
        }
        var next: PageCursor?
        if snapshot.documents.count == limit, let last = snapshot.documents.last {
            let token = PageCursor()
            resumePoints[token] = last
            next = token
        }
        return Page(items: followers, next: next)
    }

    // MARK: - Membership

    func isFamilyMember(petID: String, userID: String) async throws -> Bool {
        guard let pet = DeepLink.validDocumentID(petID),
              let user = DeepLink.validDocumentID(userID) else { return false }
        return try await read {
            try await db.collection("pets").document(pet)
                .collection("family").document(user)
                .getDocument().exists
        }
    }

    func pets(ofUser userID: String) async throws -> [ProfilePet] {
        guard let user = DeepLink.validDocumentID(userID) else { return [] }
        let familySnapshot = try await read {
            try await db.collectionGroup("family")
                .whereField("userId", isEqualTo: user)
                .getDocuments()
        }
        // Pet id → this person's family document, in the order the index
        // returned them. The order is kept so the list does not reshuffle
        // between visits.
        var order: [String] = []
        var familyByPet: [String: [String: Any]] = [:]
        for document in familySnapshot.documents {
            guard let petID = document.reference.parent.parent?.documentID,
                  familyByPet[petID] == nil else { continue }
            order.append(petID)
            familyByPet[petID] = document.data()
        }

        var pets: [String: Pet] = [:]
        for batch in IDBatches.make(order) {
            let snapshot = try await read {
                try await db.collection("pets")
                    .whereField(FieldPath.documentID(), in: batch)
                    .getDocuments()
            }
            for document in snapshot.documents {
                if let pet = PetDecoder.pet(id: document.documentID, from: document.data()) {
                    pets[pet.id] = pet
                }
            }
        }
        // A family document whose pet is gone is a cascade still in flight;
        // it is not a pet this person has, so it is not shown.
        return order.compactMap { petID in
            guard let pet = pets[petID], let family = familyByPet[petID] else { return nil }
            return SocialDecoder.profilePet(pet: pet, family: family)
        }
    }

    func memberPetIDs(userID: String) async throws -> Set<String> {
        guard let user = DeepLink.validDocumentID(userID) else { return [] }
        let snapshot = try await read {
            try await db.collectionGroup("family")
                .whereField("userId", isEqualTo: user)
                .getDocuments()
        }
        return Set(snapshot.documents.compactMap { $0.reference.parent.parent?.documentID })
    }

    // MARK: - Profiles

    func profile(userID: String) async throws -> PublicProfile? {
        guard let user = DeepLink.validDocumentID(userID) else { return nil }
        let snapshot = try await read {
            try await db.collection("users").document(user).getDocument()
        }
        guard snapshot.exists, let data = snapshot.data() else { return nil }
        return SocialDecoder.profile(id: snapshot.documentID, from: data)
    }

    // MARK: - Blocks

    func blockedUserIDs(viewerID: String) async throws -> Set<String> {
        guard let viewer = DeepLink.validDocumentID(viewerID) else { return [] }
        let snapshot = try await read {
            try await db.collection("users").document(viewer)
                .collection("blockedUsers")
                .getDocuments()
        }
        return Set(snapshot.documents.map(\.documentID))
    }

    /// The web page's `unblockUser`: a direct delete, which the rules allow the
    /// owner when not banned and not mid-deletion.
    func unblock(userID: String, viewerID: String) async throws {
        guard let user = DeepLink.validDocumentID(userID),
              let viewer = DeepLink.validDocumentID(viewerID) else { throw SocialError.denied }
        try await read {
            try await db.collection("users").document(viewer)
                .collection("blockedUsers").document(user)
                .delete()
        }
    }

    // MARK: - Plumbing

    private func requireCallables(_ name: String) throws {
        guard environment.supportsCallables else {
            log.error("callables are unreachable from this build; refusing to send \(name, privacy: .public)")
            throw SocialError.callablesUnavailable
        }
    }

    /// Runs a Firestore operation and maps its failure onto `SocialError`.
    private func read<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            log.error("social read failed: \(String(describing: error), privacy: .public)")
            throw Self.mapFirestore(error)
        }
    }

    /// Firestore failures on a read or a rule-checked write.
    static func mapFirestore(_ error: Error) -> SocialError {
        if let already = error as? SocialError { return already }
        let nsError = error as NSError
        guard nsError.domain == FirestoreErrorDomain else {
            return CallableFailure.neverSent(nsError) ? .offline : .transport(nsError.domain)
        }
        switch FirestoreErrorCode.Code(rawValue: nsError.code) {
        case .permissionDenied: return .denied
        case .unauthenticated: return .notSignedIn
        case .unavailable: return .offline
        default: return .transport("firestore/\(nsError.code)")
        }
    }

    /// `followPetCallable` / `unfollowPetCallable` failures.
    static func mapCallable(_ error: Error) -> SocialError {
        if let already = error as? SocialError { return already }
        switch CallableFailure.classify(error) {
        case .neverSent: return .offline
        case .unavailable: return .callablesUnavailable
        case .unknownOutcome: return .outcomeUnknown
        case .server(let code, let message):
            switch code {
            case .unauthenticated: return .notSignedIn
            case .permissionDenied:
                return message.contains("banned") ? .banned : .denied
            case .failedPrecondition:
                if CallableFailure.isAccountDeletion(message) { return .accountDeleted }
                // The only other failed-precondition either follow callable
                // raises is "You can't follow your own pet."
                return .ownPet
            case .notFound: return .petNotFound
            case .resourceExhausted: return .rateLimited
            case .invalidArgument: return .petNotFound
            default: return .transport("functions/\(code.rawValue)")
            }
        }
    }
}

/// How a callable failed, before any one callable decides what that means.
///
/// Shared by the social, family and search repositories so the line between
/// "never sent", "sent and unanswered" and "answered with a refusal" is drawn
/// once. It is the line that decides whether a retry is safe.
enum CallableFailure: Equatable {
    /// The request never left the device. Nothing happened on the server.
    case neverSent
    /// This build cannot reach the callables at all.
    case unavailable
    /// The request may have been delivered; the answer did not arrive.
    case unknownOutcome
    /// The server answered with an `HttpsError`. `message` is lowercased and
    /// is for classification only — it is not written for a person and is
    /// never shown.
    case server(FunctionsErrorCode, message: String)

    /// URL errors that mean nothing was put on the wire. The exclusions are
    /// the point: `timedOut`, `networkConnectionLost` and `cancelled` are
    /// ambiguous, because the request may have been delivered.
    static let neverSentURLErrorCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorDataNotAllowed,
        NSURLErrorCallIsActive,
        NSURLErrorSecureConnectionFailed,
    ]

    static func neverSent(_ error: NSError) -> Bool {
        error.domain == NSURLErrorDomain && neverSentURLErrorCodes.contains(error.code)
    }

    static func classify(_ error: Error) -> CallableFailure {
        let nsError = error as NSError
        guard nsError.domain == FunctionsErrorDomain,
              let code = FunctionsErrorCode(rawValue: nsError.code) else {
            return neverSent(nsError) ? .neverSent : .unknownOutcome
        }
        let message = nsError.localizedDescription.lowercased()
        switch code {
        case .unauthenticated where message.contains(CallableTransport.plaintextTokenRefusal):
            return .unavailable
        case .deadlineExceeded, .unavailable, .cancelled, .aborted, .internal, .unknown:
            return .unknownOutcome
        default:
            return .server(code, message: message)
        }
    }

    /// `assertActorNotDeleting` ("Account deletion is in progress.") and
    /// `assertCallerAccountActive` ("This account has been deleted."). Every
    /// mutating callable raises one of the two as `failed-precondition`, so it
    /// has to be recognised before an operation's own meaning of that code.
    static func isAccountDeletion(_ message: String) -> Bool {
        message.contains("account has been deleted") || message.contains("account deletion")
    }
}
