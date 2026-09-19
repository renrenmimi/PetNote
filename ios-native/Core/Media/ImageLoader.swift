import ImageIO
import OSLog
import UIKit

/// Loads and decodes remote images.
///
/// Built rather than taken off the shelf, for the reasons in
/// docs/image-loading-decision.md — chiefly that Cloudinary already does the
/// resizing, which is the hard part, so what is left is small enough to own.
/// The whole implementation is behind this actor so swapping in Nuke later
/// means changing this file and nothing else.
actor ImageLoader {
    static let shared = ImageLoader()

    private let session: URLSession
    private let cache = NSCache<NSString, UIImage>()
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "media")

    /// In-flight requests, so twenty rows asking for the same avatar make one
    /// request rather than twenty.
    private var inFlight: [String: Task<UIImage, Error>] = [:]
    /// How many callers are waiting on each in-flight request.
    private var subscribers: [String: Int] = [:]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            // Disk caching is HTTP's job; Cloudinary sends long-lived
            // Cache-Control, and URLCache honours it without us writing an
            // eviction policy.
            configuration.urlCache = URLCache(
                memoryCapacity: 16 * 1024 * 1024,
                diskCapacity: 256 * 1024 * 1024
            )
            configuration.requestCachePolicy = .returnCacheDataElseLoad
            self.session = URLSession(configuration: configuration)
        }
        // NSCache responds to memory pressure by itself, which is most of why
        // it is here rather than a dictionary.
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    /// - Parameter maxPixelSize: the largest edge, in *pixels*, the caller will
    ///   actually draw. Decoding to the display size rather than the full image
    ///   is where the memory saving is.
    func image(for url: URL, maxPixelSize: CGFloat) async throws -> UIImage {
        let key = Self.cacheKey(url: url, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key as NSString) { return cached }

        // A caller that goes away must actually stop the work. An unstructured
        // `Task { }` does not inherit cancellation and `await task.value` is not
        // a cancellation point, so the previous shape kept downloading and
        // decoding for rows that had scrolled off — the one thing §11.3 asks
        // this layer to get right.
        //
        // The request is still coalesced: N callers for the same key share one
        // download, and it is torn down when the LAST of them goes away, not
        // the first.
        let request: Task<UIImage, Error>
        if let existing = inFlight[key] {
            request = existing
            subscribers[key, default: 0] += 1
        } else {
            request = Task { [session] in
                let (data, response) = try await session.data(from: url)
                try Task.checkCancellation()
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw ImageLoadError.http(http.statusCode)
                }
                guard let image = Self.decode(data, maxPixelSize: maxPixelSize) else {
                    throw ImageLoadError.undecodable
                }
                return image
            }
            inFlight[key] = request
            subscribers[key] = 1
        }

        do {
            let image = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                Task { await self.release(key) }
            }
            await release(key, completed: true)
            cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
            return image
        } catch {
            await release(key, completed: true)
            if !(error is CancellationError) {
                log.error("image failed: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    /// Drops one subscriber and cancels the shared download when none are left.
    private func release(_ key: String, completed: Bool = false) {
        guard let count = subscribers[key] else { return }
        if completed || count <= 1 {
            subscribers[key] = nil
            if !completed { inFlight[key]?.cancel() }
            inFlight[key] = nil
        } else {
            subscribers[key] = count - 1
        }
    }

    func clearMemoryCache() {
        cache.removeAllObjects()
        log.info("image memory cache cleared")
    }

    /// Starts listening for memory warnings.
    ///
    /// NSCache evicts under pressure on its own, but §11.3 asks for the image
    /// cache to be dropped on a warning while the list data is kept — that is a
    /// different policy from "evict something", and it needs an observer.
    /// Called once from app start.
    nonisolated func observeMemoryWarnings() {
        Task {
            let notifications = NotificationCenter.default.notifications(
                named: UIApplication.didReceiveMemoryWarningNotification
            )
            for await _ in notifications {
                await self.clearMemoryCache()
            }
        }
    }

    /// Downsamples while decoding, so a 4000px original never exists in memory
    /// at full size.
    private nonisolated static func decode(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as [CFString: Any] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private nonisolated static func cacheKey(url: URL, maxPixelSize: CGFloat) -> String {
        // The size is part of the key: the same URL decoded for a thumbnail and
        // for a detail view are different images. Cloudinary's version segment
        // is already in the URL, so a re-uploaded asset gets a new key for free.
        "\(url.absoluteString)|\(Int(maxPixelSize))"
    }

    private nonisolated static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

enum ImageLoadError: Error, Sendable, Equatable {
    case http(Int)
    case undecodable
}
