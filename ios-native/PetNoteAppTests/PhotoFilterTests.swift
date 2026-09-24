import CoreGraphics
import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import PetNote

/// Pictures with a known colour, and a way to read colours back out of
/// encoded bytes.
///
/// Solid fills, encoded as PNG so the input is exact: the assertions are about
/// what the filter did to a known value, and a lossy input would make that a
/// statement about JPEG instead.
enum FilterTestImages {
    static var sRGB: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB() }

    static func solid(red: CGFloat, green: CGFloat, blue: CGFloat, side: Int = 64) -> Data {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return UploadTestImages.encoded(context.makeImage()!, as: .png)!
    }

    /// Left half black, right half white: an edge with nothing in between,
    /// so any value between the two is the blur's.
    static func hardEdge(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return context.makeImage()!
    }

    /// Every pixel of an encoded image as sRGB bytes, RGBX.
    static func pixels(of data: Data) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return pixels(of: image)
    }

    /// Every pixel of a picture as sRGB bytes, RGBX.
    static func pixels(of image: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raw = context.data else { return nil }
        let buffer = UnsafeBufferPointer(start: raw.assumingMemoryBound(to: UInt8.self), count: width * height * 4)
        return (Array(buffer), width, height)
    }

    /// The red channel, 0…255, of every pixel along the middle row.
    static func middleRow(of image: CGImage) -> [Int]? {
        guard let picture = pixels(of: image) else { return nil }
        let start = (picture.height / 2) * picture.width
        return (0..<picture.width).map { Int(picture.bytes[(start + $0) * 4]) }
    }

    /// The colour in the middle of an encoded image, 0…255 per channel.
    static func centre(of data: Data) -> [Int]? {
        guard let image = pixels(of: data) else { return nil }
        let offset = ((image.height / 2) * image.width + image.width / 2) * 4
        return (0..<3).map { Int(image.bytes[offset + $0]) }
    }
}

/// The ten filters, and what they do to the bytes that are uploaded.
struct PhotoFilterTests {
    /// The repository root, from this file at ios-native/PetNoteAppTests/…
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PetNoteAppTests
            .deletingLastPathComponent()   // ios-native
            .deletingLastPathComponent()   // the repository
    }

    // MARK: - Parity with the web client's table

    /// src/components/ImageFilter.tsx, row for row.
    static let webTable: [(key: String, label: String, css: String)] = [
        ("normal", "Normal", "none"),
        ("warm", "Warm", "sepia(0.3) saturate(1.4) brightness(1.1)"),
        ("cool", "Cool", "saturate(0.8) brightness(1.1) hue-rotate(15deg)"),
        ("bright", "Bright", "brightness(1.3)"),
        ("contrast", "Contrast", "contrast(1.4)"),
        ("vintage", "Vintage", "sepia(0.4) saturate(0.8) brightness(0.9)"),
        ("bw", "B&W", "grayscale(1)"),
        ("vivid", "Vivid", "saturate(1.8) contrast(1.1)"),
        ("soft", "Soft", "brightness(1.1) contrast(0.9) blur(0.5px)"),
        ("rose", "Rose", "sepia(0.2) saturate(1.3) hue-rotate(-10deg) brightness(1.05)"),
    ]

    @Test func theTenFiltersAreTheWebClientsTen() {
        #expect(PhotoFilter.allCases.map { $0.rawValue } == Self.webTable.map { $0.key },
                "same keys, in the same order the strip shows them")
        for (filter, row) in zip(PhotoFilter.allCases, Self.webTable) {
            #expect(filter.label == row.label, "\(row.key)")
            #expect(filter.css == row.css, "\(row.key): the chain is not the web client's")
        }
    }

    /// And against the web source itself, so a change there that is not made
    /// here fails a test rather than drifting.
    @Test func theTableAboveIsStillWhatTheWebClientShips() throws {
        let url = Self.repositoryRoot.appendingPathComponent("src/components/ImageFilter.tsx")
        let source = try String(contentsOf: url, encoding: .utf8)
        let regex = try NSRegularExpression(
            pattern: #"\{\s*key:\s*"([^"]+)",\s*label:\s*"([^"]+)",\s*css:\s*"([^"]+)"\s*\}"#
        )
        let rows: [[String]] = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
            .map { match in
                (1...3).compactMap { group -> String? in
                    guard let range = Range(match.range(at: group), in: source) else { return nil }
                    return String(source[range])
                }
            }
        try #require(rows.count == 10, "expected ten FILTERS rows in ImageFilter.tsx, found \(rows.count)")
        for (row, filter) in zip(rows, PhotoFilter.allCases) {
            #expect(row == [filter.rawValue, filter.label, filter.css],
                    "ImageFilter.tsx says \(row); this client says \(filter.rawValue), \(filter.label), \(filter.css)")
        }
    }

    // MARK: - The matrices are the spec's

    /// Every function at its neutral amount is the identity. A transposed
    /// coefficient or a wrong sign shows up here as a matrix that is not.
    @Test func eachFunctionAtItsNeutralAmountChangesNothing() {
        let neutral: [PhotoFilter.Step] = [
            .sepia(0), .grayscale(0), .saturate(1), .hueRotate(degrees: 0), .brightness(1), .contrast(1),
        ]
        let colour: [Double] = [0.9, 0.4, 0.1]
        for step in neutral {
            let out = step.colorMatrix?.applied(to: colour) ?? []
            #expect(out.count == 3 && zip(out, colour).allSatisfy { abs($0 - $1) < 1e-9 }, "\(step.css) is not the identity")
        }
        #expect(PhotoFilter.Step.gaussianBlur(cssPixels: 0.5).colorMatrix == nil)
    }

    /// Grey stays grey through every colour function the chains use — the
    /// property the spec's luminance weights exist to keep.
    @Test func greyStaysGreyThroughSaturateAndHueRotate() {
        let grey: [Double] = [0.5, 0.5, 0.5]
        let steps: [PhotoFilter.Step] = [.saturate(1.8), .saturate(0.8), .hueRotate(degrees: 15), .hueRotate(degrees: -10)]
        for step in steps {
            let out = step.colorMatrix?.applied(to: grey) ?? []
            #expect(out.count == 3 && out.allSatisfy { abs($0 - 0.5) < 1e-3 }, "\(step.css) tinted a grey: \(out)")
        }
    }

    // MARK: - Normal changes nothing

    /// The existing preparation path, byte for byte: passthrough stays
    /// passthrough, and the re-encode is the same re-encode.
    @Test func normalLeavesThePreparedBytesExactlyAsTheyWere() throws {
        var fixtures: [(name: String, data: Data)] = [
            ("snap.jpg", UploadTestImages.jpeg(width: 400, height: 400, quality: 0.6)),
            ("big.jpg", UploadTestImages.jpeg(width: 2400, height: 1800)),
            ("cat.gif", UploadTestImages.gif()),
            ("flat.png", FilterTestImages.solid(red: 0.2, green: 0.6, blue: 0.4)),
        ]
        if let heic = UploadTestImages.encoded(UploadTestImages.noisy(width: 800, height: 600), as: .heic) {
            fixtures.append((name: "IMG_0001.HEIC", data: heic))
        }
        for fixture in fixtures {
            let before = try UploadPreparation.prepareImage(fixture.data, filename: fixture.name)
            let normal = try UploadPreparation.prepareImage(fixture.data, filename: fixture.name, filter: .normal)
            #expect(normal == before, "\(fixture.name): Normal took a different path")
        }

        let small = fixtures[0].data
        let passed = try UploadPreparation.prepareImage(small, filename: "snap.jpg", filter: .normal)
        #expect(!passed.wasTranscoded)
        #expect(passed.data == small, "Normal must not re-encode a photo that already fits")
    }

    // MARK: - What a filter does to the pixels

    /// `grayscale(1)` on pure red: equal channels, at red's luminance weight.
    @Test func blackAndWhiteTurnsRedIntoAGreyOfRedsLuminance() throws {
        let red = FilterTestImages.solid(red: 1, green: 0, blue: 0)
        let prepared = try UploadPreparation.prepareImage(red, filename: "red.png", filter: .bw)
        let colour = try #require(FilterTestImages.centre(of: prepared.data))

        #expect(abs(colour[0] - colour[1]) <= 3 && abs(colour[1] - colour[2]) <= 3,
                "B&W left colour in it: \(colour)")
        // 0.2126 × 255 ≈ 54 in sRGB-encoded values, where the browser applies
        // CSS filters. In linear light the same weight would come out near 127.
        #expect((46...62).contains(colour[0]), """
            B&W made red \(colour[0]); CSS grayscale(1) makes it about 54. \
            Far above that means the matrix ran in linear light, not sRGB.
            """)
    }

    /// `brightness(1.3)` multiplies, in sRGB: a mid-grey comes out 1.3 times
    /// as bright, not 0.3 brighter and not 1.3 times as much light.
    @Test func brightMakesAMidGreyAboutThirtyPercentBrighter() throws {
        let grey = FilterTestImages.solid(red: 0.5, green: 0.5, blue: 0.5)
        let input = try #require(FilterTestImages.centre(of: grey))
        let prepared = try UploadPreparation.prepareImage(grey, filename: "grey.png", filter: .bright)
        let output = try #require(FilterTestImages.centre(of: prepared.data))

        let ratio = Double(output[0]) / Double(input[0])
        #expect((1.25...1.35).contains(ratio), """
            Bright took \(input[0]) to \(output[0]) (×\(ratio)); CSS brightness(1.3) is ×1.3. \
            About ×1.13 means it multiplied linear light; about ×1.6 means it added.
            """)
        #expect(abs(output[0] - output[1]) <= 3 && abs(output[1] - output[2]) <= 3, "Bright tinted a grey: \(output)")
    }

    /// Every chain renders, and renders something other than the original.
    @Test func everyFilterButNormalChangesThePicture() throws {
        let colour = FilterTestImages.solid(red: 0.8, green: 0.5, blue: 0.3)
        let original = try #require(FilterTestImages.centre(of: colour))
        // A flat colour cannot show Soft's blur, but its brightness and
        // contrast still move this one by about ten levels.
        for filter in PhotoFilter.allCases where filter != .normal {
            let prepared = try UploadPreparation.prepareImage(colour, filename: "c.png", filter: filter)
            let filtered = try #require(FilterTestImages.centre(of: prepared.data), "\(filter.rawValue)")
            let moved = zip(filtered, original).map { abs($0 - $1) }.max() ?? 0
            #expect(moved >= 4, "\(filter.rawValue) left \(original) at \(filtered)")
        }
    }

    // MARK: - Format and caps

    /// A filtered photo is a JPEG within the same caps as any re-encode, from
    /// any source format — and never the picked bytes, even when those would
    /// have passed through.
    @Test func aFilteredPhotoIsAJpegWithinTheSameCaps() throws {
        var fixtures: [(name: String, data: Data)] = [
            ("big.jpg", UploadTestImages.jpeg(width: 4032, height: 3024)),
            ("snap.jpg", UploadTestImages.jpeg(width: 400, height: 400, quality: 0.6)),
        ]
        if let heic = UploadTestImages.encoded(UploadTestImages.noisy(width: 800, height: 600), as: .heic) {
            fixtures.append((name: "IMG_0001.HEIC", data: heic))
        }
        let caps = UploadPreparation.Options.default
        for fixture in fixtures {
            let prepared = try UploadPreparation.prepareImage(fixture.data, filename: fixture.name, filter: .vintage)
            let unfiltered = try UploadPreparation.prepareImage(fixture.data, filename: fixture.name)

            #expect(prepared.wasTranscoded, "\(fixture.name)")
            #expect(prepared.mimeType == "image/jpeg", "\(fixture.name)")
            #expect(UploadPreparation.imageType(of: prepared.data) == UTType.jpeg.identifier, "\(fixture.name)")
            #expect(prepared.filename.hasSuffix(".jpg"), "\(fixture.name) → \(prepared.filename)")
            #expect(prepared.data.count <= caps.targetBytes, "\(fixture.name): \(prepared.data.count) bytes")
            #expect(prepared.data != fixture.data, "\(fixture.name) went up as picked")
            #expect(prepared.aspectRatio == unfiltered.aspectRatio, "\(fixture.name): the shape changed")
            let size = try #require(UploadPreparation.pixelSize(of: prepared.data))
            #expect(max(size.width, size.height) <= caps.maxPixelSize, "\(fixture.name): \(size)")
        }
    }

    /// The filter runs on the upright picture, so a portrait photo stays
    /// portrait.
    @Test func aRotatedPhotoIsFilteredTheWayItIsSeen() throws {
        let rotated = try #require(
            UploadTestImages.encoded(UploadTestImages.noisy(width: 1200, height: 800), as: .jpeg, orientation: 6)
        )
        let prepared = try UploadPreparation.prepareImage(rotated, filename: "IMG.jpg", filter: .warm)
        let size = try #require(UploadPreparation.pixelSize(of: prepared.data))
        #expect(size.width < size.height, "the filtered photo came out on its side: \(size)")
    }

    // MARK: - Soft's blur is the web client's uploaded blur

    /// The web client blurs the original by 0.5px and then shrinks it to
    /// 1920 (src/pages/Create.tsx:627-628, :860), so the file it uploads
    /// carries 0.5 × 1920 ÷ the original's long side — and the whole 0.5 for
    /// a photo it does not shrink.
    @Test func softsBlurIsHalfAPixelOfTheOriginal() {
        // A 12-megapixel phone photo: about a quarter of a pixel in the upload.
        let phone = PhotoFilter.pixelsPerCSSPixel(decodedLongSide: 1920, originalLongSide: 4032)
        #expect(abs(0.5 * phone - 0.238) < 0.001, "Soft's blur in a 4032px photo's upload is \(0.5 * phone)px")
        // Already 1920 or smaller: not enlarged on either client.
        #expect(PhotoFilter.pixelsPerCSSPixel(decodedLongSide: 1200, originalLongSide: 1200) == 1)
        // Sizes that could not be read leave the blur at its CSS value.
        #expect(PhotoFilter.pixelsPerCSSPixel(decodedLongSide: 1920, originalLongSide: 0) == 1)
    }

    /// And the upload render uses it. A hard edge in a 1920-wide picture
    /// decoded from a 4032-pixel original comes out with the web client's
    /// quarter-pixel blur: the second pixel out from the edge, on either
    /// side, has not moved. The rule this replaced — half a pixel per 400 of
    /// the short side — made that 1.35 pixels here and moved those two by
    /// about thirty levels.
    ///
    /// Then the same picture said to be decoded *larger* than its original,
    /// which the app never does, turns the blur up to 2 pixels — so the first
    /// half is the scale at work, not a blur that was never applied.
    @Test func theUploadRenderBlursByTheOriginalsScale() throws {
        let edge = FilterTestImages.hardEdge(width: 1920, height: 1080)
        let upload = try #require(
            PhotoFilterRenderer.shared.render(.soft, edge, originalLongSide: 4032, for: .upload)
        )
        let row = try #require(FilterTestImages.middleRow(of: upload))
        // Soft's brightness and contrast take black to about 13 and white to
        // about 242 before the blur; columns 900 and 1000 are far from it.
        #expect(abs(row[958] - row[900]) <= 3 && abs(row[961] - row[1000]) <= 3, """
            The second pixel out from the edge moved: \(row[956...963]) against \(row[900]) and \(row[1000]). \
            The blur is wider than the web client's upload carries.
            """)

        let enlarged = try #require(
            PhotoFilterRenderer.shared.render(.soft, edge, originalLongSide: 480, for: .upload)
        )
        let wide = try #require(FilterTestImages.middleRow(of: enlarged))
        #expect(wide[958] - wide[900] >= 15, "no blur where it should be two pixels wide: \(wide[956...963])")
    }

    /// The web client skips its filter for GIFs; so do the bytes here.
    @Test func aGifIsNeverFiltered() throws {
        let gif = UploadTestImages.gif()
        let prepared = try UploadPreparation.prepareImage(gif, filename: "cat.gif", filter: .bw)

        #expect(!prepared.wasTranscoded)
        #expect(prepared.data == gif)
    }
}

/// The composer's side: which photo a filter belongs to, what goes up, and
/// what a change after uploading costs.
@MainActor
struct PhotoFilterComposeTests {
    typealias Harness = ComposePublishTests.Harness

    static func photo(_ index: Int) -> ComposeViewModel.PickedItem { ComposePublishTests.photo(index) }

    /// Every sampled pixel has R = G = B, within JPEG's rounding.
    static func isGrey(_ data: Data) -> Bool {
        guard let image = FilterTestImages.pixels(of: data) else { return false }
        return stride(from: 0, to: image.width * image.height, by: 37).allSatisfy { pixel in
            let r = Int(image.bytes[pixel * 4]), g = Int(image.bytes[pixel * 4 + 1]), b = Int(image.bytes[pixel * 4 + 2])
            return abs(r - g) <= 3 && abs(g - b) <= 3
        }
    }

    @Test func thePickedPhotoIsSelectedAndStartsAtNormal() {
        let harness = Harness(photos: 2)

        #expect(harness.model.selectedItemID == "item-1")
        #expect(harness.model.filter(for: "item-1") == .normal)
        #expect(harness.model.filter(for: "item-2") == .normal)
    }

    /// A choice made before Share is in the uploaded bytes, and only in the
    /// photo it was made for.
    @Test func aFilterChosenBeforeSharingIsWhatIsUploaded() async {
        let harness = Harness(photos: 2)
        harness.model.setFilter(.bw, for: "item-1")
        #expect(harness.model.filter(for: "item-1") == .bw)

        await harness.model.share()

        let sent = harness.uploader.sentItems
        #expect(harness.model.hasPublished)
        #expect(sent.count == 2)
        #expect(sent.first?.mimeType == "image/jpeg")
        #expect(sent.first?.data != Self.photo(1).data, "the filtered photo went up as picked")
        #expect(sent.first.map { Self.isGrey($0.data) } == true, "B&W was chosen and the upload has colour in it")
        #expect(sent.last?.data == Self.photo(2).data, "the Normal photo must go up exactly as before")
    }

    /// The case the retry design is for: a photo already on the CDN has its
    /// filter changed. Its bytes are stale, so the attempt is released — kept
    /// on the CDN, dropped from this attempt — and the next Share sends it
    /// again under a fresh operation id.
    @Test func changingTheFilterOfAnUploadedPhotoSendsItAgain() async {
        let harness = Harness(photos: 2)
        harness.writes.loseAnswer(onAttempts: [1])
        await harness.model.share()
        #expect(harness.model.phase == .failed(stage: .publish))
        #expect(harness.model.uploadedAssets.count == 2)
        let firstOperationID = harness.writes.publishAttempts.first?.operationID

        harness.model.setFilter(.warm, for: "item-1")

        #expect(harness.model.uploadedAssets.isEmpty, "the upload of item-1 carries the old filter and must not be published")
        #expect(harness.model.operationID == nil, """
            Reusing the id would hand back the post the first attempt may have \
            made, with the unfiltered photo in it.
            """)

        await harness.model.share()

        #expect(harness.uploader.sendCount == 4, "both photos are sent again, after the two first sends")
        let sent = harness.uploader.sentItems
        #expect(sent.count == 4 && sent[2].data != sent[0].data, "item-1 was re-sent without its new filter")
        #expect(sent.count == 4 && sent[3].data == sent[1].data, "item-2 is unchanged, so its bytes are too")
        #expect(harness.writes.publishAttempts.count == 2)
        #expect(harness.writes.publishAttempts.last?.operationID != firstOperationID)
        #expect(harness.model.hasPublished)
    }

    /// Choosing what is already chosen is not a change and releases nothing.
    @Test func choosingTheSameFilterAgainKeepsTheAttempt() async {
        let harness = Harness(photos: 2)
        harness.writes.loseAnswer(onAttempts: [1])
        await harness.model.share()
        let operationID = harness.model.operationID

        harness.model.setFilter(.normal, for: "item-1")

        #expect(harness.model.uploadedAssets.count == 2)
        #expect(harness.model.operationID == operationID)
    }

    /// A photo that has not been uploaded yet: nothing recorded is stale, so
    /// the photo before it is not sent twice, and it goes up with the new
    /// choice when its turn comes.
    @Test func changingTheFilterOfAPhotoNotYetUploadedKeepsWhatLanded() async {
        let harness = Harness(photos: 3)
        harness.uploader.fail(atSend: [2])
        await harness.model.share()
        #expect(harness.model.phase == .failed(stage: .upload))
        #expect(harness.model.uploadedAssets.count == 1)
        let operationID = harness.model.operationID

        harness.model.setFilter(.bw, for: "item-3")

        #expect(harness.model.uploadedAssets.count == 1, "item-1 is on the CDN unfiltered, as it should be")
        #expect(harness.model.operationID == operationID)

        harness.uploader.fail(atSend: [])
        await harness.model.share()

        #expect(harness.uploader.sendCount == 4, "one success, one failure, then the two outstanding")
        let sent = harness.uploader.sentItems
        #expect(sent.count == 4 && sent[2].data == Self.photo(2).data)
        #expect(sent.count == 4 && Self.isGrey(sent[3].data), "item-3 went up without the filter chosen for it")
        #expect(harness.writes.publishAttempts.last?.operationID == operationID)
    }

    /// Videos are uploaded as picked, whatever is asked for.
    @Test func aVideoIsNeverFiltered() async {
        let harness = Harness(photos: 0)
        let clip = ComposeViewModel.PickedItem(
            id: "v1", sourceID: "v1", kind: .video, data: Data(repeating: 7, count: 2048),
            filename: "clip.mov", mimeType: "video/quicktime", duration: 5
        )
        #expect(!clip.isFilterable)
        harness.model.add([clip])

        harness.model.setFilter(.bw, for: "v1")
        #expect(harness.model.filter(for: "v1") == .normal)

        await harness.model.share()

        #expect(harness.uploader.sentItems.first?.data == clip.data)
        #expect(harness.uploader.sentItems.first?.resourceType == .video)
    }

    /// Nor is a GIF offered one.
    @Test func aGifIsNotOfferedAFilter() {
        let harness = Harness(photos: 0)
        let gif = ComposeViewModel.PickedItem(
            id: "g1", sourceID: "g1", kind: .image, data: UploadTestImages.gif(),
            filename: "cat.gif", mimeType: "image/gif", duration: nil
        )
        #expect(!gif.isFilterable)
        harness.model.add([gif])

        harness.model.setFilter(.vivid, for: "g1")

        #expect(harness.model.filter(for: "g1") == .normal)
    }

    /// Removing a photo forgets its filter and moves the selection to the one
    /// before it, or the new first — the web client's rule.
    @Test func removingAPhotoForgetsItsFilterAndMovesTheSelection() {
        let harness = Harness(photos: 3)
        harness.model.select(id: "item-2")
        harness.model.setFilter(.rose, for: "item-2")

        harness.model.remove(id: "item-2")

        #expect(harness.model.filter(for: "item-2") == .normal)
        #expect(harness.model.selectedItemID == "item-1")

        harness.model.remove(id: "item-1")
        #expect(harness.model.selectedItemID == "item-3")
    }

    /// The previews are rendered once and kept.
    @Test func aPreviewIsRenderedOnceAndKept() async throws {
        let previews = ComposeFilterPreviews()
        let item = Self.photo(1)

        let first = await previews.preview(of: item, filter: .bw, maxPixelSize: 128)
        let again = await previews.preview(of: item, filter: .bw, maxPixelSize: 128)
        let normal = await previews.preview(of: item, filter: .normal, maxPixelSize: 128)

        let bw = try #require(first)
        #expect(again === bw, "the second ask rendered again instead of using the kept one")
        let plain = try #require(normal)
        #expect(plain !== bw)
    }
}
