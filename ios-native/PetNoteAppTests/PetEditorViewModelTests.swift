import Foundation
import Testing

@testable import PetNote

/// Adding and editing a pet, including the three ways it goes wrong that the
/// person has to be able to recover from: the form being incomplete, the photo
/// not going up, and the write being refused.
@MainActor
struct PetEditorViewModelTests {
    private func creator(
        repository: FakePetRepository = FakePetRepository(),
        uploader: FakePetAvatarUploader = FakePetAvatarUploader(),
        viewerID: String? = "alice"
    ) -> PetEditorViewModel {
        PetEditorViewModel(
            mode: .create, repository: repository, uploader: uploader, viewerID: viewerID
        )
    }

    private func filledIn(_ model: PetEditorViewModel) {
        model.name = "  Mochi  "
        model.species = .dog
        model.breed = " Shiba "
        model.gender = .female
        model.bio = " TEST CONTENT bio "
        model.relationship = .mom
    }

    // MARK: - Validation

    @Test func refusesANameTheServerWouldRefuse() {
        let model = creator()
        filledIn(model)

        model.name = "M"
        #expect(model.validationProblem != nil, "a one-character name is refused by the server")
        #expect(!model.canSave)

        model.name = String(repeating: "x", count: PetValidation.nameRange.upperBound + 1)
        #expect(model.validationProblem != nil)

        model.name = "Mochi"
        #expect(model.validationProblem == nil)
        #expect(model.canSave)
    }

    @Test func refusesACreateWithNoSpeciesAndNoRelationship() {
        let model = creator()
        model.name = "Mochi"

        model.species = nil
        model.relationship = .mom
        #expect(model.validationProblem == "Choose a species.")

        model.species = .cat
        model.relationship = nil
        #expect(model.validationProblem == "Say how you are related to this pet.")
    }

    /// Editing has no relationship field: the relationship belongs to the
    /// family document, not to the pet, and it is not what is being edited.
    @Test func anEditDoesNotDemandARelationship() async {
        let repository = FakePetRepository()
        repository.pet = PetFixture.pet()
        repository.family = [PetFixture.member("alice", role: .primary)]
        let model = PetEditorViewModel(
            mode: .edit(petID: "pet-1"), repository: repository,
            uploader: FakePetAvatarUploader(), viewerID: "alice"
        )
        await model.loadIfEditing()

        #expect(model.validationProblem == nil)
    }

    @Test func aSaveThatCannotPassValidationNeverReachesTheServer() async {
        let repository = FakePetRepository()
        let model = creator(repository: repository)
        model.name = "M"

        await model.save()

        #expect(repository.created.isEmpty)
        #expect(model.validationMessage != nil)
    }

    // MARK: - Creating

    @Test func createsThePetWithTrimmedFieldsAndTheChosenRelationship() async {
        let repository = FakePetRepository()
        repository.createResult = .success("pet-9")
        let model = creator(repository: repository)
        filledIn(model)

        await model.save()

        #expect(repository.created.count == 1)
        let draft = repository.created[0]
        #expect(draft.name == "Mochi")
        #expect(draft.breed == "Shiba")
        #expect(draft.bio == "TEST CONTENT bio")
        #expect(draft.species == .dog)
        #expect(draft.relationship == .mom)
        #expect(model.saveState == .saved(petID: "pet-9"))
    }

    /// The server only keeps a custom label when the relationship is `other`,
    /// so sending one otherwise would be sending something it throws away.
    @Test func sendsACustomRelationshipOnlyWhenTheRelationshipIsOther() async {
        let repository = FakePetRepository()
        let model = creator(repository: repository)
        filledIn(model)
        model.customRelationship = "Dog walker"

        model.relationship = .mom
        await model.save()
        #expect(repository.created.last?.customRelationship == nil)

        model.relationship = .other
        await model.save()
        #expect(repository.created.last?.customRelationship == "Dog walker")
    }

    @Test func aRefusedCreateKeepsTheFormAndSaysWhy() async {
        let repository = FakePetRepository()
        repository.createResult = .failure(PetError.petLimitReached)
        let model = creator(repository: repository)
        filledIn(model)

        await model.save()

        #expect(model.saveState == .failed("You already have 5 pets."))
        #expect(model.name == "  Mochi  ", "the form was cleared under a failure")
        #expect(model.canSave, "a refusal that is safe to retry has to leave Save usable")
    }

    // MARK: - The photo

    @Test func uploadsThePhotoBeforeCreatingAndSendsWhereItLanded() async {
        let repository = FakePetRepository()
        let uploader = FakePetAvatarUploader()
        let model = creator(repository: repository, uploader: uploader)
        filledIn(model)
        model.choosePhoto(PetFixture.tinyPNG, filename: "pet.png")

        await model.save()

        #expect(uploader.uploads.count == 1)
        #expect(uploader.uploads.first?.resourceType == .image)
        #expect(repository.created.first?.avatarURL == FakePetAvatarUploader.landedURL)
    }

    /// If the photo never goes up there is nothing to clean up and no pet to
    /// half-create. The write must not be attempted with a URL that stands for
    /// nothing.
    @Test func aFailedUploadStopsBeforeThePetIsCreated() async {
        let repository = FakePetRepository()
        let uploader = FakePetAvatarUploader()
        uploader.result = .failure(
            UploadError.tooLarge(limitBytes: 10 * 1_048_576, actualBytes: 20 * 1_048_576)
        )
        let model = creator(repository: repository, uploader: uploader)
        filledIn(model)
        model.choosePhoto(PetFixture.tinyPNG, filename: "pet.png")

        await model.save()

        #expect(repository.created.isEmpty, "a pet must not be created with a URL standing for nothing")
        #expect(model.saveState == .failed("That photo is over the 10MB limit."))
    }

    /// Bytes ImageIO cannot read never reach the network. The refusal is the
    /// shared `UploadPreparation`'s, which is the same gate a post's photo
    /// goes through.
    @Test func aPhotoThatIsNotAnImageIsRefusedBeforeItIsSent() async {
        let repository = FakePetRepository()
        let uploader = FakePetAvatarUploader()
        let model = creator(repository: repository, uploader: uploader)
        filledIn(model)
        model.choosePhoto(Data([0x01, 0x02, 0x03]), filename: "not-a-photo.png")

        await model.save()

        #expect(uploader.uploads.isEmpty)
        #expect(repository.created.isEmpty)
        #expect(model.saveState == .failed("That photo could not be read. Try another one."))
    }

    /// The other direction: the photo went up and the write did not.
    ///
    /// **The asset is not deleted, and it is not sent again.** The web client
    /// deletes it here; `AssetReclaim` is the shared decision that it must
    /// not, because this branch includes the case where the response was lost
    /// — and a lost response may mean the pet exists and already points at
    /// this URL. An orphan on the CDN is bounded and collectable; a live pet
    /// with a deleted photo is not undoable.
    @Test func aPhotoUploadedForACreateThatFailedIsKeptRatherThanDeletedOrResent() async {
        let repository = FakePetRepository()
        repository.createResult = .failure(PetError.petLimitReached)
        let uploader = FakePetAvatarUploader()
        let model = creator(repository: repository, uploader: uploader)
        filledIn(model)
        model.choosePhoto(PetFixture.tinyPNG, filename: "pet.png")

        await model.save()

        #expect(model.saveState == .failed("You already have 5 pets."))
        #expect(model.lastReclaimDecision == .automaticReclaimDisabled, """
            The save left an asset unreferenced and did not record a decision \
            about it. Silence here is how a deletion gets added back.
            """)
        #expect(model.uploadedAvatar?.publicID == "new")

        // Pressing Save again must not send the photo a second time.
        await model.save()
        #expect(uploader.uploads.count == 1, "the photo was uploaded twice for one pet")
        #expect(repository.created.count == 2, "the retry did reach the server")
    }

    /// The same on an edit, where the pet's *previous* avatar is still
    /// referenced by a document that is working.
    @Test func aFailedEditKeepsTheUploadedPhotoAndDoesNotResendIt() async {
        let repository = FakePetRepository()
        repository.pet = PetFixture.pet()
        repository.family = [PetFixture.member("alice", role: .primary)]
        repository.updateError = PetError.rateLimited
        let uploader = FakePetAvatarUploader()
        let model = PetEditorViewModel(
            mode: .edit(petID: "pet-1"), repository: repository,
            uploader: uploader, viewerID: "alice"
        )
        await model.loadIfEditing()
        model.choosePhoto(PetFixture.tinyPNG, filename: "pet.png")

        await model.save()
        await model.save()

        #expect(uploader.uploads.count == 1)
        #expect(repository.updated.count == 2)
        #expect(model.avatarURL == "https://res.cloudinary.com/demo/image/upload/old.jpg", """
            The pet's stored avatar must not move until a write has actually \
            succeeded.
            """)
    }

    // MARK: - An outcome nobody knows

    /// **The most important test in this file.** None of the pet callables has
    /// an idempotency key, so a create whose response was lost may already
    /// have made a pet — out of one of the five slots. Pressing Save again
    /// makes a second one.
    @Test func anUnknownCreateOutcomeIsNeverRetriedByPressingSaveAgain() async {
        let repository = FakePetRepository()
        repository.createResult = .failure(PetError.outcomeUnknown)
        let model = creator(repository: repository)
        filledIn(model)

        await model.save()

        guard case .uncertain(let words) = model.saveState else {
            Issue.record("expected an uncertain outcome, got \(model.saveState)")
            return
        }
        #expect(words.contains("two"), "the wording has to say what a second attempt would cost")
        #expect(!model.canSave)

        // The person presses Save again anyway.
        await model.save()
        #expect(repository.created.count == 1, """
            A second create went out after an outcome nobody knew. That is how \
            one lost response becomes two pets.
            """)

        // Acknowledging is a deliberate, separate act, and it sends nothing.
        model.acknowledgeUncertainOutcome()
        #expect(model.saveState == .idle)
        #expect(repository.created.count == 1)
    }

    // MARK: - Editing

    @Test func prefillsTheFormFromThePetBeingEdited() async {
        let repository = FakePetRepository()
        repository.pet = PetFixture.pet(name: "Mochi", breed: "Shiba", bio: "TEST CONTENT bio")
        repository.family = [PetFixture.member("alice", role: .primary)]
        let model = PetEditorViewModel(
            mode: .edit(petID: "pet-1"), repository: repository,
            uploader: FakePetAvatarUploader(), viewerID: "alice"
        )

        await model.loadIfEditing()

        #expect(model.loadState == .ready)
        #expect(model.name == "Mochi")
        #expect(model.breed == "Shiba")
        #expect(model.species == .dog)
        #expect(model.avatarURL == "https://res.cloudinary.com/demo/image/upload/old.jpg")
    }

    /// A blank form would let Save target a document that is not there.
    @Test func editingAPetThatIsGoneSaysSoInsteadOfShowingABlankForm() async {
        let repository = FakePetRepository()
        repository.pet = nil
        let model = PetEditorViewModel(
            mode: .edit(petID: "pet-1"), repository: repository,
            uploader: FakePetAvatarUploader(), viewerID: "alice"
        )

        await model.loadIfEditing()

        #expect(model.loadState == .missing)
    }

    /// Refused before the form is shown, not after Save is pressed. The server
    /// would refuse either way; a form whose only possible outcome is a
    /// refusal is a worse way to say so.
    @Test func somebodyWhoIsNotAnOwnerIsNotGivenTheForm() async {
        let repository = FakePetRepository()
        repository.pet = PetFixture.pet(ownerID: "alice")
        repository.family = [PetFixture.member("alice", role: .primary)]
        let model = PetEditorViewModel(
            mode: .edit(petID: "pet-1"), repository: repository,
            uploader: FakePetAvatarUploader(), viewerID: "stranger"
        )

        await model.loadIfEditing()

        #expect(model.loadState == .notPermitted("You are not one of this pet's owners."))
    }

    /// The same trap as on the profile: an empty family array from a *failed*
    /// read would otherwise trigger the legacy owner fallback and hand the
    /// form to whoever is named in a stale `ownerId`.
    @Test func aFailedFamilyReadRefusesTheFormRatherThanGuessing() async {
        let repository = FakePetRepository()
        repository.pet = PetFixture.pet(ownerID: "alice")
        repository.familyError = PetFixture.readFailure
        let model = PetEditorViewModel(
            mode: .edit(petID: "pet-1"), repository: repository,
            uploader: FakePetAvatarUploader(), viewerID: "alice"
        )

        await model.loadIfEditing()

        #expect(model.loadState == .failed("Could not load this pet."))
        #expect(model.name.isEmpty, "the form must not be filled in on a permission nobody checked")
    }

    @Test func sendsOnlyTheFieldsThatChanged() async throws {
        let repository = FakePetRepository()
        repository.pet = PetFixture.pet(name: "Mochi", breed: "Shiba")
        repository.family = [PetFixture.member("alice", role: .primary)]
        let model = PetEditorViewModel(
            mode: .edit(petID: "pet-1"), repository: repository,
            uploader: FakePetAvatarUploader(), viewerID: "alice"
        )
        await model.loadIfEditing()

        model.bio = "TEST CONTENT changed"
        await model.save()

        let changes = try #require(repository.updated.first?.changes)
        #expect(changes.bio == "TEST CONTENT changed")
        #expect(changes.name == nil, "the name was not touched and must not be rewritten")
        #expect(changes.breed == nil)
        #expect(changes.birthday == PetChanges.Birthday.unchanged)
    }

    @Test func anEditThatChangedNothingDoesNotCallTheServer() async {
        let repository = FakePetRepository()
        repository.pet = PetFixture.pet()
        repository.family = [PetFixture.member("alice", role: .primary)]
        let model = PetEditorViewModel(
            mode: .edit(petID: "pet-1"), repository: repository,
            uploader: FakePetAvatarUploader(), viewerID: "alice"
        )
        await model.loadIfEditing()

        await model.save()

        #expect(repository.updated.isEmpty, """
            An update with no supported fields is answered `invalid-argument`, \
            which reads to a person as a failure when they changed nothing.
            """)
        #expect(model.saveState == .saved(petID: "pet-1"))
    }

    /// The case the server grew an explicit null for. Omitting the field means
    /// "leave it alone", so without this there is no way to undo a birthday
    /// once it has been set.
    @Test func clearingTheBirthdaySendsAnExplicitClearAndNotAnOmission() async {
        let repository = FakePetRepository()
        repository.pet = PetFixture.pet(
            birthday: Date(timeIntervalSince1970: 1_590_969_600),
            birthdayMonth: 6, birthdayDay: 1
        )
        repository.family = [PetFixture.member("alice", role: .primary)]
        let model = PetEditorViewModel(
            mode: .edit(petID: "pet-1"), repository: repository,
            uploader: FakePetAvatarUploader(), viewerID: "alice"
        )
        await model.loadIfEditing()
        #expect(model.birthday != nil, "the birthday has to be prefilled before it can be cleared")

        model.birthday = nil
        await model.save()

        #expect(repository.updated.first?.changes.birthday == PetChanges.Birthday.cleared)
    }

    @Test func settingABirthdaySendsThePickedDay() async {
        let repository = FakePetRepository()
        repository.pet = PetFixture.pet()
        repository.family = [PetFixture.member("alice", role: .primary)]
        let model = PetEditorViewModel(
            mode: .edit(petID: "pet-1"), repository: repository,
            uploader: FakePetAvatarUploader(), viewerID: "alice"
        )
        await model.loadIfEditing()

        let picked = Date(timeIntervalSince1970: 1_590_969_600)
        model.birthday = picked
        await model.save()

        #expect(repository.updated.first?.changes.birthday == PetChanges.Birthday.set(picked))
    }
}
