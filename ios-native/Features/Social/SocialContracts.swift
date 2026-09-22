import Foundation

// MARK: - TEMPORARY LOCATION
//
// The protocol and the value types below are shared-layer material:
// `SocialRepository` belongs with the other repository protocols and the
// models in `Core/Model/`. They live here because both of those are the
// coordinator's, and this batch needed them first. Listed in the batch report.

/// A pet somebody follows, as `users/{uid}/followingPets/{petId}` stores it.
///
/// The name and picture are a snapshot `followPetCallable` took at follow
/// time, so they can lag the pet's own profile. Good enough for a list whose
/// rows open the pet's page, which reads the live document.
struct FollowedPet: Sendable, Equatable, Identifiable {
    /// The document id, which is the pet id.
    let id: String
    let petName: String
    let petAvatarURL: URL?
    let followedAt: Date?
}

/// One follower of a pet, from the `pets/{id}/followers/{uid}` mirror that
/// `onFollowingPetCreated` writes. World-readable, unlike the follower's own
/// `followingPets`, which only its owner may read.
struct PetFollower: Sendable, Equatable, Identifiable {
    /// The document id, which is the follower's uid.
    let id: String
    let userName: String
    let userAvatarURL: URL?
    let followedAt: Date?
}

/// Anybody's profile, as anyone may read it (`users/{uid}` is `read: if true`).
///
/// Separate from `UserProfile` (Core/Repository/FirestoreUserRepository.swift)
/// because that one is the signed-in person's editable profile and carries
/// none of the fields another person's page shows: the counter, the city, the
/// join date. Adding them there is a change to a file this batch does not own.
struct PublicProfile: Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let avatarURL: URL?
    let bio: String
    let city: String
    let state: String
    /// Trigger-maintained. Nil when the document has never had one, which is
    /// different from zero only for the person themself — the web page falls
    /// back to the length of their own following list in that case.
    let followingPetsCount: Int?
    let createdAt: Date?
}

/// A pet on somebody's profile, with that person's place in its family.
struct ProfilePet: Sendable, Equatable, Identifiable {
    var id: String { pet.id }
    let pet: Pet
    let relationship: PetFamilyRelationship
    let customRelationship: String?
    let role: PetFamilyRole
}

/// One case per gate `followPetCallable` / `unfollowPetCallable` enforce, plus
/// the ways a read can fail.
enum SocialError: Error, Sendable, Equatable {
    case notSignedIn
    case banned
    /// `assertCallerAccountActive`: the account is deleted or being deleted.
    case accountDeleted
    case petNotFound
    /// `failed-precondition` "You can't follow your own pet." The server
    /// refuses a follow from anyone in the pet's family, or named in
    /// `ownerId`/`primaryOwnerId`, so their follow cannot inflate the counts.
    case ownPet
    case rateLimited
    /// A read or a direct write the rules refused.
    case denied
    /// The request never left the device.
    case offline
    /// This build cannot reach the callables at all (a device pointed at a
    /// local emulator over plain HTTP).
    case callablesUnavailable
    /// The request may have been delivered and the answer lost.
    ///
    /// Following is idempotent on the server — `followPetCallable` returns
    /// early when the follow document already exists, and unfollow deletes
    /// only if present — so the recovery is to *read* what is true now, not
    /// to guess.
    case outcomeUnknown
    case transport(String)
}

/// Reads for the social surfaces, and the two follow writes.
///
/// **Writes to pets, families and followers go through callables only.**
/// `firestore.rules` refuses every client create/update/delete under
/// `pets/**`, and `users/{uid}/followingPets` refuses create outright. The one
/// direct write here is `unblock`, whose collection the rules do open to its
/// owner, and which is exactly what the web page does.
protocol SocialRepository: Sendable {
    func follow(petID: String) async throws
    func unfollow(petID: String) async throws

    /// `users/{viewer}/followingPets/{petId}` exists. Owner-only by rule.
    func isFollowing(petID: String, viewerID: String) async throws -> Bool
    /// Batched, ten ids per query, as `batchCheckFollowingPets` does.
    func followedPetIDs(among petIDs: [String], viewerID: String) async throws -> Set<String>
    /// Newest first, as `getFollowingPets` does. Owner-only by rule.
    func followedPets(viewerID: String, limit: Int) async throws -> [FollowedPet]
    /// Newest first, as `getPetFollowers` does.
    func followers(petID: String, after cursor: PageCursor?, limit: Int) async throws -> Page<PetFollower>

    /// Whether `pets/{petId}/family/{uid}` exists. World-readable.
    func isFamilyMember(petID: String, userID: String) async throws -> Bool
    /// Every pet this person is in the family of — one collection-group read,
    /// then the pet documents in batches, as `getUserPets` does.
    func pets(ofUser userID: String) async throws -> [ProfilePet]
    /// Just the ids, for deciding which follow buttons would be refused.
    func memberPetIDs(userID: String) async throws -> Set<String>

    /// Nil when the document does not exist.
    func profile(userID: String) async throws -> PublicProfile?

    /// `users/{viewer}/blockedUsers`, owner-only by rule.
    func blockedUserIDs(viewerID: String) async throws -> Set<String>
    func unblock(userID: String, viewerID: String) async throws
}

/// Pure decoding for the documents above, so the normalization rules are
/// testable without Firebase.
enum SocialDecoder {
    static func followedPet(id: String, from data: [String: Any]) -> FollowedPet? {
        guard !id.isEmpty else { return nil }
        return FollowedPet(
            id: id,
            petName: nonEmpty(data["petName"]) ?? "Pet",
            petAvatarURL: PetDecoder.url(data["petAvatar"]),
            followedAt: (data["followedAt"] as? PostDate)?.postDate
        )
    }

    static func follower(id: String, from data: [String: Any]) -> PetFollower? {
        guard !id.isEmpty else { return nil }
        return PetFollower(
            id: id,
            userName: nonEmpty(data["userName"]) ?? "PetNote User",
            userAvatarURL: PetDecoder.url(data["userAvatar"]),
            followedAt: (data["followedAt"] as? PostDate)?.postDate
        )
    }

    static func profile(id: String, from data: [String: Any]) -> PublicProfile {
        let location = data["location"] as? [String: Any]
        return PublicProfile(
            id: id,
            displayName: nonEmpty(data["displayName"]) ?? "",
            avatarURL: PetDecoder.url(data["avatarUrl"]),
            bio: (data["bio"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            city: nonEmpty(location?["city"]) ?? "",
            state: nonEmpty(location?["state"]) ?? "",
            followingPetsCount: data["followingPetsCount"].map { PetDecoder.count($0) },
            createdAt: (data["createdAt"] as? PostDate)?.postDate
        )
    }

    /// The family half of a profile pet. Mirrors `PetDecoder.familyMember`'s
    /// reading of `role`: only the literal `"primary"` promotes.
    static func profilePet(pet: Pet, family data: [String: Any]) -> ProfilePet {
        let relationship =
            PetFamilyRelationship(rawValue: (data["relationship"] as? String) ?? "") ?? .other
        return ProfilePet(
            pet: pet,
            relationship: relationship,
            customRelationship: relationship == .other ? nonEmpty(data["customRelationship"]) : nil,
            role: (data["role"] as? String) == PetFamilyRole.primary.rawValue ? .primary : .member
        )
    }

    static func nonEmpty(_ raw: Any?) -> String? {
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Splits ids into the batches a Firestore `in` filter is sent in.
///
/// Ten, as the web client's `DOCUMENT_ID_BATCH_SIZE`. Duplicates and empty ids
/// are dropped first so a repeated pet does not cost a slot in a batch.
enum IDBatches {
    static let size = 10

    static func make(_ ids: [String], size: Int = IDBatches.size) -> [[String]] {
        var seen: Set<String> = []
        let unique = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        return stride(from: 0, to: unique.count, by: size).map {
            Array(unique[$0..<min($0 + size, unique.count)])
        }
    }
}
