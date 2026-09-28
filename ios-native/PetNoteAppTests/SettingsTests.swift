import FirebaseFunctions
import Foundation
import Testing

@testable import PetNote

/// Settings, the account's security operations, and deleting the account —
/// the rules, over fakes. The screens themselves are in SettingsUITests.
@MainActor
struct SettingsTests {
    // MARK: - Fakes

    final class FakeStore: PreferencesStoring, @unchecked Sendable {
        var stored = NotificationPreferences()
        var readError: Error?
        var writeError: Error?
        private(set) var writes: [(NotificationPreferences.Key, Bool)] = []

        func preferences(uid: String) async throws -> NotificationPreferences {
            if let readError { throw readError }
            return stored
        }

        func set(_ key: NotificationPreferences.Key, to value: Bool, uid: String) async throws {
            writes.append((key, value))
            if let writeError { throw writeError }
            stored[key] = value
        }
    }

    final class FakeSecurity: AccountSecurity, @unchecked Sendable {
        var methods = ["password"]
        var reauthError: ReauthenticationError?
        var changeError: PasswordChangeError?
        var deleteError: AccountDeletionError?
        var profileStillThere: Bool? = true
        var pending: Bool? = false
        private(set) var reauthenticated: [String] = []
        private(set) var deleteCalls = 0

        func signInMethods() async -> [String] { methods }
        func reauthenticate(password: String) async throws(ReauthenticationError) {
            reauthenticated.append("password")
            if let reauthError { throw reauthError }
        }
        func reauthenticate(google: GoogleTokens) async throws(ReauthenticationError) {
            reauthenticated.append("google")
            if let reauthError { throw reauthError }
        }
        func changePassword(current: String, to new: String) async throws(PasswordChangeError) {
            if let changeError { throw changeError }
        }
        func deleteAccount(uid: String) async throws(AccountDeletionError) {
            deleteCalls += 1
            if let deleteError { throw deleteError }
        }
        func profileExists(uid: String) async -> Bool? { profileStillThere }
        func deletionPending(uid: String) async -> Bool? { pending }
    }

    @MainActor
    final class FakeGoogle: GoogleTokenProviding {
        var result: Result<GoogleTokens?, AuthError> = .success(GoogleTokens(idToken: "id", accessToken: "a"))
        var isAvailable = true
        func tokens() async throws(AuthError) -> GoogleTokens? { try result.get() }
    }

    // MARK: - Notification switches

    @Test func aMissingSwitchIsOnAndOnlyABooleanCounts() {
        let read = NotificationPreferences(stored: ["likeNotifications": false, "followNotifications": "no"])
        #expect(read.likes == false)
        #expect(read.comments == true, "missing means on, as on the web and the server")
        #expect(read.follows == true, "a value that is not a boolean is ignored")
        #expect(NotificationPreferences(stored: nil) == NotificationPreferences())
    }

    @Test func aSwitchIsSavedAndARefusedOneIsPutBack() async {
        let store = FakeStore()
        let model = SettingsModel(uid: "me", store: store, security: FakeSecurity())
        await model.load()

        await model.set(.likes, to: false)
        #expect(model.preferences.likes == false)
        #expect(store.writes.map { $0.0 } == [.likes] && store.writes.map { $0.1 } == [false])

        store.writeError = NSError(domain: "test", code: 7)
        await model.set(.comments, to: false)
        #expect(model.preferences.comments == true, "a refused write left the switch showing what was not saved")
        #expect(model.saveFailure == "Failed to save settings.")
    }

    @Test func nothingIsWrittenBeforeTheSwitchesHaveLoaded() async {
        let store = FakeStore()
        store.readError = NSError(domain: "test", code: 14)
        let model = SettingsModel(uid: "me", store: store, security: FakeSecurity())
        await model.load()
        #expect(model.preferencesState == .failed)
        await model.set(.likes, to: false)
        #expect(store.writes.isEmpty, "a switch was written over a value that was never read")
    }

    @Test func passwordIsOfferedOnlyToAccountsThatHaveOne() async {
        let security = FakeSecurity()
        security.methods = ["google.com"]
        let model = SettingsModel(uid: "me", store: FakeStore(), security: security)
        await model.load()
        #expect(!model.hasPassword)
        #expect(model.hasGoogle)
    }

    @Test func anUnfinishedDeletionIsReported() async {
        let security = FakeSecurity()
        security.pending = true
        let model = SettingsModel(uid: "me", store: FakeStore(), security: security)
        await model.load()
        #expect(model.deletionPending)
    }

    // MARK: - Change password

    @Test func thePasswordRulesAreSignUpsAndTheTwoMustMatch() {
        let model = ChangePasswordModel(security: FakeSecurity())
        model.current = "Old1!pass"
        model.new = "weak"
        model.confirm = "weak"
        #expect(!model.canSubmit, "a password sign-up would refuse was accepted")
        model.new = "Str0ng!pass"
        model.confirm = "Str0ng!pas"
        #expect(model.mismatch)
        #expect(!model.canSubmit)
        model.confirm = "Str0ng!pass"
        #expect(model.canSubmit)
        model.current = ""
        #expect(!model.canSubmit, "no current password, no change")
    }

    @Test func aWrongCurrentPasswordSaysSoInTheWebsWords() async {
        let security = FakeSecurity()
        security.changeError = .currentPasswordIncorrect
        let model = ChangePasswordModel(security: security)
        model.current = "Wrong1!pass"
        model.new = "Str0ng!pass"
        model.confirm = "Str0ng!pass"
        await model.submit()
        #expect(model.failure == "Current password is incorrect.")
        #expect(!model.done)
        #expect(model.new == "Str0ng!pass", "what was typed was cleared on a failure")
    }

    @Test func aChangedPasswordClearsTheFields() async {
        let model = ChangePasswordModel(security: FakeSecurity())
        model.current = "Old1!pass"
        model.new = "Str0ng!pass"
        model.confirm = "Str0ng!pass"
        await model.submit()
        #expect(model.done)
        #expect(model.current.isEmpty && model.new.isEmpty && model.confirm.isEmpty)
    }

    // MARK: - Delete account

    private func deletion(
        security: FakeSecurity = FakeSecurity(),
        hasPassword: Bool = true,
        hasGoogle: Bool = false,
        google: FakeGoogle? = nil
    ) -> DeleteAccountModel {
        DeleteAccountModel(uid: "me", hasPassword: hasPassword, hasGoogle: hasGoogle, security: security, google: google)
    }

    @Test func onlyTheExactWordAndAPasswordArmIt() {
        let model = deletion()
        model.password = "Passw0rd!x"
        for attempt in ["", "delete", "Delete", "DELETE ", " DELETE", "DELET"] {
            model.typed = attempt
            #expect(!model.canSubmit, "\"\(attempt)\" armed the delete")
        }
        model.typed = "DELETE"
        #expect(model.canSubmit)
        model.password = ""
        #expect(!model.canSubmit, "no password, no deletion")
    }

    @Test func aWrongPasswordStopsItBeforeAnythingIsSent() async {
        let security = FakeSecurity()
        security.reauthError = .wrongPassword
        let model = deletion(security: security)
        model.password = "nope"
        model.typed = "DELETE"
        await model.submit()
        #expect(security.deleteCalls == 0, "a deletion went out without the person proving it was them")
        #expect(model.failure == "That password is not correct.")
        #expect(model.phase == .editing)
    }

    @Test func aDeletionThatFinishesSaysSo() async {
        let security = FakeSecurity()
        let model = deletion(security: security)
        model.password = "Passw0rd!x"
        model.typed = "DELETE"
        await model.submit()
        #expect(security.reauthenticated == ["password"])
        #expect(security.deleteCalls == 1)
        #expect(model.phase == .deleted)
    }

    /// The reply never came. Gone on the server means it finished; still
    /// there means it did not, and the person is told so rather than being
    /// signed out of an account that still exists.
    @Test func aLostAnswerIsSettledByAskingTheServer() async {
        let finished = FakeSecurity()
        finished.deleteError = .notFinished
        finished.profileStillThere = false
        let a = deletion(security: finished)
        a.password = "Passw0rd!x"
        a.typed = "DELETE"
        await a.submit()
        #expect(a.phase == .deleted)

        let unfinished = FakeSecurity()
        unfinished.deleteError = .notFinished
        unfinished.profileStillThere = true
        let b = deletion(security: unfinished)
        b.password = "Passw0rd!x"
        b.typed = "DELETE"
        await b.submit()
        #expect(b.phase == .editing)
        #expect(b.failure == AccountDeletionError.notFinished.message)

        let unreadable = FakeSecurity()
        unreadable.deleteError = .notFinished
        unreadable.profileStillThere = nil
        let c = deletion(security: unreadable)
        c.password = "Passw0rd!x"
        c.typed = "DELETE"
        await c.submit()
        #expect(c.phase == .editing, "an unreadable answer was taken as a finished deletion")
    }

    @Test func aGoogleAccountConfirmsWithGoogleAndBackingOutSendsNothing() async {
        let security = FakeSecurity()
        let google = FakeGoogle()
        google.result = .success(nil)
        let model = deletion(security: security, hasPassword: false, hasGoogle: true, google: google)
        model.typed = "DELETE"
        #expect(model.canSubmit, "a Google account needs no password field")
        await model.submit()
        #expect(security.deleteCalls == 0)
        #expect(model.failure == nil, "backing out of Google was reported as a failure")
        #expect(model.phase == .editing)

        google.result = .success(GoogleTokens(idToken: "id", accessToken: "a"))
        await model.submit()
        #expect(security.reauthenticated == ["google"])
        #expect(model.phase == .deleted)
    }

    @Test func aGoogleAccountWithNoWayToConfirmCannotBeDeletedHere() {
        let google = FakeGoogle()
        google.isAvailable = false
        let model = deletion(hasPassword: false, hasGoogle: true, google: google)
        model.typed = "DELETE"
        #expect(!model.canReauthenticate)
        #expect(!model.canSubmit)
    }

    @Test func theServersRefusalsBecomeTheRightWords() {
        func functionsError(_ code: FunctionsErrorCode) -> NSError {
            NSError(domain: FunctionsErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: "x"])
        }
        #expect(LiveAccountSecurity.mapDeletion(functionsError(.resourceExhausted)) == .rateLimited)
        #expect(LiveAccountSecurity.mapDeletion(functionsError(.unauthenticated)) == .notSignedIn)
        #expect(LiveAccountSecurity.mapDeletion(functionsError(.internal)) == .notFinished,
                "a cascade that stopped part-way is not finished, and a retry finishes it")
        #expect(LiveAccountSecurity.mapDeletion(functionsError(.deadlineExceeded)) == .notFinished)
        #expect(LiveAccountSecurity.mapDeletion(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)) == .offline)
        #expect(AccountDeletionError.rateLimited.message == "Too many attempts. Wait an hour and try again.")
    }
}
