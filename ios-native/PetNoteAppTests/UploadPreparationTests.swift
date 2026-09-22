import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PetNote

/// Image fixtures, made here rather than checked in.
///
/// A committed .heic would prove ImageIO can read *that file*; one encoded by
/// the same framework on the same machine proves the round trip the composer
/// actually performs. It also keeps a binary out of the repository.
enum UploadTestImages {
    /// A picture with real detail in it. A flat colour compresses to almost
    /// nothing, so a flat fixture would pass the "it got under 2 MB" test
    /// without the quality ladder ever running — the test would be measuring
    /// JPEG, not the code.
    static func noisy(width: Int, height: Int, seed: UInt64 = 42) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        var state = seed
        // A cheap deterministic PRNG: the fixture has to be the same every run
        // or a size assertion is a coin toss.
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 33) % 1000) / 1000.0
        }
        let block = 4
        for y in stride(from: 0, to: height, by: block) {
            for x in stride(from: 0, to: width, by: block) {
                context.setFillColor(
                    CGColor(red: next(), green: next(), blue: next(), alpha: 1)
                )
                context.fill(CGRect(x: x, y: y, width: block, height: block))
            }
        }
        return context.makeImage()!
    }

    static func encoded(
        _ image: CGImage, as type: UTType, quality: CGFloat = 1.0, orientation: Int? = nil
    ) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil
        ) else { return nil }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func jpeg(width: Int, height: Int, quality: CGFloat = 1.0) -> Data {
        encoded(noisy(width: width, height: height), as: .jpeg, quality: quality)!
    }

    /// A one-frame GIF. Enough for the passthrough rule, which is about the
    /// container rather than about how many frames are in it.
    static func gif(width: Int = 64, height: Int = 64) -> Data {
        encoded(noisy(width: width, height: height), as: .gif)!
    }
}

/// What happens to a photo between the picker and Cloudinary.
///
/// The output contract is the web client's — longest edge 1920, JPEG, 2 MB —
/// because both clients' photos land in the same feed and are served by the
/// same CDN. These tests pin the numbers, not just the mechanism.
struct UploadPreparationTests {
    // MARK: - HEIC

    /// The reason there is no `heic2any` equivalent in this client.
    ///
    /// ImageIO reads HEIC natively, so the conversion is the same call that
    /// does the downscale. If this ever fails on a platform that cannot encode
    /// HEIC, the `#require` says so rather than the test failing for a reason
    /// that looks like the code's.
    @Test func aHeicPhotoBecomesJpegWithNoBundledDecoder() throws {
        let heic = try #require(
            UploadTestImages.encoded(UploadTestImages.noisy(width: 800, height: 600), as: .heic),
            "this platform cannot encode HEIC, so the decode path cannot be exercised"
        )
        #expect(UploadPreparation.imageType(of: heic) == UTType.heic.identifier)

        let prepared = try UploadPreparation.prepareImage(heic, filename: "IMG_0001.HEIC")

        #expect(prepared.wasTranscoded)
        #expect(prepared.mimeType == "image/jpeg")
        // The bytes, not the name: a JPEG extension on HEIC bytes is exactly
        // the mistake this is meant to rule out.
        #expect(UploadPreparation.imageType(of: prepared.data) == UTType.jpeg.identifier)
        #expect(prepared.filename == "IMG_0001.jpg")
    }

    /// A small HEIC is still converted.
    ///
    /// The size shortcut must not reach it: the reason for converting is that
    /// the other client cannot decode HEIC at all, and that is true of a 40 KB
    /// one.
    @Test func aSmallHeicIsConvertedAnyway() throws {
        let heic = try #require(
            UploadTestImages.encoded(UploadTestImages.noisy(width: 120, height: 120), as: .heic),
            "this platform cannot encode HEIC, so the decode path cannot be exercised"
        )
        #expect(heic.count < UploadPreparation.Options.default.targetBytes)

        let prepared = try UploadPreparation.prepareImage(heic, filename: "small.heic")

        #expect(prepared.wasTranscoded)
        #expect(UploadPreparation.imageType(of: prepared.data) == UTType.jpeg.identifier)
    }

    // MARK: - Size and shape

    @Test func aLargePhotoIsDownsampledToTheLongestEdgeTheFeedAsksFor() throws {
        let original = UploadTestImages.jpeg(width: 4032, height: 3024)
        let prepared = try UploadPreparation.prepareImage(original, filename: "big.jpg")
        let size = try #require(UploadPreparation.pixelSize(of: prepared.data))

        #expect(max(size.width, size.height) <= UploadPreparation.Options.default.maxPixelSize)
        // Downsampled, not cropped: the shape has to survive.
        #expect(abs(size.width / size.height - 4032.0 / 3024.0) < 0.01)
    }

    @Test func thePreparedPhotoGetsUnderTheTwoMegabyteTarget() throws {
        let original = UploadTestImages.jpeg(width: 4032, height: 3024)
        #expect(
            original.count > UploadPreparation.Options.default.targetBytes,
            "the fixture has to start over the target or this asserts nothing"
        )

        let prepared = try UploadPreparation.prepareImage(original, filename: "big.jpg")

        #expect(prepared.data.count <= UploadPreparation.Options.default.targetBytes)
        #expect(prepared.data.count < original.count)
    }

    /// The quality ladder, exercised directly.
    ///
    /// The step is what stops every photo being encoded at 0.3 to satisfy the
    /// worst case, so it is worth showing that a lower target really does force
    /// the loop further down.
    @Test func theQualityLadderStepsDownUntilItFits() throws {
        let original = UploadTestImages.jpeg(width: 2400, height: 1800)
        var strict = UploadPreparation.Options.default
        strict.targetBytes = 120_000
        var lenient = UploadPreparation.Options.default
        lenient.targetBytes = 10 * 1024 * 1024

        let tight = try UploadPreparation.encodeJPEG(original, options: strict)
        let loose = try UploadPreparation.encodeJPEG(original, options: lenient)

        #expect(tight.count < loose.count)
    }

    // MARK: - Passthrough

    @Test func anAnimatableGifIsNeverReEncoded() throws {
        let gif = UploadTestImages.gif()
        let prepared = try UploadPreparation.prepareImage(gif, filename: "cat.gif")

        #expect(!prepared.wasTranscoded)
        #expect(prepared.data == gif)
        #expect(prepared.filename == "cat.gif")
    }

    @Test func aSmallJpegGoesUpUntouched() throws {
        let small = UploadTestImages.jpeg(width: 400, height: 400, quality: 0.6)
        #expect(small.count < UploadPreparation.Options.default.targetBytes)

        let prepared = try UploadPreparation.prepareImage(small, filename: "snap.jpg")

        #expect(!prepared.wasTranscoded)
        #expect(prepared.data == small, "re-encoding a photo that already fits only loses quality")
    }

    /// A photo that fits the byte target but not the pixel target is still
    /// resized.
    ///
    /// The web client checks only the byte size, so a highly compressible
    /// 6000px panorama went up at full resolution. The feed never draws it
    /// larger than 1200px, so those pixels cost the person's data and buy
    /// nothing.
    @Test func aSmallFileWithTooManyPixelsIsStillResized() throws {
        // Flat, so it compresses far under the byte target while staying huge.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 4000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4000, height: 1000))
        let flat = UploadTestImages.encoded(context.makeImage()!, as: .jpeg, quality: 0.5)!
        #expect(flat.count < UploadPreparation.Options.default.targetBytes)

        let prepared = try UploadPreparation.prepareImage(flat, filename: "wide.jpg")
        let size = try #require(UploadPreparation.pixelSize(of: prepared.data))

        #expect(prepared.wasTranscoded)
        #expect(max(size.width, size.height) <= UploadPreparation.Options.default.maxPixelSize)
    }

    // MARK: - Refusals

    @Test func anAbsurdlyLargeFileIsRefusedBeforeItIsDecoded() {
        var options = UploadPreparation.Options.default
        options.maxInputBytes = 1024
        let oversized = Data(repeating: 0xAB, count: 4096)

        #expect(throws: UploadPreparation.PreparationError.self) {
            _ = try UploadPreparation.prepareImage(oversized, filename: "x.jpg", options: options)
        }
    }

    @Test func somethingThatIsNotAnImageIsReportedAsUndecodable() {
        let notAnImage = Data("this is not a photograph".utf8)

        #expect(throws: UploadPreparation.PreparationError.undecodable) {
            _ = try UploadPreparation.prepareImage(notAnImage, filename: "x.jpg")
        }
    }

    // MARK: - Orientation

    /// A portrait photo taken on a phone is stored landscape with an EXIF tag.
    ///
    /// Two things follow, and both have been shipped wrong before: the
    /// *reported* shape has to be the shape a person sees, and the re-encode
    /// has to bake the rotation in, because a JPEG written without the tag and
    /// without the rotation is a photo on its side.
    @Test func aRotatedPhotoIsReportedAndWrittenTheWayItIsSeen() throws {
        // Orientation 6: stored landscape, displayed portrait.
        let rotated = try #require(
            UploadTestImages.encoded(
                UploadTestImages.noisy(width: 1200, height: 800), as: .jpeg, orientation: 6
            )
        )
        let reported = try #require(UploadPreparation.pixelSize(of: rotated))
        #expect(reported.width < reported.height, "an orientation-6 photo is portrait to the viewer")

        let encoded = try UploadPreparation.encodeJPEG(rotated)
        let afterward = try #require(UploadPreparation.pixelSize(of: encoded))
        #expect(afterward.width < afterward.height, "the rotation has to survive the re-encode")
    }

    // MARK: - Naming

    @Test func aTranscodedFileLosesItsOldExtension() {
        #expect(UploadPreparation.renamed("IMG_0042.HEIC", to: "jpg") == "IMG_0042.jpg")
        #expect(UploadPreparation.renamed("no-extension", to: "jpg") == "no-extension.jpg")
        #expect(UploadPreparation.renamed("", to: "jpg") == "upload.jpg")
    }
}
