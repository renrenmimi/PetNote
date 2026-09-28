import Foundation
import Testing

@testable import PetNote

/// Acceptance 3.2. The malicious cases are the point: a link is untrusted input,
/// and "unknown shape lands on the feed" has to hold for inputs nobody
/// anticipated, not just for typos.
struct DeepLinkTests {
    // MARK: - Shapes we do accept

    @Test func customSchemeOpensAPost() {
        #expect(DeepLink.route(for: URL(string: "petnote://post/ios-post-042")!) == .postDetail(postID: "ios-post-042"))
    }

    @Test func universalLinkOnOurHostOpensAPost() {
        #expect(DeepLink.route(for: URL(string: "https://petnote.app/post/abc123")!) == .postDetail(postID: "abc123"))
        #expect(DeepLink.route(for: URL(string: "https://www.petnote.app/post/abc123")!) == .postDetail(postID: "abc123"))
    }

    @Test func hostComparisonIsCaseInsensitive() {
        #expect(DeepLink.route(for: URL(string: "https://PetNote.App/post/abc")!) == .postDetail(postID: "abc"))
    }

    @Test func internalPathsResolve() {
        #expect(DeepLink.route(forPath: "/post/abc") == .postDetail(postID: "abc"))
        #expect(DeepLink.route(forPath: "/feed") == .feed)
        #expect(DeepLink.route(forPath: "/") == .feed)
    }

    /// The web client's `/pet/:petId`, reachable the same three ways a post is.
    @Test func aPetLinkOpensThePet() {
        #expect(DeepLink.route(for: URL(string: "petnote://pet/pet-7")!) == .pet(petID: "pet-7"))
        #expect(DeepLink.route(for: URL(string: "https://petnote.app/pet/pet-7")!) == .pet(petID: "pet-7"))
        #expect(DeepLink.route(forPath: "/pet/pet-7") == .pet(petID: "pet-7"))
    }

    @Test func aProfileLinkOpensThatPerson() {
        #expect(DeepLink.route(forPath: "/profile/user-9") == .user(userID: "user-9"))
        #expect(DeepLink.route(for: URL(string: "https://petnote.app/profile/user-9")!) == .user(userID: "user-9"))
        #expect(DeepLink.route(forPath: "/profile/..%2Fadmin") == .feed)
        #expect(DeepLink.route(forPath: "/profile") == .feed)
        #expect(DeepLink.route(forPath: "/profile/a/b") == .feed)
    }

    @Test func theSearchLinkOpensSearch() {
        #expect(DeepLink.route(forPath: "/search") == .search(tag: nil))
        #expect(DeepLink.route(forPath: "/search/extra") == .feed)
    }

    /// The pet id goes through the same validation as a post id — after
    /// decoding — because it reaches the same kind of Firestore read. A new
    /// route is the easiest place for that check to be forgotten.
    /// The web's paths for a place and a meetup, with the same id checks.
    @Test func placeAndMeetupLinksOpenThem() {
        #expect(DeepLink.route(forPath: "/location/loc1") == .place(placeID: "loc1"))
        #expect(DeepLink.route(forPath: "/meetups/m1") == .meetup(meetupID: "m1"))
        #expect(DeepLink.route(forPath: "/meetups") == .feed, "the tab is not one meetup")
        #expect(DeepLink.route(forPath: "/location/a%2Fb") == .feed)
        #expect(DeepLink.route(forPath: "/meetups/__reserved__") == .feed)
        #expect(DeepLink.route(forPath: "/location/a/b") == .feed)
    }

    @Test func aPetLinkGetsThePostLinksValidation() {
        #expect(DeepLink.route(for: URL(string: "petnote://pet/..%2F..%2Fusers")!) == .feed)
        #expect(DeepLink.route(forPath: "/pet/a%2Fb") == .feed)
        #expect(DeepLink.route(forPath: "/pet/__reserved__") == .feed)
        #expect(DeepLink.route(forPath: "/pet/") == .feed)
        #expect(DeepLink.route(forPath: "/pet/a/b") == .feed)
    }

    /// Editors are not link targets. A link can open a place to look at; it
    /// must not be able to open a screen that writes.
    ///
    /// The `switch` is the half that matters and it is checked by the
    /// compiler rather than at run time: it names every `Route`, so adding an
    /// editor-shaped case — `.editPet`, `.compose` — stops this file compiling
    /// until someone decides, here, whether a URL may reach it.
    @Test func noLinkOpensAnEditor() {
        func isAPlaceToLook(_ route: Route) -> Bool {
            switch route {
            case .feed, .postDetail, .pet, .user, .search, .petFollowers, .followingPets, .savedPosts,
                 .myCheckins, .notifications, .place, .meetup: return true
            // Management, not a place to look: the one case a link must never
            // produce, and the reason this switch has no `default`.
            case .family, .joinFamily, .blockedUsers, .contactUs, .settings: return false
            }
        }
        for path in ["/pet/abc/edit", "/create", "/post/abc/edit", "/profile/edit", "/compose",
                     "/meetups/create", "/places/add", "/meetups/abc/edit"] {
            let route = DeepLink.route(forPath: path)
            #expect(isAPlaceToLook(route), "\(path) produced \(route)")
            #expect(route == .feed, "\(path) should not resolve to anything but the feed, got \(route)")
        }
    }

    // MARK: - Another origin must never be routed

    @Test func anotherHostIsNotOurs() {
        #expect(DeepLink.route(for: URL(string: "https://evil.example/post/abc")!) == .feed)
        // A lookalike host: prefix matching would accept this, equality does not.
        #expect(DeepLink.route(for: URL(string: "https://petnote.app.evil.example/post/abc")!) == .feed)
    }

    @Test func protocolRelativePathsAreRefused() {
        // "//evil.example/post/abc" is another origin, not a path.
        #expect(DeepLink.route(forPath: "//evil.example/post/abc") == .feed)
    }

    @Test func aPathCarryingASchemeIsRefused() {
        #expect(DeepLink.route(forPath: "/post/abc:def") == .feed)
        #expect(DeepLink.route(forPath: "javascript:alert(1)") == .feed)
        #expect(DeepLink.route(forPath: "https://evil.example/post/abc") == .feed)
    }

    @Test func nonWebSchemesAreRefused() {
        #expect(DeepLink.route(for: URL(string: "file:///etc/passwd")!) == .feed)
        #expect(DeepLink.route(for: URL(string: "http://petnote.app/post/abc")!) == .feed)  // plaintext, not ours
        #expect(DeepLink.route(for: URL(string: "data:text/html,<script>")!) == .feed)
    }

    // MARK: - Identifier validation happens after decoding

    @Test func percentEncodedSeparatorsCannotSmuggleAPath() {
        // %2F decodes to "/". Validating before decoding would let this through
        // as the id "..%2F..%2Fusers".
        #expect(DeepLink.route(for: URL(string: "petnote://post/..%2F..%2Fusers")!) == .feed)
        #expect(DeepLink.route(forPath: "/post/a%2Fb") == .feed)
    }

    @Test func dotSegmentsAreRefused() {
        #expect(DeepLink.validDocumentID(".") == nil)
        #expect(DeepLink.validDocumentID("..") == nil)
    }

    @Test func firestoreReservedIdsAreRefused() {
        #expect(DeepLink.validDocumentID("__name__") == nil)
        #expect(DeepLink.validDocumentID("__id7__") == nil)
    }

    @Test func emptyAndOverlongIdsAreRefused() {
        #expect(DeepLink.validDocumentID("") == nil)
        #expect(DeepLink.validDocumentID(String(repeating: "a", count: 1501)) == nil)
        #expect(DeepLink.validDocumentID(String(repeating: "a", count: 1500)) != nil)
        // Length is in bytes, not characters: 500 three-byte characters is 1500.
        #expect(DeepLink.validDocumentID(String(repeating: "字", count: 501)) == nil)
    }

    @Test func controlCharactersAreRefused() {
        #expect(DeepLink.validDocumentID("abc\u{0}def") == nil)
        #expect(DeepLink.validDocumentID("abc\ndef") == nil)
    }

    // MARK: - Unknown shapes land on the feed without erroring

    @Test func unknownShapesFallToTheFeed() {
        // `petnote://pet/mochi` used to be here, as a shape with no route. It
        // has one now (`aPetLinkOpensThePet`); what stays unknown is a pet
        // link with the wrong number of segments.
        #expect(DeepLink.route(for: URL(string: "petnote://pet/mochi/extra")!) == .feed)
        #expect(DeepLink.route(for: URL(string: "petnote://pet")!) == .feed)
        #expect(DeepLink.route(for: URL(string: "https://petnote.app/admin")!) == .feed)
        #expect(DeepLink.route(for: URL(string: "https://petnote.app/post/abc/extra")!) == .feed)
        #expect(DeepLink.route(for: URL(string: "https://petnote.app/post")!) == .feed)
        #expect(DeepLink.route(forPath: "/post/") == .feed)
    }

    @Test func aLinkNeverConveysPermission() {
        // There is no route case that carries a role, a token or a capability;
        // this test exists so adding one is a visible decision.
        let route = DeepLink.route(for: URL(string: "https://petnote.app/post/abc?admin=1&token=xyz")!)
        #expect(route == .postDetail(postID: "abc"))
    }
}
