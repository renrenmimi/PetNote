import Foundation
import Testing

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
