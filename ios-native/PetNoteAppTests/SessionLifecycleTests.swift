import Foundation
import Testing

@testable import PetNote

/// The parts of §4.3/§4.4/§6.9 that can be decided without a Firebase app.
///
/// `SessionStore` itself cannot be exercised here: every path through it goes
/// through `Auth.auth()`, and the unit-test host deliberately does not
/// configure Firebase (`FirebaseBootstrap.isUnitTestHost`) because pointing it
/// at an emulator that may not be running took the whole runner down with a
/// SIGTRAP. So the *rule* is separated from the storage and checked here, and
/// the behaviour around it — a real revoked account, a real cold start — is
/// asserted against the emulator in AuthUITests. Neither stands in for the
/// other.
@MainActor
struct SessionLifecycleTests {
    private static func resume(_ route: Route, _ uid: String) -> SessionStore.Resume {
        SessionStore.Resume(route: route, uid: uid)
    }

    @Test func thePlaceIsGivenBackToTheAccountThatLeftIt() {
        let pending = Self.resume(.postDetail(postID: "ios-post-042"), "uid-a")
        #expect(
            SessionStore.resumeRoute(from: pending, forUID: "uid-a")
                == .postDetail(postID: "ios-post-042")
        )
    }

    /// §4.4. A post id is content, and handing the next account the screen the
    /// last one was reading is the same leak as handing them the feed.
    @Test func adifferentAccountGetsNothingBack() {
        let pending = Self.resume(.postDetail(postID: "ios-post-042"), "uid-a")
        #expect(SessionStore.resumeRoute(from: pending, forUID: "uid-b") == nil)
    }

    /// Restoring the feed would push a second copy of it on top of the one a
    /// sign-in already lands on.
    @Test func theFeedIsNotAPlaceToRestoreTo() {
        #expect(SessionStore.resumeRoute(from: Self.resume(.feed, "uid-a"), forUID: "uid-a") == nil)
    }

    @Test func nothingStoredMeansNothingRestored() {
        #expect(SessionStore.resumeRoute(from: nil, forUID: "uid-a") == nil)
    }

    /// The uid comparison must be exact. A prefix match would hand a place to
    /// whichever account happened to share the first characters.
    @Test func theUIDComparisonIsExact() {
        let pending = Self.resume(.postDetail(postID: "p"), "uid-a")
        #expect(SessionStore.resumeRoute(from: pending, forUID: "uid-ab") == nil)
        #expect(SessionStore.resumeRoute(from: pending, forUID: "uid-") == nil)
        #expect(SessionStore.resumeRoute(from: pending, forUID: "") == nil)
    }

    /// The restored route goes through the same validation as a link would: it
    /// is a `Route`, not a string, so there is no shape it can carry that a tap
    /// could not have produced.
    @Test func aRestoredRouteIsTheSameTypeATapProduces() {
        let fromLink = DeepLink.route(for: URL(string: "petnote://post/ios-post-042")!)
        let restored = SessionStore.resumeRoute(
            from: Self.resume(.postDetail(postID: "ios-post-042"), "uid-a"),
            forUID: "uid-a"
        )
        #expect(fromLink == restored)
    }
}
