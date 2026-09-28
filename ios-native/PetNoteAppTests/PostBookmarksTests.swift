import Foundation
import Testing

@testable import PetNote

/// `FakePostWrites` with gates: a save, or a read of saved state, that waits
/// until the test lets it answer, so "a second tap while the first is out"
/// and "a read that left before a write" can be arranged rather than hoped for.
private final class GatedPostWrites: PostWriteRepository, @unchecked Sendable {
    let inner = FakePostWrites()
    private let lock = NSLock()
    private var saveGate: SocialGate?
    private var readGate: SocialGate?
    private(set) var saveCalls = 0

    func holdSaves(on gate: SocialGate) { lock.withLock { saveGate = gate } }
    func holdReads(on gate: SocialGate) { lock.withLock { readGate = gate } }
    var saves: Int { lock.withLock { saveCalls } }

    func publish(_ request: PublishRequest) async throws -> PublishOutcome { try await inner.publish(request) }
    func publishStatus(operationID: String) async throws -> PublishStatus {
        try await inner.publishStatus(operationID: operationID)
    }
    func update(postID: String, text: String, tags: [String], petID: String) async throws {
        try await inner.update(postID: postID, text: text, tags: tags, petID: petID)
    }
    func delete(postID: String) async throws { try await inner.delete(postID: postID) }
    func setPinned(postID: String?) async throws { try await inner.setPinned(postID: postID) }

    func bookmark(postID: String) async throws -> BookmarkResult {
        let gate = lock.withLock { () -> SocialGate? in saveCalls += 1; return saveGate }
        if let gate { await gate.wait() }
        return try await inner.bookmark(postID: postID)
    }
    func unbookmark(postID: String) async throws -> BookmarkResult {
        let gate = lock.withLock { () -> SocialGate? in saveCalls += 1; return saveGate }
        if let gate { await gate.wait() }
        return try await inner.unbookmark(postID: postID)
    }
    func isBookmarked(postID: String) async throws -> Bool { try await inner.isBookmarked(postID: postID) }

    /// Answers with the state as it was when the read went out, as a real
    /// read in flight does.
    func bookmarkedPostIDs(among postIDs: [String]) async throws -> Set<String> {
        let answer = try await inner.bookmarkedPostIDs(among: postIDs)
        let gate = lock.withLock { readGate }
        if let gate { await gate.wait() }
        return answer
    }
}

@MainActor
struct PostBookmarksTests {
    // MARK: - Reading

    /// One read for a page, and none again for what is already known.
    @Test func aPageIsOneReadAndKnownPostsAreNotReadAgain() async throws {
        let writes = FakePostWrites()
        _ = try await writes.bookmark(postID: "b")
        let bookmarks = PostBookmarks(writes: writes)

        await bookmarks.load(["a", "b", "c"])
        #expect(writes.bookmarkStatusReads.count == 1)
        #expect(Set(writes.bookmarkStatusReads[0]) == ["a", "b", "c"])
        #expect(bookmarks.isSaved("b"))
        #expect(!bookmarks.isSaved("a"))

        await bookmarks.load(["a", "b", "d"])
        #expect(writes.bookmarkStatusReads.count == 2)
        #expect(writes.bookmarkStatusReads[1] == ["d"])

        await bookmarks.load(["a", "d"])
        #expect(writes.bookmarkStatusReads.count == 2, "nothing new to read")
    }

    /// A failed read leaves the posts unknown, so the next page asks again.
    @Test func aFailedReadIsAskedAgain() async {
        let writes = FakePostWrites()
        writes.fail("bookmarkStatus", with: .transport("offline"))
        let bookmarks = PostBookmarks(writes: writes)
        await bookmarks.load(["a"])
        writes.stopFailing("bookmarkStatus")
        await bookmarks.load(["a"])
        #expect(writes.bookmarkStatusReads.count == 2)
    }

    // MARK: - Saving

    @Test func aSaveShowsAtOnceAndStands() async {
        let writes = FakePostWrites()
        let bookmarks = PostBookmarks(writes: writes)
        let now = await bookmarks.toggle("a")
        #expect(now)
        #expect(bookmarks.isSaved("a"))
        #expect(writes.bookmarkedPostIDs == ["a"])
        #expect(bookmarks.failureMessage == nil)

        let after = await bookmarks.toggle("a")
        #expect(!after)
        #expect(writes.bookmarkedPostIDs.isEmpty)
    }

    /// Saving a post the server already has saved is success, not a failure.
    @Test func savingWhatIsAlreadySavedIsNotAFailure() async throws {
        let writes = FakePostWrites()
        _ = try await writes.bookmark(postID: "a")
        let bookmarks = PostBookmarks(writes: writes)
        // Not loaded yet, so the button says "not saved"; the tap saves.
        #expect(await bookmarks.toggle("a"))
        #expect(bookmarks.failureMessage == nil)
    }

    @Test func aFailedSaveGoesBackAndSaysSo() async {
        let writes = FakePostWrites()
        writes.fail("bookmark", with: .transport("offline"))
        let bookmarks = PostBookmarks(writes: writes)
        let now = await bookmarks.toggle("a")
        #expect(!now)
        #expect(!bookmarks.isSaved("a"))
        #expect(bookmarks.failureMessage != nil)
    }

    @Test func aPostThatIsGoneIsNotLeftLookingSaved() async throws {
        let writes = FakePostWrites()
        try await writes.delete(postID: "gone")
        let bookmarks = PostBookmarks(writes: writes)
        let now = await bookmarks.toggle("gone")
        #expect(!now)
        #expect(!bookmarks.isSaved("gone"))
        #expect(bookmarks.failureMessage == String(localized: "That post no longer exists."))
    }

    /// Two taps, one write: the second waits for the first to be answered.
    @Test func aSecondTapWhileTheFirstIsOutIsNotASecondWrite() async {
        let writes = GatedPostWrites()
        let gate = SocialGate()
        writes.holdSaves(on: gate)
        let bookmarks = PostBookmarks(writes: writes)

        let first = Task { await bookmarks.toggle("a") }
        await socialEventually { bookmarks.isPending("a") }
        let second = await bookmarks.toggle("a")
        #expect(second, "the second tap reports the state the first asked for")
        gate.open()
        #expect(await first.value)
        #expect(writes.saves == 1)
        #expect(bookmarks.isSaved("a"))
    }

    /// A read that left before a save must not put the old state back —
    /// whether it answers while the save is out or after it has landed.
    @Test func aReadFromBeforeASaveDoesNotUndoIt() async {
        let writes = GatedPostWrites()
        let readGate = SocialGate()
        writes.holdReads(on: readGate)
        let bookmarks = PostBookmarks(writes: writes)

        let read = Task { await bookmarks.load(["a"]) }
        await socialEventually { writes.inner.bookmarkStatusReads.count == 1 }
        #expect(await bookmarks.toggle("a"))
        readGate.open()
        await read.value

        #expect(bookmarks.isSaved("a"), "the read's older answer undid the save")
    }
}
