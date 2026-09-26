import Foundation
import Testing

@testable import PetNote

/// A pet's owners, managed the way the server allows: adding is equal, taking
/// away converges. Removing *someone else* and moving the primary role are the
/// primary's alone; leaving is anyone's; the last owner cannot leave. And the
/// screen expects to be told no, because what it drew from may be stale.
@MainActor
struct FamilyManageTests {
    private struct Setup {
        let pets = FakeFamilyPets()
        let family = FakeFamilyRepository()
    }

    private func setup(
        members: [PetFamilyMember] = [
            SocialFixture.member("alice", role: .primary),
            SocialFixture.member("bob"),
            SocialFixture.member("carol"),
        ],
        ownerID: String = "alice"
    ) -> Setup {
        let setup = Setup()
        setup.pets.pet = SocialFixture.pet("pet-1", name: "Mochi", ownerID: ownerID)
        setup.pets.family = members
        return setup
    }

    private func model(_ setup: Setup, viewer: String, isAdmin: Bool = false) -> FamilyModel {
        FamilyModel(
            petID: "pet-1", viewerID: viewer, viewerIsAdmin: isAdmin,
            pets: setup.pets, family: setup.family
        )
    }

    // MARK: - Who is offered what

    @Test func thePrimaryCanManageOthersButNotThemself() async {
        let setup = setup()
        let family = model(setup, viewer: "alice")
        await family.load()

        #expect(family.canManage(SocialFixture.member("bob")))
        #expect(!family.canManage(SocialFixture.member("alice", role: .primary)))
        #expect(family.canLeave)
    }

    /// Equal where it adds, not where it takes away.
    @Test func aCoOwnerCanLeaveButCannotManageAnyoneElse() async {
        let setup = setup()
        let family = model(setup, viewer: "bob")
        await family.load()

        #expect(family.permissions.isMember)
        #expect(!family.canManage(SocialFixture.member("carol")))
        #expect(family.canLeave)

        family.ask(.remove(SocialFixture.member("carol")))
        #expect(family.pending == nil, "a co-owner was asked to confirm removing somebody else")
    }

    @Test func theLastOwnerIsNotOfferedLeave() async {
        let setup = setup(members: [SocialFixture.member("alice", role: .primary)])
        let family = model(setup, viewer: "alice")
        await family.load()

        #expect(family.isOnlyOwner)
        #expect(!family.canLeave)
        family.ask(.leave)
        #expect(family.pending == nil)
    }

    @Test func somebodyOutsideTheFamilyIsOfferedNothing() async {
        let setup = setup()
        let family = model(setup, viewer: "stranger")
        await family.load()

        #expect(!family.permissions.isMember)
        #expect(!family.canLeave)
        #expect(!family.canManage(SocialFixture.member("bob")))
    }

    /// A stale `ownerId` must not hand a removed person the primary's controls
    /// — and a failed read must not either, since an empty family is exactly
    /// what the legacy fallback trusts `ownerId` for.
    @Test func aFailedFamilyReadOffersNoControlEvenToTheNamedOwner() async {
        let setup = setup(ownerID: "alice")
        setup.pets.familyError = SocialFixture.readFailure
        let family = model(setup, viewer: "alice")

        await family.load()

        #expect(family.ownership == nil)
        #expect(family.state == .failed("Could not load Mochi's owners."))
        #expect(!family.canManage(SocialFixture.member("bob")))
        #expect(!family.canLeave)
    }

    @Test func aRemovedOwnerStillNamedInOwnerIdIsNotAnOwner() async {
        let setup = setup(
            members: [SocialFixture.member("bob", role: .primary), SocialFixture.member("carol")],
            ownerID: "alice"
        )
        let family = model(setup, viewer: "alice")
        await family.load()

        #expect(!family.permissions.isMember)
        #expect(!family.canManage(SocialFixture.member("carol")))
    }

    // MARK: - Removing

    @Test func removingGoesThroughTheCallableAndRereadsTheFamily() async {
        let setup = setup()
        let family = model(setup, viewer: "alice")
        await family.load()
        let pets = setup.pets
        setup.family.onMutation = {
            pets.family = [SocialFixture.member("alice", role: .primary), SocialFixture.member("carol")]
        }

        family.ask(.remove(SocialFixture.member("bob")))
        #expect(family.pending == .remove(SocialFixture.member("bob")))
        await family.confirm()

        #expect(setup.family.removed == ["bob"])
        #expect(family.notice == .success("Bob is no longer an owner."))
        #expect(family.members.map(\.id) == ["alice", "carol"])
        #expect(family.pending == nil)
    }

    /// The server decides inside a transaction. If the role moved since the
    /// roster was read, the refusal is expected, said in words, and followed
    /// by a re-read so the screen stops offering what is no longer true.
    @Test func theServersRefusalIsReportedAndTheRosterIsReread() async {
        let setup = setup()
        let family = model(setup, viewer: "alice")
        await family.load()
        let readsBefore = setup.pets.familyReads
        setup.family.removeResult = .failure(FamilyError.notPrimary)
        setup.pets.family = [
            SocialFixture.member("alice"),
            SocialFixture.member("bob", role: .primary),
            SocialFixture.member("carol"),
        ]

        family.ask(.remove(SocialFixture.member("carol")))
        await family.confirm()

        #expect(family.notice == .failure(FamilyModel.wording(for: .notPrimary, petName: "Mochi")))
        #expect(setup.pets.familyReads == readsBefore + 1)
        #expect(!family.permissions.isPrimary)
        #expect(!family.canManage(SocialFixture.member("carol")), "a control stayed up after the server said no")
    }

    @Test func thePrimaryCannotBePushedOut() async {
        let setup = setup()
        let family = model(setup, viewer: "alice", isAdmin: true)
        await family.load()
        setup.family.removeResult = .failure(FamilyError.targetIsPrimary)

        await family.perform(.remove(SocialFixture.member("bob")))

        #expect(family.notice == .failure(FamilyModel.wording(for: .targetIsPrimary, petName: "Mochi")))
    }

    /// A lost answer is settled by reading the family: the removal is in the
    /// transaction or it is not, and the roster says which. Nothing is sent a
    /// second time.
    @Test func aLostAnswerToARemovalIsSettledByTheRoster() async {
        let setup = setup()
        let family = model(setup, viewer: "alice")
        await family.load()
        let pets = setup.pets
        setup.family.removeResult = .failure(FamilyError.outcomeUnknown)
        setup.family.onMutation = {
            pets.family = [SocialFixture.member("alice", role: .primary), SocialFixture.member("carol")]
        }

        await family.perform(.remove(SocialFixture.member("bob")))

        #expect(setup.family.removed == ["bob"])
        #expect(family.notice == .success("Bob is no longer an owner."))
    }

    @Test func aLostAnswerToARemovalThatDidNotLandSaysSo() async {
        let setup = setup()
        let family = model(setup, viewer: "alice")
        await family.load()
        setup.family.removeResult = .failure(FamilyError.outcomeUnknown)

        await family.perform(.remove(SocialFixture.member("bob")))

        #expect(family.notice == .failure(FamilyModel.unknownOutcome))
        #expect(family.members.map(\.id).contains("bob"))
    }

    /// The confirmation alert clears its own binding as it closes, possibly
    /// before the task that confirms has started. Performing takes the action
    /// as a value, so that ordering cannot drop the tap.
    @Test func performingDoesNotDependOnThePendingConfirmation() async {
        let setup = setup()
        let family = model(setup, viewer: "alice")
        await family.load()

        family.ask(.remove(SocialFixture.member("bob")))
        family.cancel()
        await family.perform(.remove(SocialFixture.member("bob")))

        #expect(setup.family.removed == ["bob"])
    }

    // MARK: - Handing on the role

    @Test func handingOnTheRoleGoesThroughTheCallable() async {
        let setup = setup()
        let family = model(setup, viewer: "alice")
        await family.load()
        let pets = setup.pets
        setup.family.onMutation = {
            pets.family = [
                SocialFixture.member("alice"),
                SocialFixture.member("bob", role: .primary),
                SocialFixture.member("carol"),
            ]
        }

        family.ask(.transfer(SocialFixture.member("bob")))
        await family.confirm()

        #expect(setup.family.transferred == ["bob"])
        #expect(family.notice == .success("Bob is now Mochi's primary owner."))
        #expect(!family.permissions.isPrimary, "the former primary kept the primary's controls")
        #expect(family.permissions.isMember, "the former primary stopped being an owner")
    }

    // MARK: - Leaving

    @Test func leavingIsARemovalOfYourselfAndEndsTheScreen() async {
        let setup = setup()
        let family = model(setup, viewer: "bob")
        await family.load()

        family.ask(.leave)
        await family.confirm()

        #expect(setup.family.removed == ["bob"])
        #expect(family.didLeave)
    }

    @Test func theLastOwnersLeaveIsRefusedInWords() async {
        let setup = setup()
        let family = model(setup, viewer: "bob")
        await family.load()
        setup.family.removeResult = .failure(FamilyError.lastOwner)

        await family.perform(.leave)

        #expect(!family.didLeave)
        #expect(family.notice == .failure(FamilyModel.wording(for: .lastOwner, petName: "Mochi")))
    }

    @Test func aLostAnswerToALeaveIsSettledByTheRoster() async {
        let setup = setup()
        let family = model(setup, viewer: "bob")
        await family.load()
        let pets = setup.pets
        setup.family.removeResult = .failure(FamilyError.outcomeUnknown)
        setup.family.onMutation = {
            pets.family = [SocialFixture.member("alice", role: .primary), SocialFixture.member("carol")]
        }

        await family.perform(.leave)

        #expect(family.didLeave)
    }

    /// Where the role goes when the primary leaves is said before it happens.
    @Test func thePrimaryIsToldWhereTheRoleGoesWhenTheyLeave() async {
        let setup = setup()
        let primary = model(setup, viewer: "alice")
        await primary.load()
        let member = model(setup, viewer: "bob")
        await member.load()

        #expect(primary.consequence(of: .leave).contains("passes to whoever has been an owner the longest"))
        #expect(!member.consequence(of: .leave).contains("passes to"))
    }

    @Test func aMissingPetIsNotAFailedRead() async {
        let setup = setup()
        setup.pets.pet = nil
        let family = model(setup, viewer: "alice")

        await family.load()

        #expect(family.state == .missing)
        #expect(!family.canLeave)
    }
}
