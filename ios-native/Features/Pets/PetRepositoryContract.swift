import Foundation

// MARK: - TEMPORARY LOCATION
//
// Two things in this file belong to the coordinator, not to this batch:
//
//   - `PetRepository` → `Core/Repository/PetRepository.swift`. The table in
//     OWNERSHIP.md gives the *protocols* to the coordinator and only
//     `FirestorePetRepository.swift` to this batch;
//   - `PetValidation` mirrors `VALIDATION_LIMITS` in functions/src/shared.ts
//     and will be wanted by other lines the moment they validate anything.
//
// Both are listed in the batch report as requests.
//
// Two things that *were* here have gone, now that the shared layer exists:
// `PetCallables` (superseded by `Core/Backend/Callables.swift`) and
// `PetAvatarUploader` (superseded by `MediaUploading` in
// `Core/Media/UploadClient.swift`). Neither is worth a second copy.

/// The client-side half of `VALIDATION_LIMITS` and the `sanitizePetDraft`
/// checks, so the form can refuse something before a round trip.
///
/// **Advisory, never authoritative.** The server validates the same things
/// again and is the only place that decides. These exist so a person is told
/// "the name is too long" while they are typing instead of after a network
/// round trip — not so the client can be trusted.
enum PetValidation {
    static let nameRange = 2...20
    static let breedLimit = 80
    static let bioLimit = 150
    static let customRelationshipLimit = 30
    /// `existingPetsSnap.size >= 5` in `createPetCallable`, counted by
    /// `ownerId` — so it is a cap on pets you are the *primary* owner of, not
    /// on pets you co-own.
    static let maxPetsPerOwner = 5

    /// Whether the name would pass `sanitizePetDraft`. Trims first, because
    /// the server trims first.
    static func isAcceptableName(_ raw: String) -> Bool {
        nameRange.contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }
}

/// What a create sends.
///
/// `relationship` is on the draft rather than the pet because it describes the
/// *creator's* place in the family, and it is written to
/// `pets/{id}/family/{uid}`, not to the pet.
struct PetDraft: Sendable, Equatable {
    var name: String
    var species: PetSpecies
    var breed: String
    var gender: PetGender
    var bio: String
    var avatarURL: String
    var birthday: Date?
    var relationship: PetFamilyRelationship
    var customRelationship: String?
}

/// What an update sends: only the fields that are present.
///
/// The callable distinguishes "field omitted, leave it alone" from "field
/// present and empty, delete it", and the birthday is the one place that
/// distinction is visible to a person: clearing the date field in the editor
/// has to actually remove the birthday, and before the explicit flag existed
/// there was no way to undo one once set.
struct PetChanges: Sendable, Equatable {
    var name: String?
    var species: PetSpecies?
    var breed: String?
    var gender: PetGender?
    var bio: String?
    var avatarURL: String?

    enum Birthday: Sendable, Equatable {
        /// Not mentioned. The server leaves the stored value alone.
        case unchanged
        case set(Date)
        /// Explicitly removed. Sends null, which is what makes the server
        /// `FieldValue.delete()` all three birthday fields.
        case cleared
    }
    var birthday: Birthday = .unchanged

    var isEmpty: Bool {
        name == nil && species == nil && breed == nil && gender == nil
            && bio == nil && avatarURL == nil && birthday == .unchanged
    }
}

/// What `deletePetCallable` reports back.
///
/// `resumed` is not decoration. The pet document is removed inside a
/// transaction and its subcollections are cleaned up afterwards, outside it;
/// if that cleanup fails the pet is already gone, so a retry finds no pet. The
/// server keeps a `petDeletionTasks` record so the retry can finish the work,
/// and answers `resumed: true` when it did. A client that showed "already
/// gone" for that case would be reporting the thing the record exists to
/// prevent.
struct PetDeletion: Sendable, Equatable {
    let resumed: Bool
}

/// One case per gate the pet callables enforce, in the order the server checks
/// them.
///
/// Distinct cases rather than one message because the recovery differs: a rate
/// limit is worth retrying in a minute, a rejected name is not worth retrying
/// at all, and an unknown outcome must not be retried automatically.
enum PetError: Error, Sendable, Equatable {
    case notSignedIn
    case banned
    /// `assertCallerAccountActive`: the account is mid-deletion
    /// (`deletionPending`) or the uid has a deletion tombstone.
    case accountDeleted
    /// `createPetCallable`: five pets counted by `ownerId`.
    case petLimitReached
    case petNotFound
    /// The caller is not in this pet's family. The wording on screen must not
    /// be "you are not the owner" — every family member is an owner, and this
    /// says the caller is not one of them.
    case notAnOwner
    /// `deletePetCallable`: the pet has other owners, so deleting it would
    /// destroy history that is not only the caller's. Leaving is the way out,
    /// and leaving is batch 3.
    case petHasOtherOwners
    case rateLimited
    /// The server refused the content itself. Carries words to show and is
    /// never retryable: the same input will be refused again.
    case rejected(String)

    /// The request went out and no answer came back.
    ///
    /// **Must not be retried automatically.** None of the pet callables has an
    /// idempotency key, so a resend of `createPetCallable` creates a second
    /// pet — and the create is the one that also burns one of the five slots.
    /// Keep the form filled in, say the outcome is uncertain, and let a
    /// reload settle it.
    case outcomeUnknown

    // No `avatarUploadFailed` case: the photo has its own vocabulary in
    // `UploadError` (Core/Media/UploadClient.swift) and the editor keeps the
    // two apart on purpose — every upload failure leaves the pet untouched,
    // which is the thing the person most needs to know and is not something a
    // pet-write error should have to carry.

    case transport(String)
}

// MARK: - Repository protocols

protocol PetRepository: Sendable {
    /// One pet document. Nil when it does not exist.
    func pet(id: String) async throws -> Pet?

    /// The pet's family, oldest join first, which is `getPetFamily`'s order
    /// (`orderBy("joinedAt","asc")`) and also the order `pickSuccessor` uses —
    /// so the roster reads in the order the role would move.
    ///
    /// Capped at `PetOwnership.familyReadLimit`, the same cap the server
    /// applies when it answers the same question.
    func family(petID: String) async throws -> [PetFamilyMember]

    /// Posts tagged with this pet, newest first, mirroring `getPostsByPet`.
    func posts(petID: String, after cursor: PageCursor?, limit: Int) async throws -> Page<Post>

    /// The pet's check-in history, through `getPetCheckinsCallable`.
    func checkins(petID: String, limit: Int) async throws -> [PetCheckin]

    /// - Returns: the new pet's id.
    func create(_ draft: PetDraft) async throws -> String
    func update(petID: String, changes: PetChanges) async throws
    func delete(petID: String) async throws -> PetDeletion
}
