import Testing

@testable import PetNote

/// What counts as suspended, read the way the rules' `isNotBanned()` and the
/// web client's `isBanned` read `users/{uid}/admin/state`.
struct SuspensionTests {
    @Test func onlyAnExplicitBanCounts() {
        #expect(Suspension.isSuspended(["banned": true]))
        #expect(!Suspension.isSuspended(["banned": false]))
        #expect(!Suspension.isSuspended(nil), "no admin state is every account that was never banned")
        #expect(!Suspension.isSuspended([:]))
        #expect(!Suspension.isSuspended(["role": "user"]))
        #expect(!Suspension.isSuspended(["banned": "true"]), "a string is not the rules' `== true`")
    }
}
