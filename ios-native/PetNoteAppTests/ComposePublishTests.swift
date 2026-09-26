import Foundation
import Testing

@testable import PetNote

// MARK: - Fakes

/// An uploader that records what it was asked to send.
///
/// The count is the point in most of these tests: "the retry did not send the
/// photos again" is a statement about this number.
final class FakeUploader: MediaUploading, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [UploadItem] = []
    private var failuresAt: Set<Int> = []
    private var failure: Error = UploadError.timedOut

    var sentItems: [UploadItem] { lock.locked { sent } }
    var sendCount: Int { lock.locked { sent.count } }

    /// 1-based attempt numbers that throw. Counted across *all* uploads this
    /// fake performs, so "the second file fails" and "the second attempt at the
    /// second file succeeds" are both expressible.
    func fail(atSend indices: Set<Int>, with error: Error = UploadError.timedOut) {
        lock.locked {
            failuresAt = indices
            failure = error
        }
    }

    func upload(_ item: UploadItem) async throws -> UploadedAsset {
        let (position, shouldFail, error): (Int, Bool, Error) = lock.locked {
            sent.append(item)
            return (sent.count, failuresAt.contains(sent.count), failure)
        }
        if shouldFail { throw error }
        return UploadedAsset(
            url: URL(string: "https://res.cloudinary.com/petnote/image/upload/v1/u/\(position).jpg")!,
            publicID: "petnote/users/u/\(position)",
            resourceType: item.resourceType,
            thumbnailURL: nil
        )
    }
}

/// A stand-in for `createPostCallable`'s idempotency, built the way the server
/// builds it.
///
/// The server derives the post's document id from `sha256(uid:operationId)` and
/// writes with `.create()`: either the post is written, or `ALREADY_EXISTS`
/// comes back and the earlier post is returned. This fake does exactly that,
/// keyed on the operation id — which is what makes it able to catch the defect
/// under test. A client that mints a fresh id per attempt gets a fresh key and
/// therefore a second post, and `postCount` says so.
final class FakePostWrites: PostWriteRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var postsByOperation: [String: String] = [:]
    private var attempts: [PublishRequest] = []
    private var lostAnswers: Set<Int> = []
    private var nextID = 0

    private var bookmarks: Set<String> = []
    private var pinned: String?
    private var deleted: Set<String> = []
    private var failures: [String: PostWriteError] = [:]

    // MARK: Server state, as seen by a test

    var postCount: Int { lock.locked { postsByOperation.count } }
    var publishAttempts: [PublishRequest] { lock.locked { attempts } }
    var bookmarkedPostIDs: Set<String> { lock.locked { bookmarks } }
    var pinnedPostID: String? { lock.locked { pinned } }
    var deletedPostIDs: Set<String> { lock.locked { deleted } }
    var updates: [(postID: String, text: String, tags: [String], petID: String)] = []

    /// Attempt numbers whose answer is thrown away **after** the write lands.
    ///
    /// This is the honest shape of a lost response, and the only way to get
    /// one: the write really happens and the client really never learns the
    /// outcome. Nothing here is timed.
    func loseAnswer(onAttempts numbers: Set<Int>) {
        lock.locked { lostAnswers = numbers }
    }

    func fail(_ operation: String, with error: PostWriteError) {
        lock.locked { failures[operation] = error }
    }

    func stopFailing(_ operation: String) {
        lock.locked { failures[operation] = nil }
    }

    // MARK: PostWriteRepository

    func publish(_ request: PublishRequest) async throws -> PublishOutcome {
        let (outcome, lost): (PublishOutcome, Bool) = try lock.locked {
            attempts.append(request)
            if let error = failures["publish"] { throw error }
            let existing = postsByOperation[request.operationID]
            let id: String
            if let existing {
                id = existing
            } else {
                nextID += 1
                id = "post-\(nextID)"
                postsByOperation[request.operationID] = id
            }
            return (
                PublishOutcome(postID: id, deduplicated: existing != nil),
                lostAnswers.contains(attempts.count)
            )
        }
        if lost { throw PostWriteError.outcomeUnknown }
        return outcome
    }

    func publishStatus(operationID: String) async throws -> PublishStatus {
        try lock.locked {
            if let error = failures["status"] { throw error }
            guard let id = postsByOperation[operationID] else { return .notVisibleYet }
            return .published(postID: id)
        }
    }

    func update(postID: String, text: String, tags: [String], petID: String) async throws {
        try lock.locked {
            if let error = failures["update"] { throw error }
            updates.append((postID, text, tags, petID))
        }
    }

    func delete(postID: String) async throws {
        try lock.locked {
            if let error = failures["delete"] { throw error }
            deleted.insert(postID)
        }
    }

    func setPinned(postID: String?) async throws {
        try lock.locked {
            if let error = failures["pin"] { throw error }
            pinned = postID
        }
    }

    func bookmark(postID: String) async throws -> BookmarkResult {
        try lock.locked {
            if let error = failures["bookmark"] { throw error }
            if deleted.contains(postID) { return .postNotFound }
            return bookmarks.insert(postID).inserted ? .changed : .unchanged
        }
    }

    func unbookmark(postID: String) async throws -> BookmarkResult {
        try lock.locked {
            if let error = failures["bookmark"] { throw error }
            return bookmarks.remove(postID) != nil ? .changed : .unchanged
        }
    }

    func isBookmarked(postID: String) async throws -> Bool {
        lock.locked { bookmarks.contains(postID) }
    }

    private(set) var bookmarkStatusReads: [[String]] = []

    func bookmarkedPostIDs(among postIDs: [String]) async throws -> Set<String> {
        try lock.locked {
            bookmarkStatusReads.append(postIDs)
            if let error = failures["bookmarkStatus"] { throw error }
            return bookmarks.intersection(postIDs)
        }
    }
}

final class InMemoryDraftStore: ComposeDraftStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var byUID: [String: ComposeDraft] = [:]
    private(set) var clearCount = 0

    func load(uid: String) -> ComposeDraft? { lock.locked { byUID[uid] } }

    func save(_ draft: ComposeDraft, uid: String) {
        lock.locked {
            if draft.isWorthKeeping { byUID[uid] = draft } else { byUID[uid] = nil }
        }
    }

    func clear(uid: String) {
        lock.locked {
            byUID[uid] = nil
            clearCount += 1
        }
    }
}

struct FixedPets: PetChoiceProviding {
    var pets: [Pet]
    func pets(ownedBy uid: String) async throws -> [Pet] { pets }
}

// MARK: - Tests

/// Publishing, and the one property the whole design is arranged around:
/// **pressing Share twice must not make two posts.**
@MainActor
struct ComposePublishTests {
    /// `PetFixture` is the pets batch's helper over the shared `Pet`. Reused
    /// rather than copied: one test target, and a second pet builder is the
    /// same duplication the ownership contract rules out in the app.
    static let pet = PetFixture.pet(id: "pet-1", name: "Momo")

    static func photo(_ index: Int) -> ComposeViewModel.PickedItem {
        ComposeViewModel.PickedItem(
            id: "item-\(index)",
            sourceID: "source-\(index)",
            kind: .image,
            data: UploadTestImages.jpeg(width: 200, height: 200, quality: 0.5),
            filename: "photo\(index).jpg",
            mimeType: "image/jpeg",
            duration: nil
        )
    }

    struct Harness {
        let model: ComposeViewModel
        let uploader: FakeUploader
        let writes: FakePostWrites
        let drafts: InMemoryDraftStore
        var publishedPostIDs: [String] { published.value }
        private let published: Box<[String]>

        final class Box<Value>: @unchecked Sendable {
            var value: Value
            init(_ value: Value) { self.value = value }
        }

        @MainActor
        init(
            uid: String = "user-1",
            isEmailVerified: Bool = true,
            uploader: FakeUploader = FakeUploader(),
            writes: FakePostWrites = FakePostWrites(),
            drafts: InMemoryDraftStore = InMemoryDraftStore(),
            photos: Int = 2
        ) {
            self.uploader = uploader
            self.writes = writes
            self.drafts = drafts
            let box = Box<[String]>([])
            published = box
            model = ComposeViewModel(
                uid: uid,
                isEmailVerified: isEmailVerified,
                uploader: uploader,
                writes: writes,
                pets: FixedPets(pets: [ComposePublishTests.pet]),
                drafts: drafts,
                onPublished: { box.value.append($0) }
            )
            model.selectedPetID = ComposePublishTests.pet.id
            model.caption = "first walk"
            if photos > 0 { model.add((1...photos).map(ComposePublishTests.photo)) }
        }
    }

    // MARK: The headline

    /// §5: a publish whose answer never arrives must not become two posts.
    ///
    /// The lost answer is injected, not waited for: the fake performs the write
    /// and then throws away the only thing that said so, which is exactly what
    /// a dropped response does. Nothing here is timed.
    @Test func aPublishWhoseAnswerIsLostDoesNotBecomeASecondPost() async {
        let harness = Harness()
        harness.writes.loseAnswer(onAttempts: [1])

        await harness.model.share()

        // The first attempt reached the server and committed. The client
        // cannot know that, and says so.
        #expect(harness.writes.postCount == 1)
        #expect(harness.model.phase == .failed(stage: .publish))
        #expect(harness.model.failureMessage?.contains("won't post twice") == true)

        // The person presses Share again, which is what the message invites.
        await harness.model.share()

        #expect(harness.writes.publishAttempts.count == 2, "the retry really was sent")
        #expect(harness.writes.postCount == 1, """
            Two publish attempts produced two posts. The retry must carry the \
            operation id of the attempt it is retrying.
            """)
        #expect(
            harness.writes.publishAttempts[0].operationID
                == harness.writes.publishAttempts[1].operationID
        )
        #expect(harness.model.hasPublished)
        #expect(harness.publishedPostIDs == ["post-1"])
    }

    /// The control for the test above.
    ///
    /// Without this, "one post after two attempts" could be a property of the
    /// fake rather than of the client — a fake that can only ever hold one post
    /// proves nothing. Two different operation ids have to produce two posts.
    @Test func theFakeServerDoesMakeASecondPostForADifferentOperationID() async throws {
        let writes = FakePostWrites()
        let request = { (operationID: String) in
            PublishRequest(
                operationID: operationID, text: "x", tags: [], petID: "pet-1", media: []
            )
        }
        _ = try await writes.publish(request("operation-one"))
        _ = try await writes.publish(request("operation-two"))

        #expect(writes.postCount == 2)
    }

    /// The retry must not send the photos again.
    ///
    /// Re-uploading wastes the person's data and leaks another copy onto the
    /// CDN that nothing will ever reference.
    @Test func aRetryAfterALostAnswerDoesNotReUploadTheMedia() async {
        let harness = Harness()
        harness.writes.loseAnswer(onAttempts: [1])

        await harness.model.share()
        let afterFirst = harness.uploader.sendCount
        await harness.model.share()

        #expect(afterFirst == 2, "two photos, two uploads")
        #expect(harness.uploader.sendCount == 2, "the retry resumed from what was already on the CDN")
        #expect(harness.writes.publishAttempts[1].media.count == 2)
    }

    /// A failure part-way through the uploads keeps what already landed.
    @Test func aFailedUploadKeepsThePhotosThatAlreadyReachedTheCdn() async {
        let harness = Harness(photos: 3)
        harness.uploader.fail(atSend: [2])

        await harness.model.share()

        #expect(harness.model.phase == .failed(stage: .upload))
        #expect(harness.model.uploadedAssets.count == 1, "photo one must not be thrown away")
        #expect(harness.writes.publishAttempts.isEmpty, "nothing reached the publish call")
        // No "press Share again, it won't post twice" here: nothing was handed
        // over, so there is nothing ambiguous to reassure anybody about.
        #expect(harness.model.failureMessage?.contains("won't post twice") == false)

        harness.uploader.fail(atSend: [])
        await harness.model.share()

        #expect(harness.model.hasPublished)
        #expect(harness.writes.publishAttempts.last?.media.count == 3)
        #expect(harness.uploader.sendCount == 4, """
            One success, one failure, then the two that were still outstanding: \
            the first photo must not be sent a second time.
            """)
    }

    /// The whole point of keeping the operation id in the draft: a retry after
    /// the app was killed is still the same submission.
    @Test func aRetryAfterARelaunchReusesTheSameOperationID() async {
        let drafts = InMemoryDraftStore()
        let writes = FakePostWrites()
        writes.loseAnswer(onAttempts: [1])

        let first = Harness(writes: writes, drafts: drafts)
        await first.model.share()
        #expect(writes.postCount == 1)
        #expect(first.model.phase == .failed(stage: .publish))

        // A new process: a new model over the same account and the same stored
        // draft. Nothing survives in memory.
        let second = ComposeViewModel(
            uid: "user-1", isEmailVerified: true,
            uploader: FakeUploader(), writes: writes,
            pets: FixedPets(pets: [Self.pet]), drafts: drafts
        )
        await second.start()
        #expect(second.restorableDraft != nil, "the interrupted attempt has to be offered back")
        second.restoreDraft()
        #expect(second.uploadedAssets.count == 2, "its media came back with it")

        await second.share()

        #expect(writes.postCount == 1, """
            The relaunched app published a second post. The operation id has to \
            come back from the draft, or idempotency stops at the process boundary.
            """)
        #expect(writes.publishAttempts.count == 2)
        #expect(writes.publishAttempts[0].operationID == writes.publishAttempts[1].operationID)
    }

    // MARK: Success

    @Test func aSuccessfulPublishClearsTheDraftAndTellsTheFeed() async {
        let harness = Harness()

        await harness.model.share()

        #expect(harness.model.phase == .published(postID: "post-1", deduplicated: false))
        #expect(harness.drafts.load(uid: "user-1") == nil, "a published post is not a draft")
        #expect(harness.model.operationID == nil)
        #expect(harness.model.uploadedAssets.isEmpty)
        #expect(harness.publishedPostIDs == ["post-1"], """
            The feed's loaded pages cannot contain what was just made, so it has \
            to be told. Without this the person lands on a feed missing their post.
            """)
    }

    /// The success window cannot accept a second submit.
    ///
    /// The web client needed a lock here because it waits 600 ms before
    /// navigating away, and a second tap inside that window used to publish
    /// again.
    @Test func shareIsRefusedOnceTheAttemptHasSucceeded() async {
        let harness = Harness()
        await harness.model.share()

        #expect(!harness.model.canShare)
        await harness.model.share()

        #expect(harness.writes.publishAttempts.count == 1)
    }

    @Test func aDeduplicatedAnswerIsReportedAsSuccessRatherThanAsAFailure() async {
        let writes = FakePostWrites()
        writes.loseAnswer(onAttempts: [1])
        let harness = Harness(writes: writes)

        await harness.model.share()
        await harness.model.share()

        #expect(harness.model.phase == .published(postID: "post-1", deduplicated: true))
        #expect(harness.model.notice == "That post was already published.")
    }

    // MARK: Gates

    @Test func shareIsRefusedWithoutAVerifiedEmailOrAChosenPet() async {
        let unverified = Harness(isEmailVerified: false)
        #expect(!unverified.model.canShare)
        await unverified.model.share()
        #expect(unverified.writes.publishAttempts.isEmpty)

        let noPet = Harness()
        noPet.model.selectedPetID = nil
        #expect(!noPet.model.canShare)
        await noPet.model.share()
        #expect(noPet.writes.publishAttempts.isEmpty)
    }

    @Test func aRestoredDraftCanBePublishedWithoutPickingThePhotosAgain() async {
        let drafts = InMemoryDraftStore()
        let writes = FakePostWrites()
        let asset = UploadedAsset(
            url: URL(string: "https://res.cloudinary.com/petnote/image/upload/v1/u/1.jpg")!,
            publicID: "petnote/users/u/1", resourceType: .image, thumbnailURL: nil
        )
        drafts.save(
            ComposeDraft(
                text: "saved", tags: ["cat"], petID: Self.pet.id, savedAt: Date(),
                operationID: OperationID.new(), uploadedAssets: [asset]
            ),
            uid: "user-1"
        )
        let model = ComposeViewModel(
            uid: "user-1", isEmailVerified: true, uploader: FakeUploader(), writes: writes,
            pets: FixedPets(pets: [Self.pet]), drafts: drafts
        )
        await model.start()
        model.restoreDraft()

        #expect(model.canShare, """
            Media already on the CDN is enough to publish. The web client \
            restores the assets and then refuses to send them, which strands \
            the post.
            """)
        await model.share()
        #expect(writes.publishAttempts.first?.media == [asset])
    }

    // MARK: Changing the selection

    @Test func changingTheSelectionReleasesTheAttemptAndStartsAFreshOne() async {
        let harness = Harness()
        harness.writes.loseAnswer(onAttempts: [1])
        await harness.model.share()
        let firstOperationID = harness.writes.publishAttempts[0].operationID
        #expect(harness.model.uploadedAssets.count == 2)

        // A different selection: the uploads are matched to the files by
        // position, so they no longer describe what is on screen.
        harness.model.remove(id: "item-2")

        #expect(harness.model.uploadedAssets.isEmpty)
        #expect(harness.model.operationID == nil, """
            A changed selection is a different submission. Reusing the id would \
            hand back the earlier post and silently ignore the new photos.
            """)

        await harness.model.share()

        #expect(harness.writes.publishAttempts.count == 2)
        #expect(harness.writes.publishAttempts[1].operationID != firstOperationID)
        #expect(harness.writes.postCount == 2, "two different submissions are two posts")
    }

    /// The one thing `getPublishStatusCallable` is for.
    ///
    /// It tells the person something true — and only in the direction that is
    /// sound. A `notVisibleYet` answer says nothing, so it says nothing.
    @Test func aReleasedAttemptThatDidPublishSaysSo() async {
        let harness = Harness()
        harness.writes.loseAnswer(onAttempts: [1])
        await harness.model.share()

        harness.model.remove(id: "item-2")
        await harness.model.pendingStatusLookup?.value

        #expect(harness.model.notice?.contains("did go through") == true)
    }

    @Test func aReleasedAttemptThatNeverPublishedSaysNothing() async {
        let harness = Harness()
        harness.uploader.fail(atSend: [2])
        await harness.model.share()
        #expect(harness.model.phase == .failed(stage: .upload))
        harness.model.notice = nil

        harness.model.remove(id: "item-1")
        await harness.model.pendingStatusLookup?.value

        #expect(harness.model.notice == nil, """
            "not visible yet" is not "never published", so there is nothing \
            true to say and nothing is said.
            """)
    }

    // MARK: Reclaim

    /// Automatic CDN reclaim from the composer is suspended, and the type is
    /// what enforces it: there is no `reclaim` case that means yes.
    @Test func noExitFromTheComposerEverDeletesUploadedMedia() throws {
        let asset = UploadedAsset(
            url: URL(string: "https://res.cloudinary.com/petnote/image/upload/v1/u/1.jpg")!,
            publicID: "petnote/users/u/1", resourceType: .image, thumbnailURL: nil
        )
        #expect(AssetReclaim.decide(assets: []) == .noAssets)
        #expect(AssetReclaim.decide(assets: [asset]) == .automaticReclaimDisabled)

        // And no source file in this line calls the delete callable, which is
        // the part a type cannot state.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
        var offenders: [String] = []
        // This batch's files only. Pet avatars are another batch's flow and do
        // reclaim an orphaned upload; that is their decision to defend, and
        // reporting it here would only teach the next person to ignore this.
        for url in PublishSourceFiles.owned(root: root) {
            let code = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains("deleteCloudinaryAssets") { offenders.append(url.lastPathComponent) }
        }
        #expect(offenders.isEmpty, """
            Automatic media reclaim is disabled in production and must not be \
            reintroduced here: past the handoff, deleting leaves a live post \
            pointing at images that no longer exist.
            """)
    }

    /// A discarded draft keeps its photos on the CDN.
    @Test func discardingADraftClearsItLocallyAndKeepsTheUploads() async {
        let harness = Harness()
        harness.writes.loseAnswer(onAttempts: [1])
        await harness.model.share()
        #expect(harness.drafts.load(uid: "user-1")?.uploadedAssets.count == 2)

        harness.model.discardDraft()

        #expect(harness.drafts.load(uid: "user-1") == nil)
        #expect(harness.model.uploadedAssets.isEmpty)
        // "I don't want this draft" is not evidence that no post references
        // those photos — and one does, in this very test.
        #expect(harness.writes.postCount == 1)
    }

    // MARK: Tags and limits

    @Test func tagsAreNormalisedTheWayTheServerNormalisesThem() {
        let normalize = ComposeViewModel.normalized

        #expect(normalize("#Cat, CUTE  dog", []) == ["cat", "cute", "dog"])
        #expect(normalize("cat cat", []) == ["cat"], "duplicates collapse")
        #expect(normalize("cat", ["cat"]) == ["cat"])
        #expect(normalize(String(repeating: "x", count: 41), []) == [], "over 40 characters is dropped")
        #expect(normalize("  #  ", []) == [], "a bare hash is not a tag")

        let full = (1...20).map { "tag\($0)" }
        #expect(normalize("overflow", full) == full, "the cap is 20")
    }

    /// `createPostCallable` validates tags with `validateIncomingTags`, not
    /// with `normalizeTags` (functions/src/posts.ts:79-100): a tag that cannot
    /// be a `hashtags/{tag}` document id — `.`, `*`, `~`, `/`, `[`, `]`, or the
    /// reserved `__x__` — is **refused with invalid-argument**, and the length
    /// is JavaScript's, which counts UTF-16 units.
    ///
    /// The fake publish accepts any tag, so before this nothing noticed that
    /// "st.louis" sailed through the composer, came back as a generic "not
    /// accepted", and invited a Share that could only be refused again.
    @Test func aTagTheCallableWouldRefuseIsRefusedHereAndSaysWhy() {
        let normalize = ComposeViewModel.normalized

        #expect(normalize("st.louis dogs/cats a*b ~x [y] __init__ ok", []) == ["ok"])
        // 21 dogs are 21 Characters and 42 UTF-16 units; the server says 42.
        #expect(normalize(String(repeating: "🐶", count: 21), []) == [])
        #expect(normalize(String(repeating: "🐶", count: 20), []).count == 1)

        let model = Harness(photos: 0).model
        model.tagInput = "st.louis walk"
        model.commitTagInput()

        #expect(model.tags == ["walk"])
        #expect(model.notice == "Tags cannot contain . * ~ / [ ] characters.")
    }

    @Test func theCaptionCannotExceedTheServersLimit() {
        let model = Harness().model
        model.caption = String(repeating: "a", count: ComposeViewModel.maxCharacters + 500)

        #expect(model.caption.count == ComposeViewModel.maxCharacters)
    }

    @Test func nineFilesIsTheCeilingAndDuplicatesAreSkipped() {
        let harness = Harness(photos: 0)
        harness.model.add((1...12).map(Self.photo))

        #expect(harness.model.items.count == ComposeViewModel.maxFiles)
        #expect(harness.model.notice != nil)

        let alreadyThere = Self.photo(1)
        harness.model.add([alreadyThere])
        #expect(harness.model.items.count == ComposeViewModel.maxFiles)
    }

    @Test func aVideoOverAMinuteIsRefusedWithTheReason() {
        let long = ComposeViewModel.PickedItem(
            id: "v1", sourceID: "v1", kind: .video, data: Data(repeating: 0, count: 1024),
            filename: "clip.mov", mimeType: "video/quicktime", duration: 75
        )
        #expect(ComposeViewModel.refusal(for: long) == "Video must be under 60 seconds")

        let huge = ComposeViewModel.PickedItem(
            id: "v2", sourceID: "v2", kind: .video,
            data: Data(repeating: 0, count: ComposeViewModel.maxVideoBytes + 1),
            filename: "clip.mov", mimeType: "video/quicktime", duration: 10
        )
        #expect(ComposeViewModel.refusal(for: huge)?.contains("80MB") == true)

        let fine = ComposeViewModel.PickedItem(
            id: "v3", sourceID: "v3", kind: .video, data: Data(repeating: 0, count: 1024),
            filename: "clip.mov", mimeType: "video/quicktime", duration: 12
        )
        #expect(ComposeViewModel.refusal(for: fine) == nil)
    }

    // MARK: Stage naming

    /// "Uploading 2/3" while the CPU is re-encoding a photo points at the wrong
    /// thing on a slow phone. Each stage names itself.
    @Test func theStagesAreNamedSeparately() {
        let model = Harness().model
        #expect(model.phaseLabel == "Share")
        #expect(ComposeViewModel.message(for: UploadError.offline, handedOff: false)
            == "You appear to be offline.")
        #expect(
            ComposeViewModel.message(for: PostWriteError.outcomeUnknown, handedOff: true)
                .contains("won't post twice")
        )
        #expect(
            !ComposeViewModel.message(for: UploadError.offline, handedOff: false)
                .contains("won't post twice"),
            "before the handoff there is nothing uncertain to reassure anybody about"
        )
    }
}

extension NSLock {
    /// Named `locked` rather than `withLock` so it cannot be confused with —
    /// or ambiguous against — Foundation's own `NSLocking.withLock`.
    func locked<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try body()
    }
}
