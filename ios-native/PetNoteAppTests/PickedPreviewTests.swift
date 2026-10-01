import Testing
import UIKit
@testable import PetNote

/// A picked photo's preview covers the space it is shown in, at three pixels
/// a point, whatever the photo's shape; and is never larger than the photo.
@Suite struct PickedPreviewTests {
    private func pixels(_ image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    /// The case the plain call gets wrong: a 4:3 photo for a square.
    @Test func aLandscapePhotoCoversASquare() throws {
        let data = UploadTestImages.jpeg(width: 1200, height: 900, quality: 0.5)
        let size = pixels(try #require(PickedPreview.image(from: data, covering: CGSize(width: 88, height: 88))))

        #expect(min(size.width, size.height) >= 264, "\(size)")
        #expect(size.width < 1200, "made no smaller: \(size)")
        #expect(abs(size.width / size.height - 4.0 / 3.0) < 0.01, "not the photo's shape: \(size)")
    }

    @Test func aPortraitPhotoCoversAWideSpace() throws {
        let data = UploadTestImages.jpeg(width: 1800, height: 2400, quality: 0.5)
        let size = pixels(try #require(PickedPreview.image(from: data, covering: CGSize(width: 400, height: 225))))

        #expect(size.width >= 1200 && size.height >= 675, "\(size)")
        #expect(size.width < 1800, "made no smaller: \(size)")
    }

    @Test func aPhotoSmallerThanTheSpaceIsNotEnlarged() throws {
        let data = UploadTestImages.jpeg(width: 200, height: 150, quality: 0.5)
        let size = pixels(try #require(PickedPreview.image(from: data, covering: CGSize(width: 88, height: 88))))

        #expect(size == CGSize(width: 200, height: 150))
    }

    @Test func bytesThatAreNotAPhotoHaveNone() {
        #expect(PickedPreview.image(from: Data("not a photo".utf8), covering: CGSize(width: 88, height: 88)) == nil)
    }
}
