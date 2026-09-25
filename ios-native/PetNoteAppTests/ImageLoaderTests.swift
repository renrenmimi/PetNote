import Foundation
import SwiftUI
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
        // The token travels on every request this session makes, so the stub
        // that answers is this test's and no one else's.
        configuration.httpAdditionalHeaders = [
            StubURLProtocol.tokenHeader: StubURLProtocol.install(stub)
        ]
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

    // MARK: - Scrolling away

    /// **A row that has gone must stop the bytes, not merely stop waiting.**
    ///
    /// `Task.cancel()` returning and the caller getting a `CancellationError`
    /// both happen whether or not the download is still running, so neither
    /// can settle this. The transport being told to stop is the fact.
    @Test func theLastRowScrollingAwayReallyStopsTheDownload() async throws {
        let (loader, stub) = loader()
        stub.respond(with: try Self.png(side: 400), status: 200, delay: .milliseconds(3000))

        let caller = Task { try await loader.image(for: photo, maxPixelSize: 300) }
        try await Self.waitUntil("the request to leave") { stub.requestCount == 1 }
        try await Self.waitUntil("the caller to register") {
            await loader.subscriberCountForTesting(url: self.photo, maxPixelSize: 300) == 1
        }

        caller.cancel()
        await #expect(throws: CancellationError.self) { _ = try await caller.value }
        try await Self.waitUntil("the transport to be told to stop") { stub.cancelCount == 1 }
        #expect(stub.cancelCount == 1)

        // And the register is clean afterwards, so the next row starts fresh
        // rather than joining a request that no longer exists.
        try await Self.waitUntil("the register to empty") {
            await loader.inFlightCountForTesting() == 0
        }
    }

    /// **What a stopped download is called, and why the name matters.**
    ///
    /// `RemoteImage` catches `is CancellationError` to mean "the row scrolled
    /// away, leave the placeholder alone", and anything else to mean "show
    /// Tap to retry". `URLSession` throws `URLError(.cancelled)`, which is
    /// not a `CancellationError` — so that first branch was unreachable and
    /// every photo whose request a scroll stopped came back wearing a retry
    /// button. `failed` is `@State` and survives the row returning, and the
    /// failed branch has no `.task` on it, so the photo stayed broken until
    /// someone tapped it.
    @Test func scrollingAwayIsReportedAsCancellationAndNotAsAFailure() async throws {
        let (loader, stub) = loader()
        stub.respond(with: try Self.png(side: 400), status: 200, delay: .milliseconds(3000))

        let caller = Task { try await loader.image(for: photo, maxPixelSize: 300) }
        try await Self.waitUntil("the request to leave") { stub.requestCount == 1 }
        caller.cancel()

        do {
            _ = try await caller.value
            Issue.record("a cancelled load returned an image")
        } catch {
            let description = "a scroll produced \(type(of: error)) — \(error) — which "
                + "RemoteImage reads as a broken photo and answers with a retry button"
            #expect(error is CancellationError, "\(description)")
        }
    }

    /// **The one that is easy to get wrong.**
    ///
    /// Two rows want the same avatar, so there is one download. One of them
    /// scrolls away. Cancelling on the first caller to leave kills a request
    /// the *other* row is still showing a placeholder for — and because
    /// `RemoteImage` treats a cancellation as "scrolled away, not a failure",
    /// that row keeps a grey rectangle forever with no retry offered. The
    /// visible symptom is indistinguishable from the load never starting.
    @Test func aRowScrollingAwayDoesNotCancelTheRowBesideIt() async throws {
        let (loader, stub) = loader()
        stub.respond(with: try Self.png(side: 400), status: 200, delay: .milliseconds(1200))

        let leaving = Task { try await loader.image(for: photo, maxPixelSize: 300) }
        let staying = Task { try await loader.image(for: photo, maxPixelSize: 300) }
        // Both registered on the same request: that is the precondition, and
        // asserting it is what stops this passing for the wrong reason.
        try await Self.waitUntil("both rows to join one request") {
            await loader.subscriberCountForTesting(url: self.photo, maxPixelSize: 300) == 2
        }
        #expect(stub.requestCount == 1)

        leaving.cancel()
        _ = try? await leaving.value

        let image = try await staying.value
        #expect(image.size.width > 0, "the row that stayed never got its picture")
        #expect(stub.cancelCount == 0, "the shared download was stopped while a row still needed it")
        #expect(stub.requestCount == 1, "it was restarted rather than shared")
    }

    /// A cancellation belongs to the stub that started the request.
    ///
    /// This is the timing that made `aRowScrollingAwayDoesNotCancelTheRowBesideIt`
    /// fail intermittently, written down so it fails on purpose instead of by
    /// luck. `StubURLProtocol` is installed globally and each test replaces
    /// the previous one; `.serialized` orders the tests but does not wait for
    /// `URLSession` to finish tearing a cancelled request down. So a stop
    /// belonging to an earlier test could arrive after the next test had
    /// installed its own stub and be counted there — a cancellation appearing
    /// in a test that never cancelled anything.
    ///
    /// Reproduced here without waiting for luck: one request is left open, a
    /// second stub is installed underneath it exactly as the next test would,
    /// and only then is the first request cancelled.
    @Test func aCancellationIsCountedByTheTransportThatStartedTheRequest() async throws {
        let (first, startedIt) = loader()
        startedIt.respond(with: try Self.png(side: 200), status: 200, delay: .seconds(5))

        let request = Task { try await first.image(for: photo, maxPixelSize: 300) }
        try await Self.waitUntil("the request to reach the transport") {
            startedIt.requestCount == 1
        }

        // The next test's fixture arrives while that request is still open.
        let (_, theNextTestsStub) = loader()

        request.cancel()
        _ = try? await request.value
        try await Self.waitUntil("the transport to be told to stop") {
            startedIt.cancelCount == 1
        }

        #expect(startedIt.cancelCount == 1,
                "the stub that started the request did not see its cancellation")
        #expect(theNextTestsStub.cancelCount == 0,
                "a cancellation from an earlier request was counted by the stub installed after it")
        #expect(theNextTestsStub.requestCount == 0,
                "the second stub answered a request that was not made through it")
    }

    /// The register must not outlive the work, or the next screenful joins a
    /// request that finished long ago — or, worse, one that was cancelled.
    @Test func nothingIsLeftBehindAfterAScreenfulComesAndGoes() async throws {
        let (loader, stub) = loader()
        stub.respond(with: try Self.png(side: 200), status: 200, delay: .milliseconds(150))

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let task = Task { try await loader.image(for: self.photo, maxPixelSize: 300) }
                    if index % 2 == 0 {
                        try? await Task.sleep(for: .milliseconds(40))
                        task.cancel()
                    }
                    _ = try? await task.value
                }
            }
        }

        try await Self.waitUntil("the register to empty") {
            await loader.inFlightCountForTesting() == 0
        }
        #expect(await loader.subscriberCountForTesting(url: photo, maxPixelSize: 300) == 0)
    }

    /// **A row that is still on screen must never be told it was cancelled.**
    ///
    /// Repeated, because the shape being looked for is an ordering one: a
    /// release belonging to a caller that has already gone landing *after* a
    /// new caller registered, and cancelling that new caller's download. A
    /// single pass cannot tell "correct" from "the interleaving did not
    /// happen this time".
    @Test func aRowThatStaysIsNeverToldItWasCancelled() async throws {
        let (loader, stub) = loader()
        stub.respond(with: try Self.png(side: 120), status: 200, delay: .milliseconds(6))

        var failures: [String] = []
        for round in 0..<120 {
            // A fresh size each round, so the memory cache cannot answer and
            // every round is a real request with a real register entry.
            let pixels = CGFloat(130 + round * 128)
            let leaving = Task { try await loader.image(for: photo, maxPixelSize: pixels) }
            let staying = Task { try await loader.image(for: photo, maxPixelSize: pixels) }
            try? await Task.sleep(for: .milliseconds(3))
            leaving.cancel()
            _ = try? await leaving.value
            do {
                _ = try await staying.value
            } catch {
                failures.append("round \(round): \(error)")
            }
        }
        #expect(failures.isEmpty, "rows still on screen were cancelled: \(failures.prefix(5))")
    }

    // MARK: - Memory

    /// §11.3: a memory warning drops the decoded photos and keeps the list.
    ///
    /// The observer is started from app launch, and the notification it wants
    /// can arrive at any moment after that — including before an async
    /// sequence has got round to subscribing. This project has already been
    /// bitten by exactly that shape once, in the audio-interruption observer.
    @Test func aMemoryWarningDropsTheDecodedPhotos() async throws {
        let (loader, stub) = loader()
        stub.respond(with: try Self.png(side: 300), status: 200)
        _ = try await loader.image(for: photo, maxPixelSize: 300)
        #expect(await loader.isCachedForTesting(url: photo, maxPixelSize: 300))

        loader.observeMemoryWarnings()
        // Give the observer a turn to subscribe before the warning is posted.
        // If this had to be longer than a yield, that would itself be the
        // finding — see the comment above.
        try await Task.sleep(for: .milliseconds(50))
        await MainActor.run {
            NotificationCenter.default.post(
                name: UIApplication.didReceiveMemoryWarningNotification, object: nil
            )
        }

        try await Self.waitUntil("the cache to be dropped") {
            await loader.isCachedForTesting(url: self.photo, maxPixelSize: 300) == false
        }
        // And the next ask really goes back to the network, rather than
        // silently drawing nothing.
        _ = try await loader.image(for: photo, maxPixelSize: 300)
        #expect(stub.requestCount == 2)
    }

    // MARK: -

    /// Polls a condition, and says what it was waiting for when it gives up.
    /// A bare `Task.sleep` would turn every ordering failure into a timeout
    /// with no name on it.
    static func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(10),
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout.seconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)")
    }

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
    private var cancelled: [URL] = []

    func respond(with data: Data, status: Int, delay: Duration = .zero) {
        lock.withLock {
            self.data = data
            self.status = status
            self.delay = delay
        }
    }

    var requestCount: Int { lock.withLock { seen.count } }
    /// How many requests were stopped **before they had delivered anything**.
    ///
    /// The qualifier is the whole of it, and it was measured: `URLSession`
    /// calls `stopLoading` on a protocol that has already finished, as
    /// ordinary teardown. Counting every `stopLoading` reported a cancelled
    /// download on a load that completed perfectly — "the shared download was
    /// stopped while a row still needed it", about a row that got its picture.
    /// A metric that says the code is broken when it is not is worse than no
    /// metric.
    var cancelCount: Int { lock.withLock { cancelled.count } }

    fileprivate func record(_ url: URL) -> (Data, Int, Duration) {
        lock.withLock {
            seen.append(url)
            return (data, status, delay)
        }
    }

    fileprivate func recordCancel(_ url: URL) {
        lock.withLock { cancelled.append(url) }
    }
}

/// Answers every request from the installed `StubTransport`.
///
/// `URLProtocol` rather than a protocol-shaped seam in `ImageLoader`: the point
/// is to measure what actually leaves the loader, including the request
/// coalescing, and a hand-rolled seam would let the thing under test be the
/// thing that is faked.
final class StubURLProtocol: URLProtocol {
    /// Transports by token, **not one global "current" transport**.
    ///
    /// `install` used to replace a single static, and every request was
    /// attributed to whatever was installed at the moment it was handled. A
    /// test's `URLSession` is torn down asynchronously and `.serialized` does
    /// not wait for that, so one test's traffic could be counted by the next
    /// test's stub.
    ///
    /// The first fix only moved `recordCancel` onto the transport that started
    /// the request, which closed the cancel path and left the request path
    /// open: `aRowScrollingAwayDoesNotCancelTheRowBesideIt` then failed on
    /// `stub.requestCount == 1` instead of `stub.cancelCount == 0` — the same
    /// leak through a different counter, and a reminder that fixing the symptom
    /// that was observed is not the same as fixing the thing that caused it.
    ///
    /// A token on the session, carried by every request it makes, decides which
    /// transport hears about it. Traffic from a session that has gone away
    /// carries that session's token and is counted there, where nobody is
    /// looking any more, instead of landing in the next test's numbers.
    nonisolated(unsafe) private static var transports: [String: StubTransport] = [:]
    private static let lock = NSLock()

    static let tokenHeader = "X-PetNote-Stub-Token"

    /// Registers a transport and returns the token that routes traffic to it.
    static func install(_ transport: StubTransport) -> String {
        let token = UUID().uuidString
        lock.withLock { Self.transports[token] = transport }
        return token
    }

    private static func transport(for request: URLRequest) -> StubTransport? {
        guard let token = request.value(forHTTPHeaderField: tokenHeader) else { return nil }
        return lock.withLock { Self.transports[token] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Set by `stopLoading`, read by the delayed delivery. Without it a
    /// cancelled request still hands bytes to a client that has gone, which
    /// makes a cancelled load look exactly like a successful one.
    private let stopped = NSLock.Flag()
    /// Raised once the response has been handed over in full.
    private let delivered = NSLock.Flag()

    /// The transport that **started** this request.
    ///
    /// `stopLoading` used to ask `Self.transport` for the transport to record
    /// against, which is the one installed *now* rather than the one this
    /// request belongs to. `URLSession` tears a cancelled request down
    /// asynchronously, and `.serialized` orders the tests without waiting for
    /// that, so a cancellation raised by one test could be counted by the
    /// next test's stub. The suite has a test three above this one that
    /// cancels on purpose and asserts `cancelCount == 1`; its stop arriving
    /// late is a cancellation appearing in a test that never cancelled
    /// anything.
    ///
    /// That is what `aRowScrollingAwayDoesNotCancelTheRowBesideIt` was
    /// reporting — intermittently, on CI as well as locally, which is what
    /// ruled out machine load.
    private var owner: StubTransport?

    override func startLoading() {
        guard let url = request.url,
              let transport = Self.transport(for: request) else {
            // No token, or a token whose transport is gone: answer with an
            // error rather than picking whichever transport happens to be
            // registered. Guessing here is the defect this replaced.
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        owner = transport
        let (data, status, delay) = transport.record(url)
        let client = self.client
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let deliver = { [weak self] in
            guard let self, !self.stopped.isSet else { return }
            // **Raised before the handover, not after it.** `stopLoading`
            // counts a stop as a cancellation when `delivered` is not yet set,
            // so a teardown landing between `didLoad` and `delivered.set()`
            // used to be counted as "the download was stopped" about bytes
            // that had just been handed over. This stub delivers the whole
            // response in one go, so there is no partial state that raising
            // the flag first could misreport.
            //
            // Latent rather than observed: unlike the attribution defect above
            // it, nothing has been seen to land in that window. It is closed
            // because it is the same false positive by a second route, and
            // three lines is cheaper than telling the two apart later.
            self.delivered.set()
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

    override func stopLoading() {
        let hadFinished = delivered.isSet
        stopped.set()
        // Only a stop that arrives before the bytes did is a cancellation.
        guard !hadFinished, let url = request.url else { return }
        // `owner`, not `Self.transport`: see the note on `owner`.
        owner?.recordCancel(url)
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}


extension NSLock {
    /// A one-way flag that is safe to read from any thread.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}

// MARK: - Can you actually see the whole photo?

/// The full-image screen exists for one reason: the feed frame crops, so
/// there has to be somewhere the *whole* picture is reachable. That is a claim
/// about pixels, and the existing UI test for it only ever checked that the
/// close button appeared — a screen showing a centre crop would have passed it.
///
/// These render the real `FullImageView` into a window and look at what came
/// out. The photo is three coloured bands; if the outer two are missing, the
/// screen that promises the whole photo is showing the middle of it.
@MainActor
@Suite(.serialized)
struct FullImageViewTests {
    /// Wider than the screen's shape by a long way — a panorama.
    @Test func aWidePhotoIsShownWholeAndNotCropped() async throws {
        let url = try Self.bandedImage(width: 1200, height: 300, named: "wide")
        let seen = try await Self.render(FullImageView(url: url))
        #expect(
            seen.hasRed && seen.hasGreen && seen.hasBlue,
            "a 4:1 photo lost its ends on the screen that promises the whole photo — \(seen)"
        )
    }

    /// The other shape, and the one a phone photo is more likely to be: a long
    /// portrait that the feed's 4:5 frame cuts the top and bottom off.
    @Test func aLongPhotoIsShownWholeAndNotCropped() async throws {
        let url = try Self.bandedImage(width: 300, height: 1200, named: "long")
        let seen = try await Self.render(FullImageView(url: url))
        #expect(
            seen.hasRed && seen.hasGreen && seen.hasBlue,
            "a 1:4 photo lost its ends on the screen that promises the whole photo — \(seen)"
        )
    }

    /// **The same photo, the same window, the frame mode this screen used to
    /// ask for — and the ends are gone.**
    ///
    /// This is the defect, kept as a test rather than as a paragraph.
    /// `FullImageView` called `RemoteImage(url:aspectRatio: 1, size: .large)`,
    /// which reserves a square and fills it: `scaledToFill` inside a fixed
    /// frame, then clipped. On a 402x874 window a 4:1 photo keeps roughly its
    /// middle quarter, and pinch-to-zoom cannot bring back what was clipped —
    /// it magnifies the crop. Paired with `aWidePhotoIsShownWholeAndNotCropped`
    /// above: same harness, same picture, one parameter different.
    ///
    /// It is also the feed's correct behaviour, which is why the mode still
    /// exists: the feed trades the edges for a row height that does not move
    /// when the bytes land, and says so with the "tap for the whole photo"
    /// hint. The bug was using that trade on the screen the hint points at.
    @Test func theOldFixedSquareFrameLosesTheEndsOfAWidePhoto() async throws {
        let url = try Self.bandedImage(width: 1200, height: 300, named: "wide-reserved")
        let seen = try await Self.render(
            ZStack {
                Color.black
                RemoteImage(url: url, aspectRatio: 1, size: .large, fit: .reservedFrame)
            }
        )
        #expect(seen.hasGreen, "the middle of the photo should still be there — \(seen)")
        let note = "this is the cropping mode; if it now shows the ends, the pair of tests "
            + "above no longer measures anything — \(seen)"
        #expect(!seen.hasRed && !seen.hasBlue, "\(note)")
    }

    /// The control: a photo the same shape as the screen has nothing to lose,
    /// so this passes before and after and keeps the two above from being
    /// read as "the renderer cannot see anything".
    @Test func anOrdinaryPhotoIsAlsoWhole() async throws {
        let url = try Self.bandedImage(width: 800, height: 1000, named: "ordinary")
        let seen = try await Self.render(FullImageView(url: url))
        #expect(seen.hasRed && seen.hasGreen && seen.hasBlue, "\(seen)")
    }

    // MARK: -

    /// iPhone 17's points.
    private static let screen = CGSize(width: 402, height: 874)

    struct Seen: CustomStringConvertible {
        var hasRed = false
        var hasGreen = false
        var hasBlue = false
        /// How many coarse colours the photograph contained at all. One means
        /// the photograph is blank, which is a broken camera and not a crop.
        var distinctColours = 0
        var description: String {
            "bands seen: red=\(hasRed) green=\(hasGreen) blue=\(hasBlue) "
                + "(distinct colours in the photograph: \(distinctColours))"
        }
    }

    /// Hosts the view for real and photographs it.
    ///
    /// A `UIWindow` rather than `ImageRenderer`: the load is asynchronous, and
    /// `ImageRenderer` draws once and returns — it would photograph the
    /// placeholder every time and report that nothing is ever visible.
    private static func render(_ view: some View) async throws -> Seen {
        // **The window has to belong to a foreground scene.**
        //
        // A bare `UIWindow(frame:)` in a test process belongs to no scene, and
        // `drawHierarchy` then refuses: it logs "Rendering a window requires
        // it to be in a foreground scene" and returns false. The first run of
        // these tests photographed nothing at all and reported every band
        // missing — including from the control photo, which is what gave the
        // measurement away rather than the code.
        let scene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
            "no window scene in the test host — nothing can be photographed"
        )
        let host = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: screen)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds

        var seen = Seen()
        let started = Date()
        let deadline = started.addingTimeInterval(20)
        var polls = 0
        while Date() < deadline {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            seen = bands(in: photograph(window))
            polls += 1
            // The middle band is on screen under every reading of the layout,
            // so its arrival is what says the photo has loaded and it is time
            // to judge the ends.
            if seen.hasGreen { break }
        }
        // **No green is not a crop.** Every layout keeps the middle band, so
        // without it the photo never arrived, and reporting that as "lost its
        // ends" — as CI run 35823319648 did, with all three bands missing —
        // blames the layout for a load. The poll count says which kind of
        // slow it was: about 200 is a load that took too long; a handful is
        // this test not getting the main actor at all.
        if !seen.hasGreen {
            window.isHidden = true
            throw RenderError.photoNeverAppeared(
                "no band of the photo appeared in \(Int(Date().timeIntervalSince(started)))s "
                    + "(\(polls) polls) — the load did not finish, which says nothing about cropping — \(seen)"
            )
        }
        // One more, after a settle, so a half-drawn first frame is not the
        // thing being judged.
        try await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded()
        seen = bands(in: photograph(window))
        window.isHidden = true
        // A blank photograph and a cropped photo both come back with bands
        // missing. Saying which is which here is what keeps a broken camera
        // from being reported as a product defect.
        if seen.distinctColours < 2 {
            Issue.record("the photograph came back blank — \(seen) — nothing below measures the view")
        }
        return seen
    }

    private static func photograph(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
        }
    }

    /// Which of the three band colours appear anywhere in the picture.
    private static func bands(in image: UIImage) -> Seen {
        guard let cgImage = image.cgImage else { return Seen() }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Seen() }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var seen = Seen()
        var distinct = Set<Int>()
        // Every eighth pixel in each direction: a band that survives at all
        // covers far more than that, and a full sweep of a 402x874 @2x
        // photograph on every poll is waste.
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let offset = (y * width + x) * 4
                let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                if r > 170, g < 90, b < 90 { seen.hasRed = true }
                if g > 150, r < 110, b < 110 { seen.hasGreen = true }
                if b > 170, r < 90, g < 110 { seen.hasBlue = true }
                distinct.insert((r / 32) << 10 | (g / 32) << 5 | (b / 32))
            }
        }
        seen.distinctColours = distinct.count
        return seen
    }

    /// Three flat bands across the long edge: red, green, blue.
    ///
    /// A file URL, so the loader under test is the real one and no transport
    /// is faked — `URLSession` reads `file://` and the decode path is
    /// identical to a CDN's.
    private static func bandedImage(width: CGFloat, height: CGFloat, named: String) throws -> URL {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { context in
            let colours: [UIColor] = [
                UIColor(red: 1, green: 0, blue: 0, alpha: 1),
                UIColor(red: 0, green: 0.8, blue: 0, alpha: 1),
                UIColor(red: 0, green: 0, blue: 1, alpha: 1),
            ]
            let alongWidth = width > height
            for (index, colour) in colours.enumerated() {
                colour.setFill()
                let slice = (alongWidth ? width : height) / 3
                let rect = alongWidth
                    ? CGRect(x: CGFloat(index) * slice, y: 0, width: slice, height: height)
                    : CGRect(x: 0, y: CGFloat(index) * slice, width: width, height: slice)
                context.fill(rect)
            }
        }
        guard let data = image.pngData() else { throw StubError.couldNotMakeAPNG }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("petnote-\(named)-\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }

    enum StubError: Error { case couldNotMakeAPNG }

    enum RenderError: Error, CustomStringConvertible {
        case photoNeverAppeared(String)
        var description: String {
            switch self { case .photoNeverAppeared(let why): why }
        }
    }
}
