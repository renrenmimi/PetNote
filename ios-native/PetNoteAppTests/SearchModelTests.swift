import Foundation
import Testing

@testable import PetNote

/// Typing into search: what is asked, what is shown, and what is not.
@MainActor
struct SearchModelTests {
    private func model(
        _ repository: FakeSearchRepository,
        social: FakeSocialRepository = FakeSocialRepository(),
        initialTag: String? = nil
    ) -> SearchModel {
        SearchModel(
            viewerID: "me", search: repository,
            blockList: BlockList(viewerID: "me", social: social),
            initialTag: initialTag, debounce: .milliseconds(1)
        )
    }

    @Test func aPlainQueryAsksForPeoplePetsTagsAndTaggedPosts() async {
        let repository = FakeSearchRepository()
        repository.peopleResult = [SocialFixture.profile("u1")]
        repository.postResult = [SocialFixture.post("p1")]
        let search = model(repository)

        search.query = "  Cat "
        await search.searchNow()

        #expect(repository.peopleQueries == ["cat"])
        #expect(repository.postQueries.first?.tag == "cat")
        #expect(repository.postQueries.first?.limit == SearchModel.textPostLimit)
        #expect(search.visiblePeople.map(\.id) == ["u1"])
        #expect(search.visiblePosts.map(\.id) == ["p1"])
        #expect(search.hasAnyResult)
    }

    @Test func aHashQueryIsATagSearch() async {
        let repository = FakeSearchRepository()
        let search = model(repository)

        search.query = "#Poodle"
        await search.searchNow()

        #expect(repository.postQueries.first?.tag == "poodle")
        #expect(repository.postQueries.first?.limit == SearchModel.tagPostLimit)
        #expect(search.activeTag == "poodle")
    }

    @Test func aLoneHashAsksNothingAndFindsNothing() async {
        let repository = FakeSearchRepository()
        let search = model(repository)

        search.query = "#"
        await search.searchNow()

        #expect(repository.peopleQueries.isEmpty)
        #expect(search.state == .loaded(.empty))
        #expect(!search.hasAnyResult)
    }

    /// Losing the connection must not read as "nothing matches".
    @Test func aFailedSearchIsNotAnEmptyOne() async {
        let repository = FakeSearchRepository()
        repository.searchError = SocialError.offline
        let search = model(repository)

        search.query = "cat"
        await search.searchNow()

        #expect(search.state == .failed)
    }

    /// Under a `#tag` search that tag's posts are already on screen; listing
    /// it again under Tags was redundant and re-tapping it did nothing.
    @Test func theActiveTagIsNotListedAgain() async {
        let repository = FakeSearchRepository()
        repository.tagResult = [
            Hashtag(name: "dog", postCount: 3), Hashtag(name: "doggo", postCount: 9),
        ]
        let search = model(repository)

        search.query = "#dog"
        await search.searchNow()

        #expect(search.visibleTags.map(\.name) == ["doggo"])
    }

    @Test func postsByBlockedPeopleAreNotShownAndFiveAtMost() async {
        let repository = FakeSearchRepository()
        repository.postResult = (1...8).map {
            SocialFixture.post("p\($0)", author: $0 == 2 ? "blocked" : "alice")
        }
        let social = FakeSocialRepository()
        social.blocked = ["blocked"]
        let search = model(repository, social: social)

        search.query = "cat"
        await search.searchNow()

        #expect(search.visiblePosts.map(\.id) == ["p1", "p3", "p4", "p5", "p6"])
    }

    @Test func threePeopleUntilAskedForAll() async {
        let repository = FakeSearchRepository()
        repository.peopleResult = (1...5).map { SocialFixture.profile("u\($0)") }
        let search = model(repository)

        search.query = "u"
        await search.searchNow()
        #expect(search.visiblePeople.count == 3)
        #expect(search.canExpandPeople)

        search.showAllPeople = true
        #expect(search.visiblePeople.count == 5)
    }

    @Test func petCountsArriveAfterThePeople() async {
        let repository = FakeSearchRepository()
        repository.peopleResult = [SocialFixture.profile("u1"), SocialFixture.profile("u2")]
        repository.counts = ["u1": 2, "u2": 0]
        let search = model(repository)

        search.query = "u"
        await search.searchNow()

        #expect(repository.countQueries == [["u1", "u2"]])
        #expect(search.petCounts == ["u1": 2, "u2": 0])
    }

    /// A count that could not be read is left out, not shown as "0 pets".
    @Test func aFailedPetCountLeavesTheCountsOut() async {
        let repository = FakeSearchRepository()
        repository.peopleResult = [SocialFixture.profile("u1")]
        repository.countsError = SocialFixture.readFailure
        let search = model(repository)

        search.query = "u"
        await search.searchNow()

        #expect(search.petCounts.isEmpty)
        #expect(search.visiblePeople.map(\.id) == ["u1"])
    }

    /// An older answer that arrives after a newer question must not replace
    /// the newer answer.
    @Test func aSlowOlderSearchCannotOverwriteANewerOne() async {
        let repository = FakeSearchRepository()
        let gate = SocialGate()
        repository.peopleGate = gate
        repository.peopleResult = [SocialFixture.profile("old")]
        let search = model(repository)

        search.query = "old"
        let slow = Task { await search.searchNow() }
        await socialEventually { repository.peopleQueries.count == 1 }

        repository.peopleResult = [SocialFixture.profile("new")]
        search.query = "new"
        await search.searchNow()
        gate.open()
        await slow.value

        #expect(search.searchedQuery == "new")
        #expect(search.visiblePeople.map(\.id) == ["new"])
    }

    @Test func typingWaitsAndThenSearchesOnce() async {
        let repository = FakeSearchRepository()
        let search = model(repository)

        search.query = "c"
        search.queryChanged()
        search.query = "ca"
        search.queryChanged()
        search.query = "cat"
        search.queryChanged()
        await search.settle()

        #expect(repository.peopleQueries == ["cat"])
    }

    /// A tag chip sets the field; the field's own change must not ask the
    /// same question a second time.
    @Test func selectingATagSearchesOnceAndReselectingDoesNothing() async {
        let repository = FakeSearchRepository()
        let search = model(repository)

        await search.select(tag: "dog")
        search.queryChanged()
        await search.settle()
        await search.select(tag: "dog")

        #expect(search.query == "#dog")
        #expect(repository.peopleQueries == ["dog"])
    }

    @Test func clearingReturnsToDiscovery() async {
        let repository = FakeSearchRepository()
        let search = model(repository)
        search.query = "cat"
        await search.searchNow()

        search.clear()

        #expect(search.state == .idle)
        #expect(!search.hasQuery)
    }

    @Test func aTagHandedInBecomesTheQuery() {
        let search = model(FakeSearchRepository(), initialTag: "#Shiba ")
        #expect(search.query == "#shiba")
    }
}

/// Discovery, before anything is typed.
@MainActor
struct SearchExploreTests {
    private func model(
        _ repository: FakeSearchRepository,
        social: FakeSocialRepository = FakeSocialRepository(),
        now: Date = SocialFixture.date
    ) -> ExploreModel {
        ExploreModel(
            viewerID: "me", search: repository, social: social,
            blockList: BlockList(viewerID: "me", social: social), now: { now }
        )
    }

    /// One module failing must not empty the others.
    @Test func oneModuleFailingLeavesTheOthersOnScreen() async {
        let repository = FakeSearchRepository()
        repository.popularTagError = SocialFixture.readFailure
        repository.recentPosts = [SocialFixture.post("p1")]
        repository.byFollowers = [SocialFixture.pet("pet-a")]
        let explore = model(repository)

        await explore.load()

        #expect(explore.failed == [.tags])
        #expect(explore.trendingPosts.map(\.id) == ["p1"])
        #expect(explore.discoverPets.map(\.id) == ["pet-a"])

        repository.popularTagError = nil
        repository.popularTagResult = [Hashtag(name: "dog", postCount: 1)]
        await explore.retry(.tags)
        #expect(explore.failed.isEmpty)
        #expect(explore.tags.map(\.name) == ["dog"])
    }

    @Test func trendingIsTheLastWeekMostLikedFirst() async {
        let repository = FakeSearchRepository()
        repository.recentPosts = [
            SocialFixture.post("low", likes: 1),
            SocialFixture.post("high", likes: 9),
            SocialFixture.post("tieOld", likes: 5, createdAt: SocialFixture.date),
            SocialFixture.post("tieNew", likes: 5, createdAt: SocialFixture.date.addingTimeInterval(60)),
        ]
        let now = SocialFixture.date.addingTimeInterval(3600)
        let explore = model(repository, now: now)

        await explore.load()

        #expect(repository.sinceQueries.first?.date == now.addingTimeInterval(-7 * 24 * 3600))
        #expect(repository.sinceQueries.first?.limit == 90)
        #expect(explore.trendingPosts.map(\.id) == ["high", "tieNew", "tieOld", "low"])
    }

    @Test func suggestionsLeaveOutPetsAlreadyFollowed() async {
        let repository = FakeSearchRepository()
        repository.byFollowers = ["a", "b", "c"].map { SocialFixture.pet($0) }
        let social = FakeSocialRepository()
        social.followedPetsList = [
            FollowedPet(id: "b", petName: "B", petAvatarURL: nil, followedAt: nil),
        ]
        let explore = model(repository, social: social)

        await explore.load()

        #expect(explore.discoverPets.map(\.id) == ["a", "c"])
    }

    @Test func aSuggestedPetOfTheViewersOwnHasNoFollowButton() async {
        let repository = FakeSearchRepository()
        repository.byFollowers = ["mine", "theirs"].map { SocialFixture.pet($0) }
        let social = FakeSocialRepository()
        social.familyMemberships = ["mine"]
        let explore = model(repository, social: social)

        await explore.load()

        #expect(explore.followModels["mine"]?.offersControl == false)
        #expect(explore.followModels["theirs"]?.status == .notFollowing)
    }

    /// Fewer than eight pets with a stored count: the newest posts are
    /// counted per pet to fill the rest, and the number shown is the one
    /// ranked on.
    @Test func popularPetsFallBackToCountingRecentPosts() async {
        let repository = FakeSearchRepository()
        repository.byPostCount = [
            SocialFixture.pet("stored", posts: 4), SocialFixture.pet("zero", posts: 0),
        ]
        repository.latest = [
            SocialFixture.post("1", petID: "x"), SocialFixture.post("2", petID: "y"),
            SocialFixture.post("3", petID: "y"), SocialFixture.post("4", petID: "stored"),
            SocialFixture.post("5", petID: nil),
        ]
        repository.petsByID = ["x": SocialFixture.pet("x"), "y": SocialFixture.pet("y")]
        let explore = model(repository)

        await explore.load()

        #expect(explore.popularPets.map(\.id) == ["stored", "y", "x"])
        #expect(explore.popularPets.map(\.postCount) == [4, 2, 1])
    }

    @Test func popularPetsDoNotReadPostsWhenStoredCountsSuffice() async {
        let repository = FakeSearchRepository()
        repository.byPostCount = (1...8).map { SocialFixture.pet("p\($0)", posts: 10 - $0) }
        let explore = model(repository)

        await explore.load()

        #expect(repository.latestReads == 0)
        #expect(explore.popularPets.count == 8)
    }

    /// With a small catalogue both rankings resolve to the same animals; the
    /// second section appears only with three pets the first does not show.
    @Test func mostPostsAppearsOnlyWithThreePetsNotAlreadyShown() async {
        let repository = FakeSearchRepository()
        repository.byFollowers = ["a", "b"].map { SocialFixture.pet($0) }
        repository.byPostCount = ["a", "b", "c", "d"].map { SocialFixture.pet($0, posts: 3) }
        let explore = model(repository)

        await explore.load()
        #expect(explore.alsoActivePets.map(\.id) == ["c", "d"])
        #expect(!explore.showsAlsoActive)

        repository.byPostCount.append(SocialFixture.pet("e", posts: 1))
        await explore.retry(.popularPets)
        #expect(explore.showsAlsoActive)
    }

    @Test func theTagHeadingIsEarnedByTheCounts() {
        #expect(SearchLogic.tagHeading([Hashtag(name: "a", postCount: 5)]) == "Popular Tags")
        #expect(SearchLogic.tagHeading([Hashtag(name: "a", postCount: 4)]) == "Tags in use")
        #expect(SearchLogic.tagHeading([]) == "Tags in use")
        #expect(SearchLogic.postCountLabel(1) == "1 post")
        #expect(SearchLogic.postCountLabel(2) == "2 posts")
    }

    @Test func petMatchesAreMergedLowerCaseFirstAndOnce() {
        let merged = SearchLogic.mergePets(
            lower: [SocialFixture.pet("a"), SocialFixture.pet("b")],
            exact: [SocialFixture.pet("b"), SocialFixture.pet("c")],
            limit: 10
        )
        #expect(merged.map(\.id) == ["a", "b", "c"])
        #expect(SearchLogic.mergePets(lower: merged, exact: [], limit: 2).count == 2)
    }

    @Test func tagsAreSortedByCountStably() {
        let sorted = SearchLogic.sortTags([
            Hashtag(name: "a", postCount: 1), Hashtag(name: "b", postCount: 5),
            Hashtag(name: "c", postCount: 1),
        ])
        #expect(sorted.map(\.name) == ["b", "a", "c"])
    }
}
