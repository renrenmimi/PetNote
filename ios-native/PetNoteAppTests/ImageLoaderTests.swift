import Foundation
import Testing
import UIKit

@testable import PetNote

/// Cache-key behaviour, pinned because the failure it prevents was measured
/// rather than imagined: the same photo was fetched at 401pt and 402pt — one
/// point apart, from a safe-area inset — and ended up downloaded twice and
/// held in memory twice.
struct ImageLoaderCacheKeyTests {
    @Test func nearIdenticalSizesShareOneEntry() {
        let url = URL(string: "https://res.cloudinary.com/demo/image/upload/v1/sample.jpg")!
        #expect(ImageLoader.cacheKeyForTesting(url: url, maxPixelSize: 401 * 3)
                == ImageLoader.cacheKeyForTesting(url: url, maxPixelSize: 402 * 3))
    }

    @Test func genuinelyDifferentSizesDoNot() {
        let url = URL(string: "https://res.cloudinary.com/demo/image/upload/v1/sample.jpg")!
        // An avatar and a full-width photo must not share a decoded copy.
        #expect(ImageLoader.cacheKeyForTesting(url: url, maxPixelSize: 40 * 3)
                != ImageLoader.cacheKeyForTesting(url: url, maxPixelSize: 402 * 3))
    }

    @Test func differentAssetsNeverCollide() {
        let a = URL(string: "https://res.cloudinary.com/demo/image/upload/v1/a.jpg")!
        let b = URL(string: "https://res.cloudinary.com/demo/image/upload/v1/b.jpg")!
        #expect(ImageLoader.cacheKeyForTesting(url: a, maxPixelSize: 1206)
                != ImageLoader.cacheKeyForTesting(url: b, maxPixelSize: 1206))
    }
}

/// The same claims, but measured against a loader that is actually asked to
/// load something.
///
/// The key tests above compare two strings. That is worth having and it is not
/// the claim: "the same photo is not cached twice" is a claim about how many
/// times the network is touched and how many decoded copies come back. These
/// count the requests, through a stubbed transport so that no CDN is involved
/// and nothing here can pass or fail because of someone else's network.
///
/// Serialized: `URLProtocol` subclasses are registered process-wide, so two of
/// these running at once answer each other's requests. The first run of this
/// suite failed that way — one test received another's 404 — which is a
/// measurement fault and would have been a confusing bug report.
@Suite(.serialized)
struct ImageLoaderBehaviourTests {
    private func loader() -> (ImageLoader, StubTransport) {
        let stub = StubTransport()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        // No URLCache: this is measuring the image loader's own cache, and a
        // second layer that also dedupes would hide whether it works.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        StubURLProtocol.install(stub)
        return (ImageLoader(session: URLSession(configuration: configuration)), stub)
    }

    private let photo = URL(string: "https://res.cloudinary.com/demo/image/upload/w_800/v1/sample.jpg")!

    /// **The measured defect.** 401pt and 402pt are one point apart because of
    /// a safe-area inset. They used to be two downloads and two decoded copies.
    @Test func aOnePointDifferenceDoesNotDownloadTheSamePhotoTwice() async throws {
        let (loader, stub) = loader()
        stub.respond(with: try Self.png(side: 600), status: 200)

        let first = try await loader.image(for: photo, maxPixelSize: 401 * 3)
        let second = try await loader.image(for: photo, maxPixelSize: 402 * 3)

        #expect(stub.requestCount == 1, "two near-identical sizes made \(stub.requestCount) requests")
        #expect(first === second, "and the second caller got the very same decoded image back")
    }

    @Test func anAvatarAndAPhotoAreNotTheSameEntry() async throws {
        let (loader, stub) = loader()
        stub.respond(with: try Self.png(side: 600), status: 200)

        let avatar = try await loader.image(for: photo, maxPixelSize: 40 * 3)
        let full = try await loader.image(for: photo, maxPixelSize: 402 * 3)

        #expect(stub.requestCount == 2)
        #expect(avatar !== full)
        // And the small one really is small — this is the memory claim.
        #expect(max(avatar.size.width, avatar.size.height) <= 128)
    }

    /// Decoding at display size is the whole reason this actor exists rather
    /// than `UIImage(data:)`.
    @Test func aLargeOriginalIsDecodedDownToTheRequestedSize() async throws {
        let (loader, stub) = loader()
        stub.respond(with: try Self.png(side: 2000), status: 200)

        let image = try await loader.image(for: photo, maxPixelSize: 300)
        // 300 rounds up to the 384 step; the point is that it is nowhere near
        // 2000, which is what a naive decode would have put in memory.
        #expect(max(image.size.width, image.size.height) <= 384)
        #expect(max(image.size.width, image.size.height) > 128)
    }

    /// Twenty rows showing the same avatar make one request, and the callers
    /// all get an image.
    @Test func manyCallersForTheSameImageShareOneDownload() async throws {
        let (loader, stub) = loader()
        stub.respond(with: try Self.png(side: 200), status: 200, delay: .milliseconds(120))

        let images = try await withThrowingTaskGroup(of: UIImage.self) { group in
            for _ in 0..<20 {
                group.addTask { try await loader.image(for: self.photo, maxPixelSize: 300) }
            }
            var collected: [UIImage] = []
            for try await image in group { collected.append(image) }
            return collected
        }

        #expect(images.count == 20)
        #expect(stub.requestCount == 1, "twenty rows made \(stub.requestCount) requests")
    }

    /// A 404 has to *fail*, and failing must not poison the entry: the retry
    /// button in `RemoteImage` is worthless if the second attempt is answered
    /// from a cached failure.
    @Test func aFailureIsRetryableAndTheRetryReallyGoesOut() async throws {
        let (loader, stub) = loader()
        stub.respond(with: Data("not found".utf8), status: 404)

        await #expect(throws: ImageLoadError.http(404)) {
            _ = try await loader.image(for: photo, maxPixelSize: 300)
        }
        #expect(stub.requestCount == 1)

        // The asset appears; tapping retry must reach the network again.
        stub.respond(with: try Self.png(side: 300), status: 200)
        let image = try await loader.image(for: photo, maxPixelSize: 300)
        #expect(stub.requestCount == 2)
        #expect(image.size.width > 0)
    }

    @Test func bytesThatAreNotAnImageFailRatherThanDrawNothing() async throws {
        let (loader, stub) = loader()
        stub.respond(with: Data(repeating: 0x7F, count: 900), status: 200)

        await #expect(throws: ImageLoadError.undecodable) {
            _ = try await loader.image(for: photo, maxPixelSize: 300)
        }
    }

    // MARK: -

    /// A real PNG of a known size, so the decode under test has something to
    /// decode.
    private static func png(side: CGFloat) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side / 2, height: side / 2))
        }
        guard let data = image.pngData() else { throw StubError.couldNotMakeAPNG }
        return data
    }

    enum StubError: Error { case couldNotMakeAPNG }
}

// MARK: - A transport that answers, and counts

/// What the stub should say, and what it was asked.
final class StubTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var status = 200
    private var delay: Duration = .zero
    private var seen: [URL] = []

    func respond(with data: Data, status: Int, delay: Duration = .zero) {
        lock.withLock {
            self.data = data
            self.status = status
            self.delay = delay
        }
    }

    var requestCount: Int { lock.withLock { seen.count } }

    fileprivate func record(_ url: URL) -> (Data, Int, Duration) {
        lock.withLock {
            seen.append(url)
            return (data, status, delay)
        }
    }
}

/// Answers every request from the installed `StubTransport`.
///
/// `URLProtocol` rather than a protocol-shaped seam in `ImageLoader`: the point
/// is to measure what actually leaves the loader, including the request
/// coalescing, and a hand-rolled seam would let the thing under test be the
/// thing that is faked.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var transport: StubTransport?
    private static let lock = NSLock()

    static func install(_ transport: StubTransport) {
        lock.withLock { Self.transport = transport }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let transport = Self.lock.withLock({ Self.transport }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (data, status, delay) = transport.record(url)
        let client = self.client
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let deliver = { [weak self] in
            guard let self else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay == .zero {
            deliver()
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay.seconds) { deliver() }
        }
    }

    override func stopLoading() {}
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
