import SwiftUI
import Testing
import UIKit

@testable import PetNote

/// The social screens drawn, in light and dark and at the largest text size,
/// with long names — rendered with `ImageRenderer`, the same way
/// `SnapshotTests` draws the token showcase.
///
/// **What this proves and what it does not.** It proves the loaded screens lay
/// out at a phone's width without clipping their text: at the largest
/// accessibility size every one of them grows taller instead of cutting lines
/// off. It proves nothing about taps, scrolling, VoiceOver order or a real
/// device — the renderer draws a still frame and runs no `.task`. The PNGs are
/// written to `build/social-renders/` (git-ignored) so a person can look at
/// them; they are not baselines.
@MainActor
struct SocialRenderTests {
    nonisolated private static let width: CGFloat = 402

    private static var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/social-renders")
    }

    private func render(
        _ view: some View, named name: String, scheme: ColorScheme, size: DynamicTypeSize
    ) throws -> CGSize {
        let renderer = ImageRenderer(
            content: view
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, size)
                .frame(width: Self.width)
                .background(Palette.background)
        )
        renderer.scale = 2
        let image = try #require(renderer.uiImage, "\(name) did not render")
        let directory = Self.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = image.pngData() {
            try data.write(to: directory.appendingPathComponent("\(name).png"))
        }
        return image.size
    }

    struct Sizes {
        let light: CGSize
        let dark: CGSize
        let largest: CGSize
        var isPhoneWidth: Bool { light.width == SocialRenderTests.width }
        /// Dark mode changes colours, never the layout.
        var darkMatchesLight: Bool { dark == light }
        /// At the largest text size the screen grows instead of clipping.
        var grewAtLargestSize: Bool { largest.height > light.height }
    }

    /// Renders at the default and the largest size, in both schemes.
    private func renders(_ make: () -> some View, named name: String) throws -> Sizes {
        Sizes(
            light: try render(make(), named: "\(name)-light", scheme: .light, size: .large),
            dark: try render(make(), named: "\(name)-dark", scheme: .dark, size: .large),
            largest: try render(make(), named: "\(name)-ax5", scheme: .light, size: .accessibility5)
        )
    }

    // MARK: - Fixtures with long names

    private static let longName = "Maximilian Bartholomew-Featherstonehaugh the Third"

    private func familyModels() async -> (FamilyModel, InviteModel) {
        let pets = FakeFamilyPets()
        pets.pet = SocialFixture.pet("pet-1", name: "Sir Reginald Fluffington", ownerID: "me")
        pets.family = [
            PetFamilyMember(
                id: "me", userName: "Me", userAvatarURL: nil, relationship: .mom,
                customRelationship: nil, role: .primary, joinedAt: SocialFixture.date
            ),
            PetFamilyMember(
                id: "bob", userName: Self.longName, userAvatarURL: nil, relationship: .other,
                customRelationship: "Weekend dog walker", role: .member, joinedAt: SocialFixture.date
            ),
        ]
        let repository = FakeFamilyRepository()
        repository.active = SocialFixture.invitation()
        let family = FamilyModel(petID: "pet-1", viewerID: "me", pets: pets, family: repository)
        let invite = InviteModel(petID: "pet-1", repository: repository)
        await family.load()
        await invite.load()
        return (family, invite)
    }

    // MARK: - Screens

    @Test func theOwnersScreenGrowsWithTheText() async throws {
        let (family, invite) = await familyModels()
        #expect(family.state == .loaded)
        let sizes = try renders({
            FamilyView(model: family, invite: invite, onOpenUser: { _ in }, onLeft: {})
        }, named: "family")
        #expect(sizes.isPhoneWidth)
        #expect(sizes.darkMatchesLight, "dark mode changed the layout, not only the colours")
        #expect(sizes.grewAtLargestSize, "the largest text size did not make the screen taller")
    }

    @Test func somebodysProfileGrowsWithTheText() async throws {
        let social = FakeSocialRepository()
        social.profiles["alice"] = PublicProfile(
            id: "alice", displayName: Self.longName, avatarURL: nil,
            bio: "Two dogs, one very loud, and a cat who is in charge of all three of us.",
            city: "Boston", state: "MA", followingPetsCount: 12, createdAt: SocialFixture.date
        )
        social.petsByUser["alice"] = [
            SocialFixture.profilePet(SocialFixture.pet("p1", name: "Sir Reginald Fluffington")),
            SocialFixture.profilePet(SocialFixture.pet("p2", name: "Mo")),
        ]
        social.following = ["p2"]
        let model = UserProfileModel(userID: "alice", viewerID: "me", social: social)
        await model.load()
        #expect(model.pets.count == 2)
        let sizes = try renders({
            UserProfileView(model: model, onOpenPet: { _ in }, onOpenFollowing: {})
        }, named: "user-profile")
        #expect(sizes.isPhoneWidth)
        #expect(sizes.darkMatchesLight, "dark mode changed the layout, not only the colours")
        #expect(sizes.grewAtLargestSize, "the largest text size did not make the screen taller")
    }

    @Test func joiningGrowsWithTheText() async throws {
        let repository = FakeFamilyRepository()
        repository.checkResult = .success(.valid(petID: "pet-1", petName: "Sir Reginald Fluffington"))
        let model = JoinFamilyModel(viewerID: "me", repository: repository)
        model.updateCode("ABCD2345")
        await model.check()
        model.relationship = .other
        model.updateCustomRelationship("Weekend dog walker")
        let sizes = try renders({ JoinFamilyView(model: model, onOpenPet: { _ in }) }, named: "join")
        #expect(sizes.isPhoneWidth)
        #expect(sizes.darkMatchesLight, "dark mode changed the layout, not only the colours")
        #expect(sizes.grewAtLargestSize, "the largest text size did not make the screen taller")
    }

    @Test func discoveryGrowsWithTheText() async throws {
        let search = FakeSearchRepository()
        search.popularTagResult = [Hashtag(name: "dog", postCount: 12), Hashtag(name: "cat", postCount: 3)]
        search.recentPosts = (1...6).map { SocialFixture.post("t\($0)", likes: $0) }
        search.byFollowers = [
            SocialFixture.pet("a", name: "Sir Reginald Fluffington", followers: 40),
            SocialFixture.pet("b", name: "Mo", followers: 1),
        ]
        let social = FakeSocialRepository()
        let blocks = BlockList(viewerID: "me", social: social)
        let explore = ExploreModel(viewerID: "me", search: search, social: social, blockList: blocks)
        await explore.load()
        let model = SearchModel(viewerID: "me", search: search, blockList: blocks)
        #expect(explore.discoverPets.count == 2)
        let sizes = try renders({
            SearchView(
                search: model, explore: explore,
                onOpenPet: { _ in }, onOpenUser: { _ in }, onOpenPost: { _ in }
            )
        }, named: "discovery")
        #expect(sizes.isPhoneWidth)
        #expect(sizes.darkMatchesLight, "dark mode changed the layout, not only the colours")
        #expect(sizes.grewAtLargestSize, "the largest text size did not make the screen taller")
    }

    @Test func thePetPagesSocialRowGrowsWithTheText() throws {
        let pet = SocialFixture.pet("p1", name: "Sir Reginald Fluffington", followers: 1234)
        let social = FakeSocialRepository()
        let sizes = try renders({
            PetSocialActions(
                pet: pet, viewerID: "me", ownership: PetOwnership.none, repository: social,
                onOpenFollowers: {}, onOpenFamily: {}
            )
            .padding()
        }, named: "pet-social-row")
        #expect(sizes.isPhoneWidth)
        #expect(sizes.darkMatchesLight, "dark mode changed the layout, not only the colours")
        #expect(sizes.grewAtLargestSize, "the largest text size did not make the screen taller")
    }
}
