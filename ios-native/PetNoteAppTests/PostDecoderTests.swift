import Foundation
import Testing

@testable import PetNote

/// Each case here corresponds to a defence in `toPost`
/// (src/services/posts.ts:95), which is the contract's source of truth. Remove
/// the matching guard in PostDecoder and the case fails — that is what makes
/// this suite worth running rather than just green.
struct PostDecoderTests {
    /// Stands in for Firestore's `Timestamp` so the decoder can be tested
    /// without linking Firebase.
    struct StubTimestamp: PostDate {
        let postDate: Date
    }

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func valid(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var data: [String: Any] = [
            "authorId": "uid-1",
            "authorName": "Accept A",
            "authorAvatar": "https://example.com/a.png",
            "text": "TEST CONTENT hello",
            "createdAt": StubTimestamp(postDate: epoch),
            "likeCount": 3,
            "commentCount": 2,
            "tags": ["test", "walk"],
            "media": [["url": "https://example.com/1.jpg", "type": "image"]],
        ]
        for (key, value) in overrides { data[key] = value }
        return data
    }

    @Test func decodesAWellFormedDocument() {
        let post = PostDecoder.post(id: "p1", from: valid())
        #expect(post?.id == "p1")
        #expect(post?.authorID == "uid-1")
        #expect(post?.createdAt == epoch)
        #expect(post?.likeCount == 3)
        #expect(post?.tags == ["test", "walk"])
        #expect(post?.media.count == 1)
        #expect(post?.media.first?.kind == .image)
    }

    // MARK: - tags: anything that is not an array of strings degrades to []

    @Test func tagsThatAreNotAnArrayBecomeEmpty() {
        #expect(PostDecoder.post(id: "p", from: valid(["tags": "walk"]))?.tags == [])
        #expect(PostDecoder.post(id: "p", from: valid(["tags": 7]))?.tags == [])
        #expect(PostDecoder.tags(nil) == [])
    }

    @Test func nonStringTagsAreDroppedRatherThanFailingTheDocument() {
        let post = PostDecoder.post(id: "p", from: valid(["tags": ["ok", 5, "also-ok"]]))
        #expect(post?.tags == ["ok", "also-ok"])
    }

    // MARK: - counts: clamped at 0, tolerant of Firestore's number types

    @Test func negativeCountsAreClampedAtZero() {
        // A create→delete race inside trigger latency can leave likeCount at -1.
        #expect(PostDecoder.post(id: "p", from: valid(["likeCount": -1]))?.likeCount == 0)
        #expect(PostDecoder.post(id: "p", from: valid(["commentCount": -42]))?.commentCount == 0)
    }

    @Test func missingOrNonNumericCountsBecomeZero() {
        var data = valid()
        data.removeValue(forKey: "likeCount")
        #expect(PostDecoder.post(id: "p", from: data)?.likeCount == 0)
        #expect(PostDecoder.post(id: "p", from: valid(["likeCount": "3"]))?.likeCount == 0)
        #expect(PostDecoder.post(id: "p", from: valid(["likeCount": Double.nan]))?.likeCount == 0)
    }

    @Test func countsArriveAsAnyOfFirestoresNumberTypes() {
        #expect(PostDecoder.count(Int64(5)) == 5)
        #expect(PostDecoder.count(Double(5)) == 5)
        #expect(PostDecoder.count(NSNumber(value: 5)) == 5)
    }

    // MARK: - media: one bad item must not cost the page

    @Test func malformedMediaEntriesAreDroppedNotFatal() {
        let post = PostDecoder.post(id: "p", from: valid(["media": [
            ["url": "https://example.com/ok.jpg", "type": "image"],
            ["type": "image"],                                        // no url
            ["url": "https://example.com/x.jpg", "type": "hologram"],  // unknown type
            ["url": "", "type": "image"],                              // empty url
        ]]))
        #expect(post?.media.count == 1)
        #expect(post?.media.first?.url.absoluteString == "https://example.com/ok.jpg")
    }

    @Test func mediaThatIsNotAnArrayFallsBackToTheLegacyPair() {
        let post = PostDecoder.post(id: "p", from: valid([
            "media": "https://example.com/1.jpg",
            "mediaUrl": "https://example.com/legacy.jpg",
            "mediaType": "image",
        ]))
        #expect(post?.media.map(\.url.absoluteString) == ["https://example.com/legacy.jpg"])
    }

    @Test func aVideoKeepsItsPosterFrame() {
        let post = PostDecoder.post(id: "p", from: valid(["media": [[
            "url": "https://res.cloudinary.com/demo/video/upload/v1/dog.mp4",
            "type": "video",
            "thumbUrl": "https://res.cloudinary.com/demo/video/upload/so_0/v1/dog.jpg",
        ]]]))
        #expect(post?.media.first?.kind == .video)
        #expect(post?.media.first?.thumbnailURL?.absoluteString.contains("so_0") == true)
    }

    @Test func nonHTTPMediaURLsAreRejected() {
        // A document field must not be able to point the client at file://.
        let post = PostDecoder.post(id: "p", from: valid(["media": [
            ["url": "file:///etc/passwd", "type": "image"],
        ]]))
        #expect(post?.media.isEmpty == true)
    }

    // MARK: - required fields

    @Test func aDocumentWithoutAnAuthorIsRejected() {
        var data = valid()
        data.removeValue(forKey: "authorId")
        #expect(PostDecoder.post(id: "p", from: data) == nil)
        #expect(PostDecoder.post(id: "p", from: valid(["authorId": ""])) == nil)
    }

    @Test func aDocumentWithoutATimestampIsRejected() {
        var data = valid()
        data.removeValue(forKey: "createdAt")
        #expect(PostDecoder.post(id: "p", from: data) == nil)
        // A string date is not a timestamp, and guessing at its format would be
        // worse than dropping the document.
        #expect(PostDecoder.post(id: "p", from: valid(["createdAt": "2026-09-18"])) == nil)
    }

    // MARK: - optional identity fields degrade instead of failing

    @Test func aPostWithNoPetDecodes() {
        var data = valid()
        data.removeValue(forKey: "petId")
        data.removeValue(forKey: "petName")
        let post = PostDecoder.post(id: "p", from: data)
        #expect(post != nil)
        #expect(post?.petID == nil)
        #expect(post?.petName == nil)
    }

    @Test func emptyStringIdentityFieldsReadAsAbsent() {
        let post = PostDecoder.post(id: "p", from: valid(["petId": "", "petName": ""]))
        #expect(post?.petID == nil)
        #expect(post?.petName == nil)
    }
}
