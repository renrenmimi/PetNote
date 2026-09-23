import Foundation
import Observation
import OSLog

/// Adding a pet and editing one, which are the same form.
///
/// They are one object for the reason the web client made them one component:
/// the fields, the limits and the photo handling are identical, and two copies
/// drift. What is *not* shared is spelled out as `Mode`, because the two
/// differ in ways that matter — a create picks a relationship and can hit the
/// five-pet cap; an edit has to be able to *clear* a birthday, and has to
/// check that this person is allowed to edit at all before showing them a form
/// whose Save can only be refused.
@MainActor
@Observable
final class PetEditorViewModel {
    enum Mode: Equatable {
        case create
        case edit(petID: String)

        var petID: String? {
            if case .edit(let id) = self { return id }
            return nil
        }
        var isEdit: Bool { petID != nil }
    }

    enum LoadState: Equatable {
        case ready
        case loading
        /// Editing something that is not there. A blank form here would let
        /// Save target a document that does not exist.
        case missing
        case failed(String)
        /// The viewer is not one of this pet's owners. Refused before the form
        /// is shown rather than after Save is pressed — the server would
        /// refuse either way, and a form whose only outcome is a refusal is a
        /// worse way to say so.
        case notPermitted(String)
    }

    enum SaveState: Equatable {
        case idle
        case saving
        /// Done. Carries the pet's id, which is where to go next.
        case saved(petID: String)
        /// It failed, and it is safe to press Save again.
        case failed(String)
        /// **The outcome is not known, and Save must not be pressed again on
        /// its own.**
        ///
        /// Separate from `failed` for one reason: none of the pet callables
        /// has an idempotency key. A create whose response was lost may have
        /// made a pet — and made it out of one of the five slots — so a
        /// retry makes a second one. The form keeps everything that was typed
        /// and the person is told to look rather than told to try again.
        case uncertain(String)
    }

    // MARK: - Form fields

    var name = ""
    /// Nil until chosen. A create with no species is refused by the server
    /// (`"Pet species is invalid."`), so it is not defaulted to `.other` here
    /// — defaulting would quietly make a choice on somebody's behalf.
    var species: PetSpecies?
    var breed = ""
    var gender: PetGender = .unknown
    var bio = ""
    var birthday: Date?
    /// Create only. The creator's place in the family, written to
    /// `pets/{id}/family/{uid}` rather than to the pet.
    var relationship: PetFamilyRelationship?
    var customRelationship = ""

    /// The photo already on the pet, if any.
    private(set) var avatarURL: String = ""
    /// A photo chosen on this device and not yet sent.
    private(set) var pendingAvatar: Data?
    private(set) var pendingAvatarFilename = "pet-avatar.jpg"

    /// Where the chosen photo landed, once it has.
    ///
    /// Kept across a failed save on purpose. The bytes are on the CDN the
    /// moment the upload succeeds, so a Save that fails *after* the upload
    /// must not send the photo a second time — that costs the person's data
    /// and leaves a second orphan for nothing. This is the same reasoning that
    /// makes `UploadedAsset` a record rather than a transient.
    private(set) var uploadedAvatar: UploadedAsset?

    /// What was decided about reclaiming an asset the last save left
    /// unreferenced. Recorded rather than acted on — see `save()`.
    private(set) var lastReclaimDecision: AssetReclaim.Decision?

    private(set) var loadState: LoadState
    private(set) var saveState: SaveState = .idle
    /// What is wrong with the form right now, or nil. Shown next to Save
    /// rather than thrown, because it is not an error — it is the form not
    /// being finished.
    private(set) var validationMessage: String?

    let mode: Mode
    private let repository: any PetRepository
    private let uploader: any MediaUploading
    private let viewerID: String?
    private let viewerIsAdmin: Bool
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "pet")

    /// The pet as it was loaded, so an edit can send only what changed.
    private var original: Pet?

    /// Set synchronously, unlike `saveState`.
    ///
    /// Not belt-and-braces: `saveState = .saving` is observed and the button
    /// redraws a turn later, and a double tap fits in that gap. The web client
    /// hit this and added `useSubmitGuard` for it; on a create, the cost of
    /// losing that race is two pets and two of the five slots.
    private var submitting = false

    init(
        mode: Mode,
        repository: any PetRepository,
        uploader: any MediaUploading,
        viewerID: String?,
        viewerIsAdmin: Bool = false
    ) {
        self.mode = mode
        self.repository = repository
        self.uploader = uploader
        self.viewerID = viewerID
        self.viewerIsAdmin = viewerIsAdmin
        self.loadState = mode.isEdit ? .loading : .ready
    }

    // MARK: - Prefill

    /// Loads the pet being edited, and checks that this person may edit it.
    ///
    /// The permission check reads the **family subcollection**, never
    /// `pet.ownerID` on its own — see `PetOwnership` for why that field cannot
    /// answer this question in either direction. A family read that *fails* is
    /// treated as "cannot establish permission" and refuses, rather than
    /// falling through to the legacy owner fallback, which an empty-because-it
    /// -failed array would otherwise trigger.
    func loadIfEditing() async {
        guard let petID = mode.petID else { return }
        loadState = .loading
        do {
            guard let pet = try await repository.pet(id: petID) else {
                loadState = .missing
                return
            }
            let family = try await repository.family(petID: petID)
            let ownership = PetOwnership.resolve(
                pet: pet, family: family, viewerID: viewerID, isAdmin: viewerIsAdmin
            )
            guard ownership.canEdit else {
                loadState = .notPermitted(
                    PetProfileViewModel.wording(for: PetError.notAnOwner, doing: .loadingPet)
                )
                return
            }
            apply(pet)
            loadState = .ready
        } catch {
            log.error("pet editor prefill failed: \(error.localizedDescription, privacy: .public)")
            loadState = .failed(PetProfileViewModel.wording(for: error, doing: .loadingPet))
        }
    }

    private func apply(_ pet: Pet) {
        original = pet
        name = pet.name
        species = pet.species
        breed = pet.breed
        gender = pet.gender
        bio = pet.bio
        birthday = pet.birthday
        avatarURL = pet.avatarURL?.absoluteString ?? ""
        pendingAvatar = nil
        uploadedAvatar = nil
    }

    // MARK: - Photo

    func choosePhoto(_ data: Data, filename: String = "pet-avatar.jpg") {
        pendingAvatar = data
        pendingAvatarFilename = filename
        // A different photo invalidates the previous upload. The old asset is
        // not deleted — see `save()` — it simply stops being the one this pet
        // is about to point at.
        uploadedAvatar = nil
    }

    /// Drops a chosen photo, leaving whatever the pet already had.
    func discardChosenPhoto() {
        pendingAvatar = nil
        uploadedAvatar = nil
    }

    // MARK: - Validation

    /// Mirrors `sanitizePetDraft`, so the form refuses what the server would
    /// refuse — one round trip earlier, and without spending a rate-limit slot
    /// on being told.
    ///
    /// **Advisory only.** The server checks all of this again and is the only
    /// thing that decides.
    var validationProblem: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            return String(localized: "Give your pet a name.")
        }
        if !PetValidation.isAcceptableName(trimmedName) {
            return String(localized: "The name has to be \(PetValidation.nameRange.lowerBound)–\(PetValidation.nameRange.upperBound) characters.")
        }
        if species == nil {
            return String(localized: "Choose a species.")
        }
        if breed.trimmingCharacters(in: .whitespacesAndNewlines).count > PetValidation.breedLimit {
            return String(localized: "The breed is too long.")
        }
        if bio.trimmingCharacters(in: .whitespacesAndNewlines).count > PetValidation.bioLimit {
            return String(localized: "The bio is over \(PetValidation.bioLimit) characters.")
        }
        if !mode.isEdit, relationship == nil {
            return String(localized: "Say how you are related to this pet.")
        }
        if !mode.isEdit, relationship == .other,
           customRelationship.trimmingCharacters(in: .whitespacesAndNewlines).count
            > PetValidation.customRelationshipLimit {
            return String(localized: "That relationship label is too long.")
        }
        return nil
    }

    var canSave: Bool {
        if case .saving = saveState { return false }
        if case .uncertain = saveState { return false }
        return validationProblem == nil
    }

    // MARK: - Saving

    func save() async {
        // Synchronous, and first. See `submitting`.
        guard !submitting else { return }
        if case .uncertain = saveState {
            // The one state Save is deliberately dead in. Nothing about the
            // form has changed, and pressing again is exactly the resend that
            // would make a second pet.
            return
        }
        if let problem = validationProblem {
            validationMessage = problem
            return
        }
        submitting = true
        defer { submitting = false }
        validationMessage = nil
        saveState = .saving

        // The photo goes up first, because both writes take a URL. If it does
        // not go up there is no pet to half-create; if it goes up and the
        // write fails, the asset stays on the CDN and is reused by the next
        // attempt rather than sent again.
        if pendingAvatar != nil, uploadedAvatar == nil {
            do {
                uploadedAvatar = try await uploadChosenPhoto()
            } catch {
                saveState = .failed(Self.photoWording(for: error))
                return
            }
        }
        let finalAvatarURL = uploadedAvatar?.url.absoluteString ?? avatarURL

        do {
            let petID: String
            if let existingID = mode.petID {
                let changes = self.changes(withAvatarURL: finalAvatarURL)
                if changes.isEmpty {
                    // Nothing to send. Not an error, and not worth a round
                    // trip — the callable answers `invalid-argument` for an
                    // update with no supported fields, which would read to a
                    // person as a failure when in fact they changed nothing.
                    saveState = .saved(petID: existingID)
                    return
                }
                try await repository.update(petID: existingID, changes: changes)
                petID = existingID
            } else {
                petID = try await repository.create(draft(withAvatarURL: finalAvatarURL))
            }
            // The upload is now referenced by a pet, so it is not an orphan.
            avatarURL = finalAvatarURL
            pendingAvatar = nil
            lastReclaimDecision = nil
            saveState = .saved(petID: petID)
        } catch {
            // **The photo is not deleted, whatever went wrong.**
            //
            // The web client deletes it here (`deleteCloudinaryAssets` in
            // src/pages/AddPet.tsx) and that is the bug `AssetReclaim` was
            // written about: the branch this runs in includes the one where
            // the response was *lost*, and a lost response may mean the pet
            // exists and already points at this URL. Deleting it then leaves a
            // live pet with a broken photo, which cannot be undone; leaving it
            // leaves an orphan on the CDN, which is bounded and collectable.
            //
            // The decision is recorded rather than merely omitted, so "we
            // thought about this" is a value something can assert instead of a
            // comment somebody has to find.
            lastReclaimDecision = AssetReclaim.decide(assets: [uploadedAvatar].compactMap { $0 })
            if case PetError.outcomeUnknown = error {
                saveState = .uncertain(Self.uncertainWording(isEdit: mode.isEdit))
                return
            }
            saveState = .failed(PetProfileViewModel.wording(for: error, doing: .saving))
        }
    }

    /// Resizes and re-encodes the picked photo, then sends it.
    ///
    /// The preparation is the shared one, so a pet's avatar gets exactly what
    /// a post's photo gets: HEIC decoded natively, longest edge 1920, JPEG
    /// quality stepping down to fit 2 MB. It runs off the main actor because
    /// it is a decode and an encode, and doing that on the main actor is a
    /// visible stall on a large photo.
    private func uploadChosenPhoto() async throws -> UploadedAsset {
        guard let data = pendingAvatar else { throw UploadError.malformedResponse }
        let filename = pendingAvatarFilename
        let prepared = try await Task.detached(priority: .userInitiated) {
            try UploadPreparation.prepareImage(data, filename: filename)
        }.value
        return try await uploader.upload(
            UploadItem(
                data: prepared.data,
                filename: prepared.filename,
                mimeType: prepared.mimeType,
                resourceType: .image
            )
        )
    }

    /// Words for the photo half of a save.
    ///
    /// Separate from `PetProfileViewModel.wording` because the failures come
    /// from a different vocabulary — `UploadError` and
    /// `UploadPreparation.PreparationError` — and because every one of them
    /// leaves the pet untouched, which is the thing the person most needs to
    /// know.
    static func photoWording(for error: Error) -> String {
        if let preparation = error as? UploadPreparation.PreparationError {
            switch preparation {
            case .tooLargeToProcess(_, let limit):
                let megabytes = max(1, limit / 1_048_576)
                return String(localized: "That photo is bigger than \(megabytes)MB. Choose a smaller one.")
            case .undecodable:
                return String(localized: "That photo could not be read. Try another one.")
            case .unencodable:
                return String(localized: "That photo could not be prepared. Try another one.")
            }
        }
        guard let upload = error as? UploadError else {
            return String(localized: "The photo could not be uploaded. The pet was not changed.")
        }
        switch upload {
        case .notSignedIn:
            return String(localized: "Sign in again to add a photo.")
        case .banned:
            return String(localized: "This account cannot upload photos.")
        case .rateLimited:
            return String(localized: "Too many uploads just now. Wait a moment and try again.")
        case .signatureUnavailable(let detail):
            return detail == CallableTransport.unavailable
                ? String(localized: "This build cannot reach PetNote's server.")
                : String(localized: "The photo could not be prepared for upload. Try again.")
        case .tooLarge(let limitBytes, _):
            let megabytes = max(1, limitBytes / 1_048_576)
            return String(localized: "That photo is over the \(megabytes)MB limit.")
        case .timedOut:
            return String(localized: "The photo upload timed out. The pet was not changed.")
        case .offline:
            return String(localized: "No connection. Check your network and try again.")
        case .rejected:
            // Never retryable: the same bytes and the same signature will be
            // refused again.
            return String(localized: "That photo was not accepted. Try a different one.")
        case .malformedResponse:
            return String(localized: "The photo upload did not complete. Try again.")
        case .transport:
            return String(localized: "The photo could not be uploaded. The pet was not changed.")
        }
    }

    /// Acknowledges an unknown outcome and re-arms the form.
    ///
    /// Deliberately a separate, deliberate act rather than Save simply working
    /// again: the person has been told to go and look, and this is them saying
    /// they did. Nothing is sent from here.
    func acknowledgeUncertainOutcome() {
        guard case .uncertain = saveState else { return }
        saveState = .idle
    }

    func clearSaveFailure() {
        if case .failed = saveState { saveState = .idle }
    }

    static func uncertainWording(isEdit: Bool) -> String {
        isEdit
            ? String(localized: """
              We could not tell whether that was saved. Open the pet to check \
              before trying again.
              """)
            : String(localized: """
              We could not tell whether the pet was created. Check your pets \
              before trying again — sending this twice would make two.
              """)
    }

    // MARK: - Payloads

    func draft(withAvatarURL avatarURL: String) -> PetDraft {
        let chosen = relationship ?? .other
        return PetDraft(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            species: species ?? .other,
            breed: breed.trimmingCharacters(in: .whitespacesAndNewlines),
            gender: gender,
            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines),
            avatarURL: avatarURL,
            birthday: birthday,
            relationship: chosen,
            // The server only keeps a custom label for `.other`, so sending
            // one with any other relationship would be sending something that
            // is thrown away.
            customRelationship: chosen == .other
                ? customRelationship.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
        )
    }

    /// Only what actually changed.
    ///
    /// The web client sends every field on every save. Sending a diff instead
    /// costs nothing and buys two things: an edit that changed the bio does
    /// not rewrite `nameLower` and the birthday fields, and "nothing changed"
    /// becomes a state this object can recognise instead of a refusal the
    /// server has to explain.
    func changes(withAvatarURL avatarURL: String) -> PetChanges {
        var changes = PetChanges()
        guard let original else { return changes }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName != original.name { changes.name = trimmedName }
        if let species, species != original.species { changes.species = species }
        let trimmedBreed = breed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBreed != original.breed { changes.breed = trimmedBreed }
        if gender != original.gender { changes.gender = gender }
        let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBio != original.bio { changes.bio = trimmedBio }
        if avatarURL != (original.avatarURL?.absoluteString ?? "") {
            changes.avatarURL = avatarURL
        }

        switch (birthday, original.birthday) {
        case (nil, .some):
            // The field was emptied on a pet that had one. This is the case
            // that needs an explicit instruction: omitting the field means
            // "leave it alone", and before the server learned to take an
            // explicit null there was no way to undo a birthday once set.
            changes.birthday = .cleared
        case (.some(let picked), let stored) where stored == nil || !Self.sameDay(picked, stored):
            changes.birthday = .set(picked)
        default:
            changes.birthday = .unchanged
        }
        return changes
    }

    /// Compared by calendar day, not by instant.
    ///
    /// The stored value is whatever instant was written; the picker hands back
    /// local midnight. Comparing instants would call every edit a birthday
    /// change and rewrite the canonical month/day on every save.
    private static func sameDay(_ lhs: Date, _ rhs: Date?, calendar: Calendar = .current) -> Bool {
        guard let rhs else { return false }
        return calendar.isDate(lhs, inSameDayAs: rhs)
    }
}
