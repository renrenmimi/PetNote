import Foundation
import Testing

@testable import PetNote

/// Editing a profile: the name check, the save, and the picture.
///
/// The name check is the part that is easy to get subtly wrong and impossible
/// to notice: it is advisory, it races with itself on every keystroke, and its
/// *failure* must not read as "free".
@MainActor
struct ProfileEditTests {

    /// Zero debounce: the delay is real behaviour, checked in its own case,
    /// and making every other case wait half a second for it is how a suite
    /// becomes something nobody runs.
    private func makeModel(
        users: FakeUserRepository,
        uploader: FakeAvatarUploader = FakeAvatarUploader(),
        delay: Duration = .zero
    ) -> EditProfileModel {
        EditProfileModel(uid: "u1", users: users, uploader: uploader, nameCheckDelay: delay)
    }

    private func loadedRepository(
        name: String = "HappyOtter42",
        bio: String = "Two cats.",
        avatar: String = "https://res.cloudinary.test/image/upload/old.jpg"
    ) -> FakeUserRepository {
        let users = FakeUserRepository()
        users.storedProfile = UserProfile(
            id: "u1", displayName: name, avatarURL: avatar, bio: bio, onboardingComplete: true
        )
        return users
    }

    // MARK: Loading

    @Test func loadingFillsTheFieldsFromTheProfileDocument() async {
        let users = loadedRepository()
        let model = makeModel(users: users)
        await model.load()

        #expect(model.loadState == .loaded)
        #expect(model.displayName == "HappyOtter42")
        #expect(model.bio == "Two cats.")
        #expect(model.currentAvatarURL == "https://res.cloudinary.test/image/upload/old.jpg")
    }

    /// Filling the field is not a change, and asking whether your own name is
    /// taken answers yes — by you.
    @Test func loadingDoesNotAskWhetherYourOwnNameIsTaken() async {
        let users = loadedRepository()
        let model = makeModel(users: users)
        await model.load()
        await model.name.awaitPending()

        #expect(users.nameChecks.isEmpty, "loading asked about the name it had just loaded")
        #expect(model.name.status == .idle)
        #expect(model.canSave)
    }

    /// No document yet is a real state right after signing up, not a failure.
    @Test func anAccountWithNoProfileDocumentYetOpensOnTheDefaults() async {
        let users = FakeUserRepository()
        users.storedProfile = nil
        let model = makeModel(users: users)
        await model.load()

        #expect(model.loadState == .loaded)
        #expect(model.displayName.isEmpty)
        #expect(model.currentAvatarURL == UserProfile.defaultAvatarURL(forUID: "u1"))
    }

    /// A failed read must not open as an empty profile: those fields would
    /// then be saved over the real one.
    @Test func afailedReadSaysSoRatherThanShowingAnEmptyProfile() async {
        let users = FakeUserRepository()
        users.profileError = ProfileError.offline
        let model = makeModel(users: users)
        await model.load()

        #expect(model.loadState == .failed(ProfileError.offline.message))
        #expect(!model.canSave, "an unread profile could be saved over")
    }

    // MARK: Is this name free?

    @Test func afreeNameIsReportedAsAvailable() async {
        let model = makeModel(users: loadedRepository())
        await model.load()
        model.displayName = "SparklyKoala19"
        await model.name.awaitPending()

        #expect(model.name.status == .available)
        #expect(model.canSave)
    }

    @Test func anameSomebodyElseHasBlocksTheSave() async {
        let users = loadedRepository()
        users.takenNames = ["sparklykoala19"]
        let model = makeModel(users: users)
        await model.load()
        model.displayName = "SparklyKoala19"
        await model.name.awaitPending()

        #expect(model.name.status == .taken)
        #expect(!model.canSave)
    }

    /// Reservations are keyed on the lowercased name, so this is not a change
    /// and must not be asked about.
    @Test func changingOnlyTheCaseOfYourOwnNameAsksNothing() async {
        let users = loadedRepository(name: "HappyOtter42")
        let model = makeModel(users: users)
        await model.load()
        model.displayName = "happyotter42"
        await model.name.awaitPending()

        #expect(users.nameChecks.isEmpty)
        #expect(model.name.status == .idle)
        #expect(model.canSave)
    }

    /// The web client's `catch` set "not taken", which turns an offline moment
    /// into a green light. `.unknown` says what happened — and still lets the
    /// save go, because the server takes the reservation anyway.
    @Test func acheckThatFailsIsNotReportedAsAFreeName() async {
        let users = loadedRepository()
        users.nameCheckError = ProfileError.offline
        let model = makeModel(users: users)
        await model.load()
        model.displayName = "SparklyKoala19"
        await model.name.awaitPending()

        #expect(model.name.status == .unknown)
        #expect(model.name.status != .available)
        #expect(model.canSave, "a failed check locked the screen")
    }

    @Test func anameThatBreaksTheLengthRuleNeverReachesTheServer() async {
        let users = loadedRepository()
        let model = makeModel(users: users)
        await model.load()

        model.displayName = "a"
        await model.name.awaitPending()
        #expect(model.name.status == .invalid(.tooShort))
        #expect(!model.canSave)

        model.displayName = String(repeating: "a", count: 31)
        await model.name.awaitPending()
        #expect(model.name.status == .invalid(.tooLong))

        #expect(users.nameChecks.isEmpty, "an unusable name was sent to the server")
    }

    /// An empty field is somebody clearing it to retype, not an error to
    /// shout about mid-edit.
    @Test func anEmptyFieldIsNotAnAccusation() async {
        let model = makeModel(users: loadedRepository())
        await model.load()
        model.displayName = ""
        await model.name.awaitPending()
        #expect(model.name.status == .idle)
        #expect(!model.canSave, "an empty name could be saved")
    }

    /// Every keystroke starts a check and cancels the last one. An answer
    /// arriving for a name that is no longer in the field would leave "taken"
    /// stuck to a name nobody typed.
    @Test func anAnswerAboutAnOlderNameIsDropped() async {
        let users = loadedRepository()
        users.takenNames = ["takenname"]
        let model = makeModel(users: users)
        await model.load()

        model.displayName = "TakenName"
        model.displayName = "FreeName"
        await model.name.awaitPending()

        #expect(model.name.status == .available, "the answer for the discarded name was applied")
        #expect(users.nameChecks == ["FreeName"], "the cancelled check still went out")
    }

    /// The debounce is real: it is what keeps a name being typed from costing
    /// one rate-limited callable per character.
    @Test func theCheckWaitsForTypingToStop() async {
        let users = loadedRepository()
        let model = makeModel(users: users, delay: .milliseconds(300))
        await model.load()

        model.displayName = "SparklyKoala19"
        #expect(model.name.status == .checking)
        #expect(users.nameChecks.isEmpty, "the check went out before the debounce elapsed")

        await model.name.awaitPending()
        #expect(users.nameChecks == ["SparklyKoala19"])
    }

    // MARK: Saving

    @Test func savingSendsTheTrimmedNameAndBioThroughTheCallable() async {
        let users = loadedRepository()
        let model = makeModel(users: users)
        await model.load()
        model.displayName = "  SparklyKoala19  "
        model.bio = "  Three cats now.  "
        await model.name.awaitPending()

        await model.save()

        #expect(users.updateCalls.count == 1)
        #expect(users.updateCalls.first?.displayName == "SparklyKoala19")
        #expect(users.updateCalls.first?.bio == "Three cats now.")
        // No picture was picked, so none is sent — the server treats an absent
        // key and a present one differently.
        #expect(users.updateCalls.first?.avatarURL == nil)
        #expect(model.outcome == .saved)
    }

    /// The durable write committed. Reporting the Auth mirror's failure as a
    /// failed save is what sent the web client's caller into a rollback that
    /// deleted the avatar the saved profile was already pointing at.
    @Test func afailedAuthMirrorIsAWarningAndNotAFailedSave() async {
        let users = loadedRepository()
        users.updateResult = .success(ProfileUpdateResult(authMirrored: false))
        let model = makeModel(users: users)
        await model.load()
        model.displayName = "SparklyKoala19"
        await model.name.awaitPending()

        await model.save()

        guard case .savedWithWarning(let message) = model.outcome else {
            Issue.record("a saved profile was reported as \(String(describing: model.outcome))")
            return
        }
        #expect(message.lowercased().contains("saved"))
    }

    @Test func anameLostInTheServersTransactionUpdatesTheFieldTheScreenShows() async {
        let users = loadedRepository()
        users.updateResult = .failure(ProfileError.displayNameTaken)
        let model = makeModel(users: users)
        await model.load()
        model.displayName = "SparklyKoala19"
        await model.name.awaitPending()
        #expect(model.name.status == .available)

        await model.save()

        // The check said free and the server said taken. The field has to
        // agree with the server, or the button stays enabled over a name that
        // cannot be saved.
        #expect(model.name.status == .taken)
        #expect(!model.canSave)
        #expect(model.outcome == .failed(ProfileError.displayNameTaken.message))
    }

    @Test func twoTapsInTheSameTurnSaveOnce() async {
        let users = loadedRepository()
        let model = makeModel(users: users)
        await model.load()
        model.displayName = "SparklyKoala19"
        await model.name.awaitPending()

        let gate = HeldWrite()
        users.whileUpdating = { await gate.hold() }
        let first = Task { await model.save() }
        #expect(await gate.arrives(), "the first save never reached the server")
        #expect(model.isSaving)

        await model.save()
        gate.release()
        await first.value

        #expect(users.updateCalls.count == 1, "the profile was written twice")
    }

    /// The half the held test above does not cover: a second tap that runs
    /// at the first save's first suspension — two taps queued back to back on
    /// the main actor, which is what a real double tap is. The held test taps
    /// again only once the first save is at the server, so a guard that is
    /// checked, then suspends, then set would pass it; this one fails on that
    /// (checked with the guard so broken, 2026-09-23). Proposed by the CI
    /// evidence review.
    @Test func aSecondTapAtTheFirstSuspensionWritesNothing() async {
        let users = loadedRepository()
        let model = makeModel(users: users)
        await model.load()
        model.displayName = "SparklyKoala19"
        await model.name.awaitPending()

        let gate = HeldWrite()
        users.whileUpdating = { await gate.hold() }
        let first = Task { await model.save() }
        let second = Task { await model.save() }
        #expect(await gate.arrives(), "the first save never reached the server")
        // Every chance for the second tap to write, on this actor.
        for _ in 0..<2_000 { await Task.yield() }
        gate.release()
        await first.value
        await second.value

        #expect(users.updateCalls.count == 1, "the profile was written twice")
    }

    /// Holds the fake's write until released, and says when one has arrived.
    private final class HeldWrite: @unchecked Sendable {
        private let lock = NSLock()
        private var arrived = false
        private var released = false
        private var waiting: CheckedContinuation<Void, Never>?

        func hold() async {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    arrived = true
                    if released { return true }
                    waiting = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        /// Bounded by the clock: the fake's write runs on another executor,
        /// and a count of turns here ran out before it arrived (a parallel run,
        /// 2026-09-23; see `eventuallyTrueAnywhere`).
        func arrives() async -> Bool {
            await eventuallyTrueAnywhere { self.lock.withLock { self.arrived } }
        }

        func release() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                released = true
                defer { waiting = nil }
                return waiting
            }
            continuation?.resume()
        }
    }

    // MARK: The picture

    @Test func apickedPictureIsUploadedAndItsUrlIsSaved() async {
        let users = loadedRepository()
        let uploader = FakeAvatarUploader()
        let model = makeModel(users: users, uploader: uploader)
        await model.load()
        model.pickImage(data: Self.onePixelPNG)

        await model.save()

        #expect(uploader.uploads == 1)
        #expect(users.updateCalls.first?.avatarURL
            == "https://res.cloudinary.test/image/upload/new.jpg")
        #expect(model.currentAvatarURL == "https://res.cloudinary.test/image/upload/new.jpg")
        #expect(!model.hasUnsavedPicture)
        #expect(uploader.discarded.isEmpty)
    }

    /// The server refused, so the transaction never ran and the profile
    /// certainly does not reference this image. Leaving it behind is paying
    /// for storage nobody can reach.
    @Test func apictureIsReclaimedWhenTheServerRefusedTheSave() async {
        let users = loadedRepository()
        users.updateResult = .failure(ProfileError.displayNameTaken)
        let uploader = FakeAvatarUploader()
        let model = makeModel(users: users, uploader: uploader)
        await model.load()
        model.pickImage(data: Self.onePixelPNG)

        await model.save()

        #expect(uploader.discarded.count == 1)
        #expect(uploader.discarded.first?.publicID == "new")
        // What was picked is still there, so Save can be pressed again.
        #expect(model.hasUnsavedPicture)
    }

    /// The dangerous case. The write may have committed, so the profile may
    /// already point at this image — and deleting it would leave a real
    /// profile showing a dead URL, which nothing can undo.
    @Test func apictureIsNotReclaimedWhenTheOutcomeIsUnknown() async {
        let users = loadedRepository()
        users.updateResult = .failure(ProfileError.outcomeUnknown)
        let uploader = FakeAvatarUploader()
        let model = makeModel(users: users, uploader: uploader)
        await model.load()
        model.pickImage(data: Self.onePixelPNG)

        await model.save()

        #expect(uploader.discarded.isEmpty, "an image the profile may reference was deleted")
        #expect(model.outcome == .failed(ProfileError.outcomeUnknown.message))
    }

    @Test func afailedUploadLeavesTheProfileAloneAndSaysWhy() async {
        let users = loadedRepository()
        let uploader = FakeAvatarUploader()
        uploader.result = .failure(AvatarUploadError.tooLarge(limitBytes: 10 * 1024 * 1024))
        let model = makeModel(users: users, uploader: uploader)
        await model.load()
        model.pickImage(data: Self.onePixelPNG)

        await model.save()

        #expect(users.updateCalls.isEmpty, "the profile was written with no picture to point at")
        #expect(model.outcome == .failed(AvatarUploadError.tooLarge(limitBytes: 10 * 1024 * 1024).message))
        #expect(uploader.discarded.isEmpty, "there was nothing uploaded to reclaim")
    }

    @Test func bytesThatAreNotAnImageAreRefusedBeforeAnyUpload() async {
        let users = loadedRepository()
        let uploader = FakeAvatarUploader()
        let model = makeModel(users: users, uploader: uploader)
        await model.load()
        model.pickImage(data: Data("not an image".utf8))

        await model.save()

        #expect(uploader.uploads == 0)
        #expect(model.outcome == .failed(AvatarUploadError.notAnImage.message))
    }

    // MARK: The bio

    @Test func abioOverTheLimitBlocksTheSaveRatherThanBeingTruncated() async {
        let model = makeModel(users: loadedRepository())
        await model.load()
        model.bio = String(repeating: "a", count: EditProfileModel.maxBioLength + 1)
        #expect(model.bioRemaining == -1)
        #expect(!model.canSave)

        model.bio = String(repeating: "a", count: EditProfileModel.maxBioLength)
        #expect(model.canSave)
    }

    // MARK: - Cloudinary's half of the bargain

    /// Cloudinary folds **every** parameter it receives into the string it
    /// verifies, and the server signs only these five. Sending one more — the
    /// obvious candidate being `max_file_size`, which the callable also
    /// returns — fails the signature check on every upload, and the failure
    /// looks like a server problem rather than a client one.
    @Test func theUploadSendsExactlyTheParametersTheServerSigned() {
        let signature = CloudinaryAvatarUploader.Signature(
            cloudName: "petnote", apiKey: "key", timestamp: 1_700_000_000,
            signature: "abc", uploadPreset: "preset", folder: "avatars",
            maxFileSize: 10 * 1024 * 1024
        )
        let body = CloudinaryAvatarUploader.multipartBody(
            boundary: "B", imageData: Data([0x01, 0x02]), signature: signature
        )
        let text = String(decoding: body, as: UTF8.self)

        for expected in ["file", "api_key", "timestamp", "signature", "upload_preset", "folder"] {
            #expect(text.contains("name=\"\(expected)\""), "\(expected) was not sent")
        }
        #expect(!text.contains("max_file_size"),
                "an unsigned parameter was sent; every upload would fail the signature check")
    }

    /// The ceiling belongs to the Cloudinary account and arrives in the
    /// response. Copying a number into the client is how the two drift.
    @Test func theSignatureCarriesTheAccountsOwnSizeLimit() {
        let parsed = CloudinaryAvatarUploader.Signature([
            "cloudName": "petnote", "apiKey": "key", "timestamp": NSNumber(value: 1_700_000_000),
            "signature": "abc", "uploadPreset": "preset", "folder": "avatars",
            "maxFileSize": NSNumber(value: 10_485_760),
        ])
        #expect(parsed?.maxFileSize == 10_485_760)
        #expect(parsed?.timestamp == 1_700_000_000)

        // A response missing a field it promised is not a signature.
        #expect(CloudinaryAvatarUploader.Signature(["cloudName": "petnote"]) == nil)
    }

    /// A 1×1 PNG. Real bytes, because `AvatarImage.prepareForUpload` decodes
    /// them and a test that hands it something undecodable would be testing
    /// the refusal path by accident.
    static let onePixelPNG: Data = {
        let base64 = """
            iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
            """
        return Data(base64Encoded: base64) ?? Data()
    }()
}
