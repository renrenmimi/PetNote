import FirebaseFunctions
import Foundation
import Testing

@testable import PetNote

/// Managing a post after it exists: edit, delete, pin, save — plus the two
/// pieces of the publish contract that are pure values, the operation id and
/// the error mapping.
@MainActor
struct PostWriteManageTests {
    static func post(id: String = "post-1", authorID: String = "user-1") -> Post {
        Post(
            id: id, authorID: authorID, authorName: "Wei", authorAvatarURL: nil,
            text: "hello", media: [], petID: "pet-1", petName: "Momo", petAvatarURL: nil,
            createdAt: Date(timeIntervalSince1970: 1_758_000_000),
            likeCount: 0, commentCount: 0, tags: ["cat"]
        )
    }

    struct StubFeed: FeedRepository {
        var stored: Post?
        var error: PostWriteError?

        func posts(after cursor: PageCursor?, limit: Int) async throws -> Page<Post> { .empty }

        func post(id: String) async throws -> Post? {
            if let error { throw error }
            return stored
        }
    }

    struct StubPins: PinnedPostReading {
        var pinned: String?
        func pinnedPostID(for uid: String) async throws -> String? { pinned }
    }

    // MARK: - Operation ids

    /// The server's rule, mirrored: 8-64 characters of `A-Z a-z 0-9 - _`. An id
    /// it rejects turns every publish into an invalid-argument, and the error
    /// reads as though the post's content was the problem.
    @Test func aGeneratedOperationIdIsOneTheServerWillAccept() {
        let id = OperationID.new()

        #expect(OperationID.isValid(id))
        #expect(id.count == 32)
        #expect(!id.contains("-"), "the dashes are stripped so the id stays inside the allowed set")
        #expect(OperationID.new() != OperationID.new())
    }

    @Test func aMalformedOperationIdIsRejectedBeforeItReachesTheServer() {
        #expect(!OperationID.isValid("short"))
        #expect(!OperationID.isValid(String(repeating: "a", count: 65)))
        #expect(!OperationID.isValid("has spaces here"))
        #expect(!OperationID.isValid("has/slash/init"))
        #expect(OperationID.isValid("with-dash_and_underscore"))
    }

    // MARK: - Error mapping

    static func functionsError(_ code: FunctionsErrorCode, _ message: String) -> NSError {
        NSError(
            domain: FunctionsErrorDomain, code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// `permission-denied` is four different gates in functions/src/posts.ts,
    /// and they need four different sentences on screen.
    @Test func eachServerGateBecomesItsOwnError() {
        let map = FirestorePostWriteRepository.map

        #expect(map(Self.functionsError(.permissionDenied, "Verify your email before posting."))
            == .emailNotVerified)
        #expect(map(Self.functionsError(.permissionDenied, "Banned users cannot create posts."))
            == .banned)
        #expect(map(Self.functionsError(.permissionDenied, "You do not have access to this pet."))
            == .petNotAccessible)
        #expect(map(Self.functionsError(.permissionDenied, "Cannot delete this post."))
            == .notTheAuthor)
        #expect(map(Self.functionsError(.notFound, "Post not found.")) == .postNotFound)
        #expect(map(Self.functionsError(.unauthenticated, "Must be logged in.")) == .notSignedIn)
        #expect(map(Self.functionsError(.resourceExhausted, "Too many requests.")) == .rateLimited)
    }

    /// A build that cannot send credentials at all reports the same code as a
    /// signed-out caller. Telling them apart is what stops somebody being sent
    /// to sign in again, over and over, for something that is not about them.
    @Test func aBuildThatCannotReachTheCallablesIsNotReportedAsSignedOut() {
        let refusal = Self.functionsError(
            .unauthenticated,
            "Refusing to send Auth, FCM, and AppCheck tokens over HTTP to non-loopback host."
        )

        #expect(FirestorePostWriteRepository.map(refusal)
            == .transport(CallableTransport.unavailable))
    }

    /// No answer at all is `outcomeUnknown` — and for publishing that is safe
    /// to retry, which is the opposite of the comment path.
    @Test func noAnswerIsReportedAsUnknownRatherThanAsFailure() {
        #expect(FirestorePostWriteRepository.map(Self.functionsError(.deadlineExceeded, "timeout"))
            == .outcomeUnknown)
        #expect(FirestorePostWriteRepository.map(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        ) == .outcomeUnknown)
        #expect(FirestorePostWriteRepository.map(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        ) == .transport("offline"))
    }

    // MARK: - Editing

    @Test func editingSavesTheTextTagsAndPetAndNothingElse() async {
        let writes = FakePostWrites()
        let model = EditPostViewModel(
            postID: "post-1", uid: "user-1",
            feed: StubFeed(stored: Self.post()), writes: writes,
            pets: FixedPets(pets: [ComposePublishTests.pet])
        )
        await model.load()
        #expect(model.state == .ready)
        #expect(model.caption == "hello")
        #expect(model.tags == ["cat"])

        model.caption = "  hello again  "
        model.tagInput = "#Dog"
        model.commitTagInput()
        await model.save()

        #expect(model.didSave)
        let update = writes.updates.last
        #expect(update?.postID == "post-1")
        #expect(update?.text == "hello again", "the text is trimmed the way the composer trims it")
        #expect(update?.tags == ["cat", "dog"])
        #expect(update?.petID == "pet-1")
    }

    @Test func somebodyElsesPostCannotBeSaved() async {
        let writes = FakePostWrites()
        let model = EditPostViewModel(
            postID: "post-1", uid: "user-2",
            feed: StubFeed(stored: Self.post(authorID: "user-1")), writes: writes,
            pets: FixedPets(pets: [ComposePublishTests.pet])
        )
        await model.load()

        #expect(!model.canEdit)
        #expect(!model.canSave)
        await model.save()
        #expect(writes.updates.isEmpty)
    }

    /// "Not there" and "we could not find out" must not look the same.
    @Test func aMissingPostAndAFailedReadAreDifferentStates() async {
        let missing = EditPostViewModel(
            postID: "gone", uid: "user-1", feed: StubFeed(stored: nil),
            writes: FakePostWrites(), pets: FixedPets(pets: [])
        )
        await missing.load()
        #expect(missing.state == .notFound)

        let broken = EditPostViewModel(
            postID: "post-1", uid: "user-1",
            feed: StubFeed(stored: nil, error: PostWriteError.transport("boom")),
            writes: FakePostWrites(), pets: FixedPets(pets: [])
        )
        await broken.load()
        #expect(broken.state == .failed("Could not load that post."), """
            Without this the screen sat on "Loading…" forever whenever the read \
            failed — the same defect the web client fixed on three screens.
            """)
    }

    @Test func aRefusedSaveSaysWhyAndLeavesTheScreenOpen() async {
        let writes = FakePostWrites()
        writes.fail("update", with: .rateLimited)
        let model = EditPostViewModel(
            postID: "post-1", uid: "user-1", feed: StubFeed(stored: Self.post()),
            writes: writes, pets: FixedPets(pets: [ComposePublishTests.pet])
        )
        await model.load()
        await model.save()

        #expect(!model.didSave)
        #expect(model.failureMessage == "Too many posts just now. Wait a moment.")
    }

    // MARK: - Delete

    @Test func deletingTellsTheListSoItCanDropTheRow() async {
        let writes = FakePostWrites()
        var removed: [String] = []
        let model = PostActionsViewModel(
            post: Self.post(), uid: "user-1", writes: writes,
            pins: StubPins(), onDeleted: { removed.append($0) }
        )

        await model.delete()

        #expect(model.isDeleted)
        #expect(writes.deletedPostIDs == ["post-1"])
        #expect(removed == ["post-1"], """
            A deleted post leaves a row pointing at nothing until something \
            tells the list.
            """)
    }

    /// The callable answers success for a post that is already gone, because
    /// that is the outcome the caller asked for. So does this.
    @Test func deletingSomethingAlreadyGoneIsSuccessRatherThanAnError() async {
        let writes = FakePostWrites()
        writes.fail("delete", with: .postNotFound)
        var removed: [String] = []
        let model = PostActionsViewModel(
            post: Self.post(), uid: "user-1", writes: writes,
            pins: StubPins(), onDeleted: { removed.append($0) }
        )

        await model.delete()

        #expect(model.isDeleted)
        #expect(model.failureMessage == nil)
        #expect(removed == ["post-1"])
    }

    @Test func onlyTheAuthorCanDeleteOrPin() async {
        let writes = FakePostWrites()
        let model = PostActionsViewModel(
            post: Self.post(authorID: "somebody-else"), uid: "user-1",
            writes: writes, pins: StubPins()
        )

        #expect(!model.isOwnPost)
        await model.delete()
        await model.togglePin()

        #expect(writes.deletedPostIDs.isEmpty)
        #expect(writes.pinnedPostID == nil)
    }

    // MARK: - Pin

    @Test func pinningAndUnpinningGoThroughTheOneCallable() async {
        let writes = FakePostWrites()
        let model = PostActionsViewModel(
            post: Self.post(), uid: "user-1", writes: writes, pins: StubPins()
        )
        await model.refresh()
        #expect(!model.isPinned)

        await model.togglePin()
        #expect(model.isPinned)
        #expect(writes.pinnedPostID == "post-1")

        await model.togglePin()
        #expect(!model.isPinned)
        #expect(writes.pinnedPostID == nil, "unpinning is the same callable with no post id")
    }

    @Test func aPostThatIsAlreadyPinnedSaysUnpin() async {
        let model = PostActionsViewModel(
            post: Self.post(), uid: "user-1", writes: FakePostWrites(),
            pins: StubPins(pinned: "post-1")
        )
        await model.refresh()

        #expect(model.isPinned)
    }

    // MARK: - Bookmarks

    /// Bookmarks are the client-direct-write exception, and the rule is
    /// create-only: `allow update: if false`. Saving something already saved
    /// therefore reports "unchanged" instead of writing again.
    @Test func savingAPostIsOptimisticAndSettlesOnTheServersAnswer() async {
        let writes = FakePostWrites()
        let model = PostActionsViewModel(
            post: Self.post(), uid: "user-1", writes: writes, pins: StubPins()
        )
        await model.refresh()
        #expect(!model.isBookmarked)

        await model.toggleBookmark()
        #expect(model.isBookmarked)
        #expect(writes.bookmarkedPostIDs == ["post-1"])

        await model.toggleBookmark()
        #expect(!model.isBookmarked)
        #expect(writes.bookmarkedPostIDs.isEmpty)
    }

    @Test func aFailedSaveRollsTheHeartBackRatherThanLeavingItFilled() async {
        let writes = FakePostWrites()
        writes.fail("bookmark", with: .rateLimited)
        let model = PostActionsViewModel(
            post: Self.post(), uid: "user-1", writes: writes, pins: StubPins()
        )

        await model.toggleBookmark()

        #expect(!model.isBookmarked, """
            A filled bookmark with no write behind it is the same defect the \
            like path had: the tap looks like it worked and nothing happened.
            """)
        #expect(model.failureMessage == "Too many posts just now. Wait a moment.")
    }

    @Test func savingAPostThatHasBeenDeletedSaysSoAndDoesNotLookSaved() async {
        let writes = FakePostWrites()
        try? await writes.delete(postID: "post-1")
        let model = PostActionsViewModel(
            post: Self.post(), uid: "user-1", writes: writes, pins: StubPins()
        )

        await model.toggleBookmark()

        #expect(!model.isBookmarked)
        #expect(model.failureMessage == "That post no longer exists.")
    }
}
