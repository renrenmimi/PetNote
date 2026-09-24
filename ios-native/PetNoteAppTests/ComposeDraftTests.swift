import Foundation
import Testing

@testable import PetNote

/// The draft, which is where the publish loop's memory lives.
///
/// Two of its fields are load-bearing rather than convenient: the operation id,
/// without which idempotency would stop at the process boundary, and the list
/// of assets already on the CDN, without which a retry would make the person
/// send the same photos again.
struct ComposeDraftTests {
    /// An isolated defaults domain per test. `.standard` is the app's, and a
    /// test that writes there leaves state behind for the next one.
    static func makeDefaults(_ function: String = #function) -> (UserDefaults, String) {
        let name = "petnote.tests.\(function).\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    static func sampleAsset(_ index: Int) -> UploadedAsset {
        UploadedAsset(
            url: URL(string: "https://res.cloudinary.com/petnote/image/upload/v1/u/\(index).jpg")!,
            publicID: "petnote/users/u/\(index)",
            resourceType: .image,
            thumbnailURL: nil
        )
    }

    @Test func aDraftCarriesBackTheOperationIdAndTheMediaAlreadyUploaded() throws {
        let (defaults, suite) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsComposeDraftStore(defaults: defaults)
        let operationID = OperationID.new()

        store.save(
            ComposeDraft(
                text: "morning walk", tags: ["cat"], petID: "pet-1", savedAt: Date(),
                operationID: operationID, uploadedAssets: [Self.sampleAsset(1)]
            ),
            uid: "user-1"
        )
        let restored = try #require(store.load(uid: "user-1"))

        #expect(restored.operationID == operationID)
        #expect(restored.uploadedAssets == [Self.sampleAsset(1)])
        #expect(restored.text == "morning walk")
        #expect(restored.tags == ["cat"])
        #expect(restored.petID == "pet-1")
    }

    /// One device, two accounts.
    ///
    /// The web client's first key was a single global string, so two people
    /// sharing a browser saw each other's unfinished post. The same mistake is
    /// available on a phone.
    @Test func oneAccountNeverSeesAnothersDraft() {
        let (defaults, suite) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsComposeDraftStore(defaults: defaults)

        store.save(ComposeDraft(text: "mine", petID: "pet-1"), uid: "user-1")

        #expect(store.load(uid: "user-2") == nil)
        #expect(store.load(uid: "user-1")?.text == "mine")
    }

    @Test func aDraftOlderThanADayIsDropped() {
        let (defaults, suite) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_758_000_000)
        let clock = MutableClock(start)
        let store = UserDefaultsComposeDraftStore(defaults: defaults, now: { clock.now })

        store.save(
            ComposeDraft(text: "stale", petID: "pet-1", savedAt: start,
                         uploadedAssets: [Self.sampleAsset(1)]),
            uid: "user-1"
        )

        clock.now = start.addingTimeInterval(UserDefaultsComposeDraftStore.lifetime - 60)
        #expect(store.load(uid: "user-1") != nil, "just under a day is still offered back")

        clock.now = start.addingTimeInterval(UserDefaultsComposeDraftStore.lifetime + 60)
        #expect(store.load(uid: "user-1") == nil)
        // And it is really gone, not merely hidden behind the clock.
        clock.now = start
        #expect(store.load(uid: "user-1") == nil)
    }

    @Test func aDraftWithNothingInItIsNotKept() {
        let (defaults, suite) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsComposeDraftStore(defaults: defaults)

        store.save(ComposeDraft(text: "something", petID: "pet-1"), uid: "user-1")
        store.save(ComposeDraft(text: "   ", tags: [], petID: nil), uid: "user-1")

        #expect(store.load(uid: "user-1") == nil, """
            Saving an empty draft over a real one has to clear it, or the \
            banner offers a draft with nothing in it.
            """)
    }

    /// Media already on the CDN counts as worth keeping even with no text.
    ///
    /// This is the case that matters most: it is the state an interrupted
    /// attempt leaves behind, and dropping it would strand the uploads and the
    /// operation id together.
    @Test func uploadedMediaAloneIsEnoughToKeepADraft() {
        let (defaults, suite) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsComposeDraftStore(defaults: defaults)

        store.save(
            ComposeDraft(text: "", tags: [], petID: nil, uploadedAssets: [Self.sampleAsset(1)]),
            uid: "user-1"
        )

        #expect(store.load(uid: "user-1")?.uploadedAssets.count == 1)
    }

    @Test func anUnreadableDraftIsDiscardedRatherThanFailingEveryLaunch() {
        let (defaults, suite) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsComposeDraftStore(defaults: defaults)
        defaults.set(Data("not json".utf8), forKey: UserDefaultsComposeDraftStore.key(uid: "user-1"))

        #expect(store.load(uid: "user-1") == nil)
        #expect(defaults.data(forKey: UserDefaultsComposeDraftStore.key(uid: "user-1")) == nil)
    }

    /// The field the web client stopped writing, and then stopped reading.
    ///
    /// It recorded whether the media had reached the publish call, and it could
    /// be stale in the one direction that matters: the write that sets it can
    /// fail while publishing goes ahead anyway. Nothing here may act on such a
    /// value, so there is nowhere in the shape to put one.
    @Test func theDraftShapeHasNoPlaceForAHandoffFlag() throws {
        let encoded = try JSONEncoder().encode(ComposeDraft(text: "x", petID: "pet-1"))
        let json = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        #expect(json["handedOff"] == nil)
        #expect(Set(json.keys).isSubset(
            of: ["text", "tags", "savedAt", "uploadedAssets", "petID", "operationID"]
        ))
    }

    /// A clock a test can move, so expiry is asserted rather than waited for.
    final class MutableClock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }
}

/// The draft on offer is kept until the person chooses Restore or Discard.
///
/// The web client's autosave does not run while its "unsaved draft" banner is
/// up (src/pages/Create.tsx:283). Saving what is typed then replaces the draft
/// being offered — and an interrupted attempt's draft is the only record of
/// its operation id and of the photos already on the CDN.
@MainActor
struct ComposeDraftOfferTests {
    static let pet = PetFixture.pet(id: "pet-1", name: "Momo")

    private func makeModel(over drafts: InMemoryDraftStore) -> ComposeViewModel {
        ComposeViewModel(
            uid: "user-1", isEmailVerified: true,
            uploader: FakeUploader(), writes: FakePostWrites(),
            pets: FixedPets(pets: [Self.pet]), drafts: drafts
        )
    }

    @Test func typingWhileADraftIsOfferedDoesNotReplaceIt() async throws {
        let drafts = InMemoryDraftStore()
        let operationID = OperationID.new()
        drafts.save(
            ComposeDraft(
                text: "morning walk", tags: ["cat"], petID: Self.pet.id, savedAt: Date(),
                operationID: operationID, uploadedAssets: [ComposeDraftTests.sampleAsset(1)]
            ),
            uid: "user-1"
        )
        let model = makeModel(over: drafts)
        await model.start()
        #expect(model.restorableDraft != nil, "precondition: the stored draft is offered")

        // What the composer's fields do on every edit.
        model.caption = "something else"
        model.persistDraft()
        model.tagInput = "dog"
        model.commitTagInput()

        let stored = try #require(drafts.load(uid: "user-1"), "the offered draft is gone")
        #expect(stored.text == "morning walk", "typing replaced the draft on offer")
        #expect(stored.tags == ["cat"])
        #expect(stored.operationID == operationID, "the interrupted attempt's operation id was lost")
        #expect(stored.uploadedAssets == [ComposeDraftTests.sampleAsset(1)], "the upload records were lost")
    }

    /// And once the person has chosen, what they type is kept again.
    @Test func afterRestoringWhatIsTypedIsKeptAgain() async {
        let drafts = InMemoryDraftStore()
        drafts.save(ComposeDraft(text: "morning walk", petID: Self.pet.id), uid: "user-1")
        let model = makeModel(over: drafts)
        await model.start()
        model.restoreDraft()

        model.caption = "morning walk, then a nap"
        model.persistDraft()

        #expect(drafts.load(uid: "user-1")?.text == "morning walk, then a nap")
    }

    @Test func afterDiscardingWhatIsTypedIsKeptAgain() async {
        let drafts = InMemoryDraftStore()
        drafts.save(ComposeDraft(text: "morning walk", petID: Self.pet.id), uid: "user-1")
        let model = makeModel(over: drafts)
        await model.start()
        model.discardDraft()

        model.caption = "a new post"
        model.persistDraft()

        #expect(drafts.load(uid: "user-1")?.text == "a new post")
    }
}
