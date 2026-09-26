import Foundation
import Testing

@testable import PetNote

/// The invitation code: any owner may make one, share it, and take it back.
@MainActor
struct FamilyInviteTests {
    private func model(_ repository: FakeFamilyRepository, now: Date = Date()) -> InviteModel {
        InviteModel(petID: "pet-1", repository: repository, now: { now })
    }

    @Test func theLiveCodeIsShown() async {
        let repository = FakeFamilyRepository()
        repository.active = SocialFixture.invitation()
        let invite = model(repository)

        await invite.load()

        #expect(invite.liveInvitation?.code == "ABCD2345")
        #expect(invite.liveInvitation?.formattedCode == "ABCD 2345")
    }

    @Test func noCodeIsNotAFailure() async {
        let repository = FakeFamilyRepository()
        let invite = model(repository)

        await invite.load()

        #expect(invite.state == .none)
    }

    @Test func somebodyOutsideTheFamilyIsToldSo() async {
        let repository = FakeFamilyRepository()
        repository.activeError = FamilyError.notAnOwner
        let invite = model(repository)

        await invite.load()

        #expect(invite.state == .notPermitted)
    }

    @Test func aFailedReadOffersARetry() async {
        let repository = FakeFamilyRepository()
        repository.activeError = FamilyError.offline
        let invite = model(repository)

        await invite.load()

        #expect(invite.state == .failed("Could not load the invitation code."))
    }

    @Test func generatingMakesACodeThroughTheCallable() async {
        let repository = FakeFamilyRepository()
        let invite = model(repository)
        await invite.load()

        await invite.generate()

        #expect(repository.creates == 1)
        #expect(invite.liveInvitation?.code == "ABCD2345")
        #expect(invite.confirmation == "Invitation code ready.")
    }

    /// The create hands back the live code rather than minting another, and
    /// reading the active code is a read — so a lost answer is settled by
    /// asking, not by generating again.
    @Test func aLostAnswerToAGenerateIsSettledByReadingTheActiveCode() async {
        let repository = FakeFamilyRepository()
        repository.createResult = .failure(FamilyError.outcomeUnknown)
        repository.createLandsDespiteError = true
        let invite = model(repository)
        await invite.load()
        let readsBefore = repository.activeReads

        await invite.generate()

        #expect(repository.creates == 1)
        #expect(repository.activeReads == readsBefore + 1)
        #expect(invite.liveInvitation?.code == "ABCD2345")
        #expect(invite.message == nil)
    }

    @Test func aGenerateThatDidNotLandSaysSo() async {
        let repository = FakeFamilyRepository()
        repository.createResult = .failure(FamilyError.outcomeUnknown)
        let invite = model(repository)
        await invite.load()

        await invite.generate()

        #expect(invite.liveInvitation == nil)
        #expect(invite.message == "We could not tell whether a code was made. Try again.")
    }

    @Test func revokingKillsTheCode() async {
        let repository = FakeFamilyRepository()
        repository.active = SocialFixture.invitation()
        let invite = model(repository)
        await invite.load()

        await invite.revoke()

        #expect(repository.revoked == ["ABCD2345"])
        #expect(invite.state == .none)
        #expect(invite.confirmation == "Invitation code revoked.")
    }

    @Test func aRevokeWhoseAnswerWasLostIsCheckedNotAssumed() async {
        let repository = FakeFamilyRepository()
        repository.active = SocialFixture.invitation()
        repository.revokeError = FamilyError.outcomeUnknown
        let invite = model(repository)
        await invite.load()

        await invite.revoke()

        #expect(invite.liveInvitation?.code == "ABCD2345", "a code that may still work was hidden")
        #expect(invite.message == "We could not tell whether the code was revoked. Try again.")
    }

    /// A code that expired while the screen was open is not offered.
    @Test func anExpiredCodeIsNotOfferedForSharing() async {
        let repository = FakeFamilyRepository()
        repository.active = SocialFixture.invitation(expiresIn: -60)
        let invite = model(repository)

        await invite.load()

        #expect(invite.liveInvitation == nil)
    }

    @Test func theExpiryAndShareWordsMatchTheWebModal() {
        let now = Date(timeIntervalSince1970: 0)
        let later = now.addingTimeInterval(47 * 3600 + 59 * 60 + 30)
        #expect(InviteModel.expiresLabel(later, now: now) == "Expires in 47h 59m")
        #expect(InviteModel.expiresLabel(now, now: later) == "Expires in 0h 0m")
        #expect(
            InviteModel.shareMessage(for: SocialFixture.invitation(), petName: "Mochi")
                == "Join Mochi's family on PetNote with this invitation code: ABCD 2345"
        )
    }

    /// The server's `normalizeInvitationCode`: letters and digits, upper case.
    @Test func typedCodesAreNormalisedAsTheServerDoes() {
        #expect(InvitationCode.normalize("abcd-2345") == "ABCD2345")
        #expect(InvitationCode.normalize(" ab cd 23 45 99") == "ABCD2345")
        #expect(InvitationCode.normalize("ÄBCD2345") == "BCD2345")
        #expect(InvitationCode.format("abcd2345") == "ABCD 2345")
        #expect(InvitationCode.format("ab") == "AB")
        #expect(InvitationCode.isComplete("abcd 2345"))
        #expect(!InvitationCode.isComplete("abcd234"))
    }
}

/// Joining with a code: check it, say who you are to the pet, join — and when
/// the answer is lost, ask the family document rather than the used code.
@MainActor
struct FamilyJoinTests {
    private func model(_ repository: FakeFamilyRepository) -> JoinFamilyModel {
        JoinFamilyModel(viewerID: "me", repository: repository)
    }

    private func accepted(_ repository: FakeFamilyRepository) async -> JoinFamilyModel {
        let join = model(repository)
        join.updateCode("abcd-2345")
        await join.check()
        return join
    }

    @Test func checkingANormalisedCodeNamesThePet() async {
        let repository = FakeFamilyRepository()
        let join = model(repository)

        join.updateCode("abcd-2345")
        #expect(join.canCheck)
        await join.check()

        #expect(repository.checked == ["ABCD2345"])
        #expect(join.step == .choosing(petID: "pet-1", petName: "Mochi"))
    }

    @Test func anIncompleteCodeCannotBeChecked() async {
        let repository = FakeFamilyRepository()
        let join = model(repository)

        join.updateCode("abc")
        await join.check()

        #expect(!join.canCheck)
        #expect(repository.checked.isEmpty)
    }

    @Test func anInvalidCodeSaysSoAndStaysOnTheField() async {
        let repository = FakeFamilyRepository()
        repository.checkResult = .success(.invalid)
        let join = model(repository)
        join.updateCode("ABCD2345")

        await join.check()

        #expect(join.step == .entering)
        #expect(join.message?.contains("not valid") == true)
    }

    @Test func joiningNeedsARelationship() async {
        let repository = FakeFamilyRepository()
        let join = await accepted(repository)

        #expect(!join.canJoin)
        await join.join()
        #expect(repository.redeemed.isEmpty)
    }

    @Test func joiningRedeemsWithTheChosenRelationship() async {
        let repository = FakeFamilyRepository()
        let join = await accepted(repository)

        join.relationship = .bestFriend
        await join.join()

        #expect(repository.redeemed.count == 1)
        #expect(repository.redeemed.first?.relationship == .bestFriend)
        #expect(repository.redeemed.first?.custom == nil)
        #expect(join.step == .joined(JoinedPet(petID: "pet-1", petName: "Mochi"), alreadyMember: false))
    }

    /// Only `other` carries a label, and never more than the server accepts.
    @Test func aCustomLabelIsCappedAndOnlySentForOther() async {
        let repository = FakeFamilyRepository()
        let join = await accepted(repository)

        join.updateCustomRelationship(String(repeating: "x", count: 45))
        #expect(join.customRelationship.count == PetValidation.customRelationshipLimit)
        join.relationship = .other
        await join.join()

        #expect(repository.redeemed.first?.custom?.count == PetValidation.customRelationshipLimit)
        #expect(FirestoreFamilyRepository.customRelationship(.mom, "Mama") == nil)
        #expect(FirestoreFamilyRepository.customRelationship(.other, "   ") == nil)
    }

    @Test func alreadyBeingAnOwnerIsAnArrivalNotAnError() async {
        let repository = FakeFamilyRepository()
        repository.redeemResults = [.failure(FamilyError.alreadyMember)]
        let join = await accepted(repository)
        join.relationship = .mom

        await join.join()

        #expect(join.step == .joined(JoinedPet(petID: "pet-1", petName: "Mochi"), alreadyMember: true))
    }

    /// The redemption landed and the answer was lost. The family document is
    /// the answer that cannot mislead.
    @Test func aLostAnswerIsSettledByTheFamilyDocument() async {
        let repository = FakeFamilyRepository()
        repository.redeemResults = [.failure(FamilyError.outcomeUnknown)]
        repository.members = ["me"]
        let join = await accepted(repository)
        join.relationship = .mom

        await join.join()

        #expect(repository.redeemed.count == 1, "an unknown outcome must not be redeemed again")
        #expect(repository.memberReads == 1)
        #expect(join.step == .joined(JoinedPet(petID: "pet-1", petName: "Mochi"), alreadyMember: false))
    }

    @Test func aLostAnswerThatDidNotLandLetsThemTryAgain() async {
        let repository = FakeFamilyRepository()
        repository.redeemResults = [.failure(FamilyError.outcomeUnknown)]
        let join = await accepted(repository)
        join.relationship = .mom

        await join.join()

        #expect(join.step == .choosing(petID: "pet-1", petName: "Mochi"))
        #expect(join.message == "We could not tell whether you joined. Try again.")
    }

    /// The trap the web client's retry falls into: after a lost answer the
    /// code is *used*, so trying again reads "invalid or expired" to somebody
    /// who is in fact now an owner.
    @Test func anInvalidCodeAfterALostAnswerIsCheckedAgainstTheFamily() async {
        let repository = FakeFamilyRepository()
        repository.redeemResults = [
            .failure(FamilyError.outcomeUnknown),
            .failure(FamilyError.invitationInvalid),
        ]
        let join = await accepted(repository)
        join.relationship = .mom
        await join.join()
        #expect(join.step == .choosing(petID: "pet-1", petName: "Mochi"))

        // Meanwhile the first attempt did land.
        repository.members = ["me"]
        await join.join()

        #expect(join.step == .joined(JoinedPet(petID: "pet-1", petName: "Mochi"), alreadyMember: false))
    }

    @Test func aCodeThatNoLongerWorksGoesBackToTheField() async {
        let repository = FakeFamilyRepository()
        repository.redeemResults = [.failure(FamilyError.inviterLeft)]
        let join = await accepted(repository)
        join.relationship = .mom

        await join.join()

        #expect(join.step == .entering)
        #expect(join.relationship == nil)
        #expect(join.message == JoinFamilyModel.wording(for: .inviterLeft))
    }

    @Test func aPassingRefusalKeepsTheChoice() async {
        let repository = FakeFamilyRepository()
        repository.redeemResults = [.failure(FamilyError.rateLimited)]
        let join = await accepted(repository)
        join.relationship = .mom

        await join.join()

        #expect(join.step == .choosing(petID: "pet-1", petName: "Mochi"))
        #expect(join.relationship == .mom)
        #expect(join.message == JoinFamilyModel.wording(for: .rateLimited))
    }
}
