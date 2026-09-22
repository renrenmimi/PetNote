import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

/// Gets picked bytes into a shape Cloudinary and the feed both want.
///
/// **HEIC is not a special case here, and that is the point.** The web client
/// carries `heic2any` — a WASM decoder, ~500 KB, shipped to every visitor —
/// because a browser canvas cannot read HEIC. ImageIO *can*: `CGImageSource`
/// decodes HEIC natively, and the JPEG it writes out comes from the same call
/// that does the downscale. So the conversion, the resize and the re-encode are
/// one pass over the pixels instead of three, and there is no extra dependency
/// and no separate "Converting image…" stage for the person to wait through.
///
/// The output contract is deliberately the web client's, because the two
/// clients' photos land in the same feed and are served by the same CDN:
/// longest edge 1920, JPEG quality 0.8 stepping down to 0.3, target 2 MB.
/// Matching those numbers is what keeps a photo posted from a phone and the
/// same photo posted from a laptop from arriving at visibly different quality.
///
/// Downsampling on decode is the same technique `ImageLoader` uses, for the
/// same reason: a 48-megapixel original never exists in memory at full size.
enum UploadPreparation {
    /// Mirrors `compressImage`'s defaults in src/utils/imageCompressor.ts.
    struct Options: Sendable, Equatable {
        var maxPixelSize: CGFloat = 1920
        var quality: CGFloat = 0.8
        var minimumQuality: CGFloat = 0.3
        var targetBytes: Int = 2 * 1024 * 1024
        /// Refused before decoding. The web client's guardrail exists because a
        /// 100 MB image decoded to a canvas can take a mobile browser out; the
        /// reason is weaker on a phone with ImageIO, but the limit is kept so
        /// both clients refuse the same files rather than one of them silently
        /// accepting what the other rejects.
        var maxInputBytes: Int = 50 * 1024 * 1024

        static let `default` = Options()
    }

    struct Prepared: Sendable, Equatable {
        let data: Data
        let mimeType: String
        let filename: String
        /// width ÷ height of what is being uploaded, when it could be read.
        ///
        /// Nowhere to send it today: `createPostCallable` takes url/type/thumbUrl
        /// and `MediaItem` has no size, so `MediaView` falls back to 4:5 and
        /// crops. Carried anyway because this is the only moment the true shape
        /// is known — see the note in the delivery report.
        let aspectRatio: CGFloat?
        /// True when the bytes were re-encoded rather than passed through.
        let wasTranscoded: Bool
    }

    enum PreparationError: Error, Sendable, Equatable {
        /// Bigger than `maxInputBytes`, refused without decoding.
        case tooLargeToProcess(bytes: Int, limit: Int)
        /// ImageIO could not read it at all.
        case undecodable
        /// ImageIO read it and could not write the JPEG back out.
        case unencodable
    }

    /// Formats that go up untouched when they are already small enough.
    ///
    /// GIF is on the list for the web client's reason — re-encoding an animated
    /// GIF to JPEG throws the animation away — and PNG/JPEG/WebP because
    /// Cloudinary serves them directly and a needless re-encode only loses
    /// quality.
    static let passthroughTypes: Set<String> = [
        UTType.gif.identifier, UTType.jpeg.identifier,
        UTType.png.identifier, UTType.webP.identifier,
    ]

    /// Types that must always be re-encoded whatever their size.
    ///
    /// HEIC/HEIF are here because the *feed* is the reason, not the upload:
    /// Cloudinary would store a HEIC happily, and `f_auto` would even serve it
    /// as JPEG to browsers — but the stored original is what an
    /// `optimizeCloudinaryUrl`-less path hands to any other client, and the web
    /// client cannot decode it. The web client converts for the same outcome by
    /// a different route.
    static let alwaysTranscodedTypes: Set<String> = [
        UTType.heic.identifier, UTType.heif.identifier,
    ]

    /// What ImageIO thinks these bytes are. Nil when it cannot tell.
    ///
    /// By content, not by file extension. The web client tests
    /// `file.type === "image/heic" || /\.heic$/i.test(file.name)` because a
    /// browser's `File` often reports an empty type for HEIC; here the bytes
    /// are in hand, so guessing from a name would be strictly worse.
    static func imageType(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceGetType(source) as String?
    }

    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0
        else { return nil }
        // EXIF orientations 5-8 mean the stored pixels are rotated a quarter
        // turn from how the picture is meant to be seen. Reporting the stored
        // shape would hand the feed a landscape ratio for a portrait photo.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let isQuarterTurned = (5...8).contains(orientation)
        return isQuarterTurned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// Prepares one picked image.
    ///
    /// - Parameter filename: what the picker called it, used only for the
    ///   multipart part name. The extension is corrected when the bytes are
    ///   re-encoded, so a `.HEIC` name never travels with JPEG bytes.
    static func prepareImage(
        _ data: Data, filename: String, options: Options = .default
    ) throws -> Prepared {
        guard data.count <= options.maxInputBytes else {
            throw PreparationError.tooLargeToProcess(bytes: data.count, limit: options.maxInputBytes)
        }
        guard let type = imageType(of: data) else { throw PreparationError.undecodable }

        let size = pixelSize(of: data)
        let ratio = size.map { $0.width / $0.height }
        let mustTranscode = alwaysTranscodedTypes.contains(type)
        let fitsAsIs = data.count <= options.targetBytes
            && passthroughTypes.contains(type)
            && (size.map { max($0.width, $0.height) <= options.maxPixelSize } ?? false)

        if !mustTranscode && fitsAsIs {
            return Prepared(
                data: data, mimeType: mimeType(for: type), filename: filename,
                aspectRatio: ratio, wasTranscoded: false
            )
        }
        // An animated GIF that is over the size target still goes up as it is:
        // there is no re-encode of it that keeps what it is.
        if type == UTType.gif.identifier {
            return Prepared(
                data: data, mimeType: mimeType(for: type), filename: filename,
                aspectRatio: ratio, wasTranscoded: false
            )
        }

        let jpeg = try encodeJPEG(data, options: options)
        return Prepared(
            data: jpeg,
            mimeType: UTType.jpeg.preferredMIMEType ?? "image/jpeg",
            filename: renamed(filename, to: "jpg"),
            aspectRatio: ratio,
            wasTranscoded: true
        )
    }

    /// Decode-downsample-encode, stepping the quality down until the result
    /// fits — the same ladder as the web client's `while` loop.
    ///
    /// The step matters more than it looks. A single encode at 0.8 leaves a
    /// 12-megapixel photo well over 2 MB, and a single encode at 0.3 makes
    /// every photo look like 2009. Stepping means only the photos that need it
    /// pay for it.
    static func encodeJPEG(_ data: Data, options: Options = .default) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PreparationError.undecodable
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            // Applies the EXIF orientation to the pixels. Without it every
            // photo taken in portrait arrives on its side — the browser canvas
            // path does this implicitly and it has to be asked for here.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, options.maxPixelSize),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        else { throw PreparationError.undecodable }

        var quality = options.quality
        var encoded = try write(image, quality: quality)
        while encoded.count > options.targetBytes && quality > options.minimumQuality {
            quality = max(options.minimumQuality, quality - 0.1)
            encoded = try write(image, quality: quality)
        }
        return encoded
    }

    private static func write(_ image: CGImage, quality: CGFloat) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw PreparationError.unencodable }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw PreparationError.unencodable }
        return output as Data
    }

    static func mimeType(for utType: String) -> String {
        UTType(utType)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func renamed(_ filename: String, to extensionName: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        let stem = base.isEmpty ? "upload" : base
        return "\(stem).\(extensionName)"
    }
}
