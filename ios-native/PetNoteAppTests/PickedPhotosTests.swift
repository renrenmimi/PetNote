import Foundation
import Testing
@testable import PetNote

/// An upload that waits, the first time only, until it is let go: a form
/// can be looked at while its photos are on their way. Only the first, so a
/// test whose guard is taken out fails rather than waits forever.
final class HeldUploader: MediaUploading, @unchecked Sendable {
    private let lock = NSLock()
    private var held: CheckedContinuation<Void, Never>?
    private var hasHeld = false

    var isHolding: Bool { lock.withLock { held != nil } }

    func upload(_ item: UploadItem) async throws -> UploadedAsset {
        let hold = lock.withLock { () -> Bool in
            defer { hasHeld = true }
            return !hasHeld
        }
        if hold {
            await withCheckedContinuation { continuation in lock.withLock { held = continuation } }
        }
        return UploadedAsset(
            url: URL(string: "https://res.cloudinary.com/petnote/image/upload/v1/u/held.jpg")!,
            publicID: "petnote/users/u/held", resourceType: item.resourceType, thumbnailURL: nil
        )
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { held = nil }
            return held
        }
        continuation?.resume()
    }
}

/// Photos picked to go with something being written: no more than the
/// server takes, sent in the order picked, and each sent once however many
/// times what they go with is tried.
@MainActor
@Suite struct PickedPhotosTests {
    private func photo() -> Data { UploadTestImages.jpeg(width: 200, height: 150, quality: 0.5) }

    private func url(_ n: Int) -> URL { URL(string: "https://res.cloudinary.com/petnote/image/upload/v1/u/\(n).jpg")! }

    @Test func noMoreThanTheLimit() {
        let photos = PickedPhotos(limit: 3)
        for index in 0..<4 { photos.add(data: photo(), filename: "\(index).jpg") }
        #expect(photos.items.count == 3 && photos.left == 0)

        photos.remove(photos.items[1].id)
        #expect(photos.items.count == 2 && photos.left == 1)
    }

    @Test func sentInTheOrderPickedAndOnlyOnce() async throws {
        let photos = PickedPhotos(limit: 3)
        let uploader = FakeUploader()
        photos.add(data: photo(), filename: "a.jpg")
        photos.add(data: photo(), filename: "b.jpg")

        #expect(try await photos.upload(with: uploader) == [url(1), url(2)])
        #expect(try await photos.upload(with: uploader) == [url(1), url(2)], "a second try sent them again")
        #expect(uploader.sendCount == 2)
        #expect(uploader.sentItems.allSatisfy { $0.resourceType == .image && $0.mimeType == "image/jpeg" })
    }

    /// One that fails stops the rest; the next try sends only what has not
    /// gone, in the order picked.
    @Test func afterAFailureOnlyWhatHasNotGoneIsSent() async throws {
        let photos = PickedPhotos(limit: 3)
        let uploader = FakeUploader()
        uploader.fail(atSend: [2])
        for name in ["a", "b", "c"] { photos.add(data: photo(), filename: "\(name).jpg") }

        await #expect(throws: UploadError.self) { try await photos.upload(with: uploader) }
        #expect(uploader.sendCount == 2, "the one after the failure was sent")
        #expect(try await photos.upload(with: uploader) == [url(1), url(3), url(4)])
        #expect(uploader.sendCount == 4)
    }

    @Test func nothingChangesWhileTheyAreBeingSent() {
        let photos = PickedPhotos(limit: 3)
        photos.add(data: photo(), filename: "a.jpg")
        let first = photos.items[0].id
        photos.isLocked = true
        photos.add(data: photo(), filename: "b.jpg")
        photos.remove(first)
        // The same photo, not a count that one added and one taken out keep.
        #expect(photos.items.map(\.id) == [first])
    }
}
