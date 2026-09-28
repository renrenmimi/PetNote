import FirebaseFirestore
import Foundation
import Testing

@testable import PetNote

/// What the app keeps on the phone: the two findings of the legal review
/// that were defects rather than decisions.
struct LocalDataTests {
    /// Every build keeps Firestore in memory. The cloud builds used to skip
    /// this and write the SDK's on-disk cache (A1).
    @Test func firestoreIsMemoryOnly() {
        let settings = FirebaseBootstrap.memoryOnly(FirestoreSettings())
        #expect(settings.cacheSettings is MemoryCacheSettings)
    }

    /// A deleted account's draft goes, and no one else's does.
    @Test func forgettingADeletedAccountRemovesItsDraftOnly() async throws {
        let name = "LocalDataTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let drafts = UserDefaultsComposeDraftStore(defaults: defaults)
        drafts.save(ComposeDraft(text: "TEST CONTENT gone", petID: "pet-1"), uid: "deleted")
        drafts.save(ComposeDraft(text: "TEST CONTENT stays", petID: "pet-2"), uid: "someone-else")

        let images = ImageLoader(session: Self.cachingSession())
        await AccountLocalData.forget(uid: "deleted", drafts: drafts, images: images)

        #expect(drafts.load(uid: "deleted") == nil, "the deleted account's draft stayed on the phone")
        #expect(drafts.load(uid: "someone-else")?.text == "TEST CONTENT stays")
    }

    /// And the pictures on disk go with it — checked on the cache itself,
    /// not on what the loader says it did.
    @Test func forgettingADeletedAccountEmptiesTheImageDiskCache() async throws {
        let cache = URLCache(memoryCapacity: 1024 * 1024, diskCapacity: 4 * 1024 * 1024)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = cache
        let session = URLSession(configuration: configuration)
        let url = try #require(URL(string: "https://example.test/avatar.png"))
        let request = URLRequest(url: url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        cache.storeCachedResponse(CachedURLResponse(response: response, data: Data([1, 2, 3])), for: request)
        #expect(cache.cachedResponse(for: request) != nil, "the control: the response was not cached to begin with")

        await AccountLocalData.forget(uid: "deleted", drafts: NoDrafts(), images: ImageLoader(session: session))

        #expect(cache.cachedResponse(for: request) == nil, "a picture stayed in the disk cache")
    }

    private static func cachingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = URLCache(memoryCapacity: 1024 * 1024, diskCapacity: 0)
        return URLSession(configuration: configuration)
    }

    private struct NoDrafts: ComposeDraftStoring {
        func load(uid: String) -> ComposeDraft? { nil }
        func save(_ draft: ComposeDraft, uid: String) {}
        func clear(uid: String) {}
    }
}
