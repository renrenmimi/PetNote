import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// The composer's ten photo filters — the web client's, by key, label and
/// effect (src/components/ImageFilter.tsx).
///
/// **Parity is the whole specification.** Both clients' photos land in the same
/// feed, so "Warm" has to mean the same picture from a phone and from a laptop.
/// The web client defines each filter as a CSS `filter` string; `steps` is that
/// string, function by function and in the same order, and `css` writes it
/// back out so a test can hold the two tables side by side.
///
/// **Each CSS function is reproduced by its own definition, not by the Core
/// Image filter with the nearest name.** The Filter Effects spec defines every
/// function used here as a colour matrix (or, for `blur`, a Gaussian), and
/// `CIColorMatrix` evaluates a colour matrix exactly. The named Core Image
/// filters are different operations that happen to share a word:
///
///   - `CIColorControls.brightness` *adds* to each channel; CSS `brightness()`
///     multiplies.
///   - `CIColorControls.contrast` does not document its pivot; CSS
///     `contrast()` is `(v - 0.5) × x + 0.5`, which is a scale of `x` and a
///     bias of `0.5 × (1 - x)`.
///   - `CISepiaTone` is its own tone map, not the spec's sepia matrix, and
///     `CIHueAdjust` does not document the luminance weights CSS
///     `hue-rotate()` keeps constant.
///   - `CIColorControls.saturation` and `CIPhotoEffectMono` do not document
///     their weights either (Mono also applies a tone curve). CSS `saturate()`
///     and `grayscale()` use Rec. 709 luminance — 0.213/0.715/0.072 and
///     0.2126/0.7152/0.0722 — and the matrix uses exactly those.
///
/// So all six colour functions go through one `CIColorMatrix` each, with the
/// spec's coefficients, and the result is clamped to 0…1 after every step
/// because each CSS function is an SVG filter primitive whose output is
/// clamped. Two chains that differ only in where a value overflowed would
/// otherwise come out differently from the browser's.
///
/// **In sRGB, not in linear light.** Browsers apply CSS filter functions to
/// the sRGB-encoded values, so `brightness(1.3)` makes a 50% grey 65%.
/// Core Image's default working space is linear, where the same multiply
/// would land near 57%. `PhotoFilterRenderer` sets the working space to sRGB
/// for that reason.
enum PhotoFilter: String, CaseIterable, Identifiable, Sendable {
    case normal
    case warm
    case cool
    case bright
    case contrast
    case vintage
    case bw
    case vivid
    case soft
    case rose

    var id: String { rawValue }

    /// What the strip calls it. The English is the web client's label.
    var label: String {
        switch self {
        case .normal: String(localized: "photoFilter.normal", defaultValue: "Normal", comment: "Photo filter: the photo as it was taken")
        case .warm: String(localized: "photoFilter.warm", defaultValue: "Warm", comment: "Photo filter name")
        case .cool: String(localized: "photoFilter.cool", defaultValue: "Cool", comment: "Photo filter name")
        case .bright: String(localized: "photoFilter.bright", defaultValue: "Bright", comment: "Photo filter name")
        case .contrast: String(localized: "photoFilter.contrast", defaultValue: "Contrast", comment: "Photo filter name: stronger contrast")
        case .vintage: String(localized: "photoFilter.vintage", defaultValue: "Vintage", comment: "Photo filter name")
        case .bw: String(localized: "photoFilter.bw", defaultValue: "B&W", comment: "Photo filter name: black and white")
        case .vivid: String(localized: "photoFilter.vivid", defaultValue: "Vivid", comment: "Photo filter name")
        case .soft: String(localized: "photoFilter.soft", defaultValue: "Soft", comment: "Photo filter name")
        case .rose: String(localized: "photoFilter.rose", defaultValue: "Rose", comment: "Photo filter name: a pink tint")
        }
    }

    /// The web client's CSS filter chain, one function per step, in order.
    var steps: [Step] {
        switch self {
        case .normal: []
        case .warm: [.sepia(0.3), .saturate(1.4), .brightness(1.1)]
        case .cool: [.saturate(0.8), .brightness(1.1), .hueRotate(degrees: 15)]
        case .bright: [.brightness(1.3)]
        case .contrast: [.contrast(1.4)]
        case .vintage: [.sepia(0.4), .saturate(0.8), .brightness(0.9)]
        case .bw: [.grayscale(1)]
        case .vivid: [.saturate(1.8), .contrast(1.1)]
        case .soft: [.brightness(1.1), .contrast(0.9), .gaussianBlur(cssPixels: 0.5)]
        case .rose: [.sepia(0.2), .saturate(1.3), .hueRotate(degrees: -10), .brightness(1.05)]
        }
    }

    /// The chain written the way ImageFilter.tsx writes it.
    var css: String {
        steps.isEmpty ? "none" : steps.map(\.css).joined(separator: " ")
    }

    /// How wide, in points, a photo is taken to be shown when the one length
    /// in these chains — `blur(0.5px)` — is turned into image pixels.
    ///
    /// CSS lengths are display lengths: on the web the preview is blurred by
    /// half a CSS pixel *at the size it is drawn*. A stored photo has no
    /// display size of its own, so it borrows the one it is mostly seen at:
    /// about a phone's width, which is how wide the feed draws a photo and how
    /// wide the web composer draws a single-photo preview. The blur is then
    /// the same fraction of the photo in every rendering of it — the strip's
    /// 64pt swatch, the grid tile, and the uploaded file — so each preview is
    /// the upload, smaller. Measured against the photo's shorter side, the one
    /// a square tile or a 4:5 feed card fills.
    ///
    /// Not what the web client's *upload* does: it applies `blur(0.5px)` to
    /// the full-resolution original on a canvas and then downscales, which
    /// leaves almost none of the blur the person saw. Matching the preview
    /// they chose from is the better half of that parity to keep.
    static let referenceDisplayPoints: CGFloat = 400

    /// Image pixels per CSS pixel for an image of this size.
    static func pixelsPerCSSPixel(width: Int, height: Int) -> CGFloat {
        CGFloat(max(1, min(width, height))) / referenceDisplayPoints
    }

    /// Runs the chain over an image, in order.
    func apply(to image: CIImage, pixelsPerCSSPixel: CGFloat) -> CIImage {
        steps.reduce(image) { current, step in
            step.apply(to: current, pixelsPerCSSPixel: pixelsPerCSSPixel)
        }
    }
}

// MARK: - One CSS filter function

extension PhotoFilter {
    enum Step: Sendable, Equatable {
        case sepia(Double)
        case saturate(Double)
        case brightness(Double)
        case contrast(Double)
        case hueRotate(degrees: Double)
        case grayscale(Double)
        case gaussianBlur(cssPixels: Double)

        var css: String {
            switch self {
            case .sepia(let amount): "sepia(\(Self.number(amount)))"
            case .saturate(let amount): "saturate(\(Self.number(amount)))"
            case .brightness(let amount): "brightness(\(Self.number(amount)))"
            case .contrast(let amount): "contrast(\(Self.number(amount)))"
            case .hueRotate(let degrees): "hue-rotate(\(Self.number(degrees))deg)"
            case .grayscale(let amount): "grayscale(\(Self.number(amount)))"
            case .gaussianBlur(let pixels): "blur(\(Self.number(pixels))px)"
            }
        }

        /// `1` rather than `1.0`, as CSS is written.
        static func number(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(value)
        }

        /// The Filter Effects spec's matrix for this function, or nil for
        /// `blur`, which is not a colour operation.
        ///
        /// Coefficients are the spec's, digit for digit: sepia and grayscale
        /// from their `feColorMatrix type="matrix"` equivalents, saturate and
        /// hue-rotate from `type="saturate"` / `type="hueRotate"`, brightness
        /// and contrast from their `feComponentTransfer type="linear"` slopes
        /// and intercepts.
        var colorMatrix: ColorMatrix? {
            switch self {
            case .sepia(let amount):
                let k = 1 - Self.unit(amount)
                return ColorMatrix(
                    red: [0.393 + 0.607 * k, 0.769 - 0.769 * k, 0.189 - 0.189 * k],
                    green: [0.349 - 0.349 * k, 0.686 + 0.314 * k, 0.168 - 0.168 * k],
                    blue: [0.272 - 0.272 * k, 0.534 - 0.534 * k, 0.131 + 0.869 * k]
                )
            case .grayscale(let amount):
                let k = 1 - Self.unit(amount)
                return ColorMatrix(
                    red: [0.2126 + 0.7874 * k, 0.7152 - 0.7152 * k, 0.0722 - 0.0722 * k],
                    green: [0.2126 - 0.2126 * k, 0.7152 + 0.2848 * k, 0.0722 - 0.0722 * k],
                    blue: [0.2126 - 0.2126 * k, 0.7152 - 0.7152 * k, 0.0722 + 0.9278 * k]
                )
            case .saturate(let s):
                return ColorMatrix(
                    red: [0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s],
                    green: [0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s],
                    blue: [0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s]
                )
            case .hueRotate(let degrees):
                let radians = degrees * Double.pi / 180
                let c = cos(radians)
                let s = sin(radians)
                return ColorMatrix(
                    red: [0.213 + 0.787 * c - 0.213 * s, 0.715 - 0.715 * c - 0.715 * s, 0.072 - 0.072 * c + 0.928 * s],
                    green: [0.213 - 0.213 * c + 0.143 * s, 0.715 + 0.285 * c + 0.140 * s, 0.072 - 0.072 * c - 0.283 * s],
                    blue: [0.213 - 0.213 * c - 0.787 * s, 0.715 - 0.715 * c + 0.715 * s, 0.072 + 0.928 * c + 0.072 * s]
                )
            case .brightness(let x):
                return ColorMatrix(red: [x, 0, 0], green: [0, x, 0], blue: [0, 0, x])
            case .contrast(let x):
                let intercept = 0.5 - 0.5 * x
                return ColorMatrix(
                    red: [x, 0, 0], green: [0, x, 0], blue: [0, 0, x],
                    bias: [intercept, intercept, intercept]
                )
            case .gaussianBlur:
                return nil
            }
        }

        func apply(to image: CIImage, pixelsPerCSSPixel: CGFloat) -> CIImage {
            if let matrix = colorMatrix {
                return matrix.apply(to: image)
            }
            guard case .gaussianBlur(let cssPixels) = self else { return image }
            // CSS `blur()` takes the Gaussian's standard deviation, which is
            // what `applyingGaussianBlur(sigma:)` takes too.
            let sigma = cssPixels * Double(pixelsPerCSSPixel)
            guard sigma > 0 else { return image }
            // Clamped first so the edges blur against themselves rather than
            // against transparent black — without it every filtered photo gets
            // a dark rim — and cropped back so the blur does not grow the
            // picture by its own radius.
            return image.clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: image.extent)
        }

        private static func unit(_ value: Double) -> Double { min(max(value, 0), 1) }
    }

    /// A 3×3 colour matrix plus a bias: `out = rows · (r, g, b) + bias`.
    /// Alpha passes through.
    struct ColorMatrix: Sendable, Equatable {
        var red: [Double]
        var green: [Double]
        var blue: [Double]
        var bias: [Double] = [0, 0, 0]

        /// The same arithmetic on one colour, for tests and nothing else.
        func applied(to rgb: [Double]) -> [Double] {
            let clamp = { (value: Double) in min(max(value, 0), 1) }
            return [
                clamp(red[0] * rgb[0] + red[1] * rgb[1] + red[2] * rgb[2] + bias[0]),
                clamp(green[0] * rgb[0] + green[1] * rgb[1] + green[2] * rgb[2] + bias[1]),
                clamp(blue[0] * rgb[0] + blue[1] * rgb[1] + blue[2] * rgb[2] + bias[2]),
            ]
        }

        func apply(to image: CIImage) -> CIImage {
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            matrix.rVector = CIVector(x: CGFloat(red[0]), y: CGFloat(red[1]), z: CGFloat(red[2]), w: 0)
            matrix.gVector = CIVector(x: CGFloat(green[0]), y: CGFloat(green[1]), z: CGFloat(green[2]), w: 0)
            matrix.bVector = CIVector(x: CGFloat(blue[0]), y: CGFloat(blue[1]), z: CGFloat(blue[2]), w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: CGFloat(bias[0]), y: CGFloat(bias[1]), z: CGFloat(bias[2]), w: 0)
            guard let transformed = matrix.outputImage else { return image }

            // Each CSS function's output is clamped before the next one reads
            // it. Core Image's intermediates are half-float and would carry a
            // 1.2 from `saturate(1.4)` straight into `brightness(1.1)`.
            let clamp = CIFilter.colorClamp()
            clamp.inputImage = transformed
            clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
            clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
            return clamp.outputImage ?? transformed
        }
    }
}

// MARK: - Rendering

/// Renders a filter chain over a decoded picture. One shared instance, one
/// `CIContext`.
///
/// A context is expensive to make — it owns a Metal device queue and a cache
/// of compiled kernels — and cheap to reuse, so every preview and every upload
/// goes through this one.
///
/// `@unchecked Sendable` because `CIContext` is documented as thread-safe and
/// is not marked `Sendable`. That claim is the unchecked part and nothing
/// else: both stored properties are `let`, and every `CIFilter` is made fresh
/// per render, never shared.
final class PhotoFilterRenderer: @unchecked Sendable {
    static let shared = PhotoFilterRenderer()

    private let context: CIContext
    private let colorSpace: CGColorSpace

    init() {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        colorSpace = sRGB
        // sRGB-encoded working space, so the chain sees the same numbers the
        // browser's CSS filters see. See `PhotoFilter`.
        context = CIContext(options: [.workingColorSpace: sRGB])
    }

    /// The filtered picture, the same size as the input, in sRGB — the space
    /// a browser canvas writes. A wide-gamut original therefore loses its
    /// extra gamut when, and only when, a filter is chosen. Nil when Core
    /// Image could not render.
    func render(_ filter: PhotoFilter, _ image: CGImage) -> CGImage? {
        guard filter != .normal else { return image }
        let input = CIImage(cgImage: image)
        let output = filter.apply(
            to: input,
            pixelsPerCSSPixel: PhotoFilter.pixelsPerCSSPixel(width: image.width, height: image.height)
        )
        return context.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: colorSpace)
    }
}
