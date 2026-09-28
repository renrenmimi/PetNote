import Foundation
import Testing

@testable import PetNote

/// The saved-posts list, by the web client's `getBookmarkedPosts`: newest
/// bookmark first, posts fetched in batches of ten, deleted posts left out.
@MainActor
struct SavedPostsTests {
    final class FakeSource: SavedPostsReading, @unchecked Sendable {
        var answers: [Result<[Post], Error>] = []
        private(set) var calls: [(uid: String, limit: Int)] = []

        func savedPosts(uid: String, limit: Int) async throws -> [Post] {
            calls.append((uid, limit))
            guard !answers.isEmpty else { return [] }
            return try answers.removeFirst().get()
        }
    }

    private static func post(_ id: String) -> Post {
        Post(
            id: id, authorID: "a", authorName: "A", authorAvatarURL: nil,
            text: "TEST CONTENT \(id)", media: [], petID: nil, petName: nil,
            petAvatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            likeCount: 0, commentCount: 0, tags: []
        )
    }

    // MARK: - The query's shape

    /// Firestore's `in` takes a bounded list; the web client asks ten at a
    /// time, and so does this.
    @Test func idsAreAskedForTenAtATime() {
        let ids = (1...23).map { "p\($0)" }
        let batches = SavedPostsModel.batches(of: ids, size: 10)
        #expect(batches.map(\.count) == [10, 10, 3])
        #expect(batches.flatMap { $0 } == ids, "an id was lost or repeated between batches")
        #expect(SavedPostsModel.batches(of: [], size: 10).isEmpty, "no bookmarks must mean no post query")
    }

    /// The batches come back in the server's order, not the bookmarks'. The
    /// list is the bookmarks' order, and a bookmark whose post is gone is
    /// simply not in it.
    @Test func theListIsInBookmarkOrderAndSkipsDeletedPosts() {
        let found = ["p3": Self.post("p3"), "p1": Self.post("p1")]
        let listed = SavedPostsModel.ordered(found, by: ["p1", "p2-deleted", "p3"])
        #expect(listed.map(\.id) == ["p1", "p3"])
    }

    // MARK: - The screen's states

    @Test func loadsTheWebClientsPageForTheSignedInPerson() async {
        let source = FakeSource()
        source.answers = [.success([Self.post("p1"), Self.post("p2")])]
        let model = SavedPostsModel(uid: "me", source: source)

        await model.load()

        #expect(model.state == .loaded([Self.post("p1"), Self.post("p2")]))
        #expect(source.calls.map { $0.uid } == ["me"])
        #expect(source.calls.map { $0.limit } == [50])
    }

    @Test func nothingSavedIsAnEmptyListNotAFailure() async {
        let source = FakeSource()
        source.answers = [.success([])]
        let model = SavedPostsModel(uid: "me", source: source)

        await model.load()
        #expect(model.state == .loaded([]))
    }

    @Test func aFirstLoadThatFailsSaysSoAndCanBeRetried() async {
        let source = FakeSource()
        source.answers = [.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)),
                          .success([Self.post("p1")])]
        let model = SavedPostsModel(uid: "me", source: source)

        await model.load()
        #expect(model.state == .failed("Couldn't load your saved posts."))

        await model.load()
        #expect(model.state == .loaded([Self.post("p1")]))
    }

    /// Coming back to the list re-reads it. If that read fails, the list that
    /// was on screen stays — blanking it would be worse than showing it a
    /// little out of date — and the screen says it could not refresh.
    @Test func aReloadThatFailsKeepsTheListAndSaysItMayBeStale() async {
        let source = FakeSource()
        source.answers = [.success([Self.post("p1")]),
                          .failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)),
                          .success([])]
        let model = SavedPostsModel(uid: "me", source: source)

        await model.load()
        await model.load()
        #expect(model.state == .loaded([Self.post("p1")]))
        #expect(model.refreshFailed)

        // Unsaved elsewhere; the next read shows it gone and clears the notice.
        await model.load()
        #expect(model.state == .loaded([]))
        #expect(!model.refreshFailed)
    }
}
