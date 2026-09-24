import Foundation
import Testing

@testable import PetNote

/// Blocking: the write, the pets that stop being followed, the feed that
/// stops showing the person, and the list that undoes it.
@MainActor
struct BlockingTests {
    private func followed(_ id: String) -> FollowedPet {
        FollowedPet(id: id, petName: id, petAvatarURL: nil, followedAt: nil)
    }

    // MARK: - The block and its one side effect

    /// Only a pet that was theirs *alone*. Following a pet somebody else
    /// also owns is not following the blocked person.
    @Test func onlyPetsTheyAloneOwnAreUnfollowed() async throws {
        let social = FakeSocialRepository()
        social.followedPetsList = [followed("theirs"), followed("shared"), followed("unrelated")]
        let pets = FakeFamilyPets()
        pets.familiesByPet = [
            "theirs": [SocialFixture.member("bob", role: .primary)],
            "shared": [SocialFixture.member("bob", role: .primary), SocialFixture.member("carol")],
            "unrelated": [SocialFixture.member("dave", role: .primary)],
        ]

        let unfollowed = try await Blocking.block("bob", viewerID: "me", social: social, pets: pets)

        #expect(social.blockedNow == ["bob"])
        #expect(unfollowed == ["theirs"])
        #expect(social.unfollowCalls == ["theirs"])
    }

    @Test func aFailedBlockUnfollowsNothing() async {
        let social = FakeSocialRepository()
        social.blockError = SocialError.denied
        social.followedPetsList = [followed("theirs")]
        let pets = FakeFamilyPets()
        pets.familiesByPet = ["theirs": [SocialFixture.member("bob", role: .primary)]]

        await #expect(throws: SocialError.self) {
            try await Blocking.block("bob", viewerID: "me", social: social, pets: pets)
        }
        #expect(social.unfollowCalls.isEmpty)
    }

    /// The block is what was asked for, and it happened. Not being able to
    /// tidy the follows afterwards does not undo it or report it as failed.
    @Test func theBlockStandsWhenTheFollowsCannotBeRead() async throws {
        let social = FakeSocialRepository()
        social.followedPetsError = SocialError.offline
        let unfollowed = try await Blocking.block(
            "bob", viewerID: "me", social: social, pets: FakeFamilyPets()
        )
        #expect(social.blockedNow == ["bob"])
        #expect(unfollowed.isEmpty)
    }

    // MARK: - The feed

    final class PagedFeed: FeedRepository, @unchecked Sendable {
        var pages: [[Post]] = []
        private(set) var reads = 0
        private var cursors: [PageCursor] = []

        func posts(after cursor: PageCursor?, limit: Int) async throws -> Page<Post> {
            reads += 1
            let index = cursor.flatMap { cursors.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            guard index < pages.count else { return .empty }
            let next: PageCursor? = index + 1 < pages.count ? PageCursor() : nil
            if let next { cursors.append(next) }
            return Page(items: pages[index], next: next)
        }

        func post(id: String) async throws -> Post? { pages.flatMap { $0 }.first { $0.id == id } }
    }

    private func post(_ id: String, by author: String) -> Post {
        Post(
            id: id, authorID: author, authorName: author, authorAvatarURL: nil,
            text: "TEST CONTENT \(id)", media: [], petID: nil, petName: nil,
            petAvatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            likeCount: 0, commentCount: 0, tags: []
        )
    }

    @Test func aBlockedAuthorsPostsAreLeftOut() async throws {
        let base = PagedFeed()
        base.pages = [[post("a", by: "alice"), post("b", by: "bob"), post("c", by: "carol")]]
        let social = FakeSocialRepository()
        social.blocked = ["bob"]
        let feed = BlockFilteringFeed(base: base, social: social, viewerID: "me")

        let page = try await feed.posts(after: nil, limit: 3)

        #expect(page.items.map(\.id) == ["a", "c"])
    }

    /// The case that would stall the list: a page that the filter empties,
    /// with more behind it. The model would get nothing to show and no row
    /// whose appearance asks for more.
    @Test func aPageTheFilterEmptiesIsFollowedByTheNextOne() async throws {
        let base = PagedFeed()
        base.pages = [
            [post("b1", by: "bob"), post("b2", by: "bob")],
            [post("a", by: "alice")],
        ]
        let social = FakeSocialRepository()
        social.blocked = ["bob"]
        let feed = BlockFilteringFeed(base: base, social: social, viewerID: "me")

        let page = try await feed.posts(after: nil, limit: 2)

        #expect(page.items.map(\.id) == ["a"])
        #expect(base.reads == 2)
    }

    @Test func withNobodyBlockedTheFeedIsReadOnceAsItIs() async throws {
        let base = PagedFeed()
        base.pages = [[post("a", by: "alice")]]
        let feed = BlockFilteringFeed(base: base, social: FakeSocialRepository(), viewerID: "me")

        let page = try await feed.posts(after: nil, limit: 1)

        #expect(page.items.map(\.id) == ["a"])
        #expect(base.reads == 1)
    }

    /// As on the web: not knowing who is blocked filters nothing, rather than
    /// showing an empty feed.
    @Test func anUnreadableBlockListFiltersNothing() async throws {
        let base = PagedFeed()
        base.pages = [[post("b", by: "bob")]]
        let social = FakeSocialRepository()
        social.blocked = ["bob"]
        social.blockedError = SocialError.offline
        let feed = BlockFilteringFeed(base: base, social: social, viewerID: "me")

        #expect(try await feed.posts(after: nil, limit: 1).items.map(\.id) == ["b"])
    }

    /// A new block takes effect on the next read, not the next launch.
    @Test func invalidatingRereadsTheBlockList() async throws {
        let base = PagedFeed()
        base.pages = [[post("b", by: "bob")]]
        let social = FakeSocialRepository()
        let feed = BlockFilteringFeed(base: base, social: social, viewerID: "me")
        #expect(try await feed.posts(after: nil, limit: 1).items.count == 1)

        social.blocked = ["bob"]
        #expect(try await feed.posts(after: nil, limit: 1).items.count == 1, "cached until told")
        await feed.invalidate()
        #expect(try await feed.posts(after: nil, limit: 1).items.isEmpty)
    }

    // MARK: - One read of the list at a time

    /// Waits, by the clock as `eventuallyTrue` does, for a number only the
    /// filter's own actor can give.
    private func waitForCallers(_ count: Int, on feed: BlockFilteringFeed) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if await feed.callersWaitingOnRead == count { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await feed.callersWaitingOnRead == count
    }

    /// Two callers while the list is being read — on a cold start, the feed's
    /// first page and the spotlight row — share that one read, and the one
    /// read fills the cache for both.
    @Test func callersWhileTheListIsBeingReadShareTheOneRead() async {
        let social = FakeSocialRepository()
        let gate = SocialGate()
        // A second entry, so a second read — the defect — would answer
        // differently and on the same gate, rather than hang the test.
        social.blockedReadScript = [(answer: ["bob"], gate: gate), (answer: ["a second read"], gate: gate)]
        let feed = BlockFilteringFeed(base: PagedFeed(), social: social, viewerID: "me")

        let first = Task { await feed.blockedIDs() }
        let second = Task { await feed.blockedIDs() }
        let bothWaiting = await waitForCallers(2, on: feed)
        gate.open()
        let firstAnswer = await first.value
        let secondAnswer = await second.value

        #expect(bothWaiting, "the second caller never arrived while the read was out")
        #expect(social.blockedReadCount == 1, "two callers at once read the list twice")
        #expect(firstAnswer == ["bob"])
        #expect(secondAnswer == ["bob"])
        #expect(await feed.blockedIDs() == ["bob"])
        #expect(social.blockedReadCount == 1, "the shared read did not fill the cache")
    }

    /// A read that went out before a block answers the caller who asked for
    /// it, but the list it brings back is from before the block, and it must
    /// not land in the cache on top of the one read after it.
    @Test func aReadFromBeforeABlockDoesNotRefillTheCacheAfterIt() async {
        let social = FakeSocialRepository()
        let before = SocialGate()
        let after = SocialGate()
        after.open()
        social.blockedReadScript = [(answer: [], gate: before), (answer: ["bob"], gate: after)]
        let feed = BlockFilteringFeed(base: PagedFeed(), social: social, viewerID: "me")

        let stale = Task { await feed.blockedIDs() }
        let staleIsOut = await eventuallyTrueAnywhere { social.blockedReadCount == 1 }
        await feed.invalidate()
        let fresh = Task { await feed.blockedIDs() }
        let freshAsked = await eventuallyTrueAnywhere { social.blockedReadCount == 2 }
        // A caller that wrongly joined the old read would wait on its gate
        // for ever; let it through, so the test fails rather than hangs.
        if !freshAsked { before.open() }
        let freshAnswer = await fresh.value
        before.open()
        let staleAnswer = await stale.value

        #expect(staleIsOut)
        #expect(freshAsked, "the caller after the block joined the read from before it")
        #expect(freshAnswer == ["bob"])
        #expect(staleAnswer == [], "the control: the old read answers its own caller with what it read")
        #expect(await feed.blockedIDs() == ["bob"], "the read from before the block overwrote the list after it")
        #expect(social.blockedReadCount == 2, "the list after the block was not kept")
    }

    /// The same for a switch of account: the previous person's list, arriving
    /// late, is not kept as the next person's.
    @Test func aReadForThePreviousAccountIsNotKeptForTheNextOne() async {
        let social = FakeSocialRepository()
        social.blocked = ["carol"]
        let gate = SocialGate()
        social.blockedReadScript = [(answer: ["bob"], gate: gate)]
        let feed = BlockFilteringFeed(base: PagedFeed(), social: social, viewerID: "alice")

        let previous = Task { await feed.blockedIDs() }
        let isOut = await eventuallyTrueAnywhere { social.blockedReadCount == 1 }
        await feed.switchAccount(to: "dana")
        gate.open()
        let previousAnswer = await previous.value

        #expect(isOut)
        #expect(previousAnswer == ["bob"], "the control: alice's read answers alice's caller")
        #expect(await feed.blockedIDs() == ["carol"], "alice's block list was kept as dana's")
        #expect(social.blockedReadCount == 2)
    }

    // MARK: - The list

    @Test func unblockingTakesThePersonOffTheList() async {
        let social = FakeSocialRepository()
        social.blocked = ["bob", "carol"]
        let model = BlockedUsersModel(viewerID: "me", social: social)
        await model.load()
        guard case .loaded(let rows) = model.state else { Issue.record("not loaded: \(model.state)"); return }
        #expect(rows.map(\.id) == ["bob", "carol"])

        let gone = await model.unblock("bob")

        #expect(gone)
        #expect(social.unblocked == ["bob"])
        guard case .loaded(let after) = model.state else { Issue.record("not loaded"); return }
        #expect(after.map(\.id) == ["carol"])
    }

    @Test func aFailedUnblockKeepsTheRowAndSaysSo() async {
        let social = FakeSocialRepository()
        social.blocked = ["bob"]
        social.unblockError = SocialError.offline
        let model = BlockedUsersModel(viewerID: "me", social: social)
        await model.load()

        let gone = await model.unblock("bob")

        #expect(!gone)
        guard case .loaded(let rows) = model.state else { Issue.record("not loaded"); return }
        #expect(rows.map(\.id) == ["bob"])
        #expect(model.failures["bob"] != nil)
    }
}
