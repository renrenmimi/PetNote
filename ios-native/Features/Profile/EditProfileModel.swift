import Foundation
import Observation
import OSLog

/// Editing the profile: name, picture, bio.
///
/// The three failure shapes this is built around, all of them ported from
/// mistakes the web client made first:
///
///   1. **A name check is advisory, not a lock.** Availability is checked
///      while typing so the answer arrives before the save, but the
///      reservation is only taken inside the server's transaction. A name can
///      be free when it is checked and taken when it is saved, so the save has
///      to handle `displayNameTaken` coming back over a field that says free.
///   2. **A double tap fits between a tap and a redraw.** `isSaving` disables
///      the button one render later, which is not soon enough; the guard is
///      taken synchronously.
///   3. **An uploaded picture is only reclaimed when the failure proves the
///      profile write did not happen.** The picture goes to Cloudinary before
///      the write, so a failed save can leave an image on a paid CDN that
///      nothing references. Deleting it is right when the server refused, or
///      when the request never left — and wrong when the outcome is unknown,
///      because a saved profile pointing at a deleted image is unrecoverable.
///      `ProfileError.provesNothingCommitted` is where that line is drawn.
@MainActor
@Observable
final class EditProfileModel {
    enum LoadState: Sendable, Equatable {
        case loading
        case loaded
        /// Says the read failed, rather than showing empty fields that look
        /// like a profile with nothing in it — and that a save would then
        /// write over the real one.
        case failed(String)
    }

    /// What the save did. `savedWithWarning` is the case that did not exist
    /// before and cost somebody their avatar: the profile *is* saved.
    enum SaveOutcome: Sendable, Equatable {
        case saved
        case savedWithWarning(String)
        case failed(String)
    }

    static let maxBioLength = DisplayNameRule.maxBioLength
    static let maxNameLength = DisplayNameRule.maxLength

    var displayName = "" {
        didSet {
            guard displayName != oldValue, loadState == .loaded else { return }
            name.check(displayName)
        }
    }
    var bio = ""

    private(set) var loadState: LoadState = .loading
    private(set) var isSaving = false
    private(set) var outcome: SaveOutcome?
    private(set) var currentAvatarURL = ""
    /// The picture that was picked and not saved yet.
    private(set) var pickedImageData: Data?

    /// Availability, and the rules around asking. Readable by the view.
    let name: DisplayNameAvailability

    private let uid: String
    private let users: any UserRepository
    private let uploader: any AvatarUploading
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "profile")

    init(
        uid: String,
        users: any UserRepository,
        uploader: any AvatarUploading,
        nameCheckDelay: Duration = .milliseconds(500)
    ) {
        self.uid = uid
        self.users = users
        self.uploader = uploader
        self.name = DisplayNameAvailability(users: users, delay: nameCheckDelay)
    }

    var normalizedName: String { DisplayNameRule.normalize(displayName) }
    var bioRemaining: Int { Self.maxBioLength - bio.count }
    var nameRemaining: Int { Self.maxNameLength - displayName.count }
    var hasUnsavedPicture: Bool { pickedImageData != nil }

    /// Everything that has to be true before the button does anything.
    var canSave: Bool {
        guard !isSaving, loadState == .loaded else { return false }
        guard DisplayNameRule.isValid(displayName) else { return false }
        guard bio.count <= Self.maxBioLength else { return false }
        return !name.status.blocksSaving
    }

    func load() async {
        loadState = .loading
        do {
            let profile = try await users.profile(uid: uid)
            // No document yet is a real state, not a failure: an account
            // exists from the moment Auth creates it, and its profile lands a
            // moment later. The fields open on what is there.
            displayName = profile?.displayName ?? ""
            bio = profile?.bio ?? ""
            currentAvatarURL = profile?.resolvedAvatarURL
                ?? UserProfile.defaultAvatarURL(forUID: uid)
            // Settle *after* assigning: the assignment above is what the
            // `didSet` watches, and this is the name that is not a change.
            name.settle(on: displayName)
            loadState = .loaded
        } catch {
            loadState = .failed(Self.message(for: error))
        }
    }

    func pickImage(data: Data) { pickedImageData = data }
    func clearPickedImage() { pickedImageData = nil }

    func save() async {
        // Synchronous, before any suspension. See the type's note (2).
        guard canSave else { return }
        isSaving = true
        outcome = nil
        defer { isSaving = false }

        var uploaded: UploadedAvatar?

        do {
            var avatarURL: String?
            if let pickedImageData {
                guard let prepared = AvatarImage.prepareForUpload(pickedImageData) else {
                    throw AvatarUploadError.notAnImage
                }
                let asset = try await uploader.upload(imageData: prepared)
                uploaded = asset
                avatarURL = asset.url
            }

            let result = try await users.updateProfile(
                displayName: normalizedName,
                avatarURL: avatarURL,
                bio: bio.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            name.settle(on: normalizedName)
            if let avatarURL { currentAvatarURL = avatarURL }
            pickedImageData = nil

            outcome = result.authMirrored
                ? .saved
                : .savedWithWarning(
                    "Saved. Your name may take until the next sign-in to update everywhere."
                )
        } catch {
            // See (3). An unknown outcome keeps the orphan; a refusal reclaims
            // it. `AvatarUploadError` means the upload itself failed, so there
            // is nothing to reclaim and `uploaded` is nil.
            if let uploaded, (error as? ProfileError)?.provesNothingCommitted == true {
                await uploader.discard(uploaded)
            }
            if (error as? ProfileError) == .displayNameTaken {
                // The server settled it. The field has to agree, or the button
                // stays enabled over a name that cannot be saved.
                name.markTaken()
            }
            log.error("profile save failed: \(String(describing: error), privacy: .public)")
            outcome = .failed(Self.message(for: error))
        }
    }

    func dismissOutcome() { outcome = nil }

    static func message(for error: Error) -> String {
        if let profile = error as? ProfileError { return profile.message }
        if let upload = error as? AvatarUploadError { return upload.message }
        return ProfileError.transport("save").message
    }
}
