import Foundation

/// Cloudinary URL handling, kept identical to the web client's
/// (src/utils/cloudinaryUrl.ts) so the two clients ask the CDN for the same
/// renditions. Diverging would split the cache and pay for every image twice.
enum CloudinaryURL {
    /// The size ladder the web client uses. Same strings, deliberately.
    enum Size: String {
        case thumbnail = "w_300,h_300,c_fill,q_auto,f_auto"
        case small = "w_400,q_auto,f_auto"
        case medium = "w_800,q_auto,f_auto"
        case large = "w_1200,q_auto,f_auto"
        case avatar = "w_100,h_100,c_fill,q_auto,f_auto"
        /// The feed's "Popular Pets" tiles — `PetSpotlight.tsx` asks for this
        /// one, so asking for anything else here would split the cache.
        case spotlight = "w_200,h_200,c_fill,q_auto,f_auto"
    }

    private static let host = "res.cloudinary.com"

    /// Inserts a size transform, but only into a URL that does not already
    /// carry one — the same rule as `optimizeCloudinaryUrl`.
    static func optimized(_ url: URL, size: Size) -> URL {
        guard url.absoluteString.contains(host) else { return url }
        guard !url.absoluteString.contains("/video/upload/") else { return url }
        return inserting(size.rawValue, into: url, marker: "/image/upload/")
    }

    /// Cloudinary's frame-0 poster for a video, which is what the web client's
    /// carousel shows before playback.
    static func videoPoster(_ url: URL, size: Size = .medium) -> URL? {
        let string = url.absoluteString
        guard string.contains(host), let range = string.range(of: "/video/upload/") else { return nil }

        let prefix = String(string[string.startIndex..<range.upperBound])
        let suffix = String(string[range.upperBound...])
        guard !suffix.isEmpty else { return nil }

        let first = suffix.split(separator: "/").first.map(String.init) ?? ""
        let transformed = hasTransformation(first) ? suffix : "\(size.rawValue)/\(suffix)"
        // so_0 is "the frame at second zero".
        let poster = "\(prefix)so_0,\(transformed)"
        let asJPEG = poster.replacingOccurrences(
            of: #"\.[^/.]+(\?.*)?$"#,
            with: ".jpg",
            options: .regularExpression
        )
        return URL(string: asJPEG)
    }

    /// The aspect ratio the URL asks for, when it says.
    ///
    /// This matters more than it looks: `MediaItem` carries no width or height,
    /// so without a hint in the URL the client cannot reserve the right height
    /// before the bytes arrive — and a wrong reservation is exactly the layout
    /// jump §6.4 forbids. A URL with `ar_4:5` tells us; a plain production URL
    /// does not, and those fall back to the default ratio.
    static func aspectRatio(of url: URL) -> CGFloat? {
        guard let match = url.absoluteString.range(
            of: #"ar_(\d+(?:\.\d+)?):(\d+(?:\.\d+)?)"#,
            options: .regularExpression
        ) else { return nil }
        let text = String(url.absoluteString[match]).dropFirst(3)
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0 else { return nil }
        return CGFloat(width / height)
    }

    private static func inserting(_ transform: String, into url: URL, marker: String) -> URL {
        let string = url.absoluteString
        guard let range = string.range(of: marker) else { return url }
        let prefix = String(string[string.startIndex..<range.upperBound])
        let suffix = String(string[range.upperBound...])
        guard !suffix.isEmpty else { return url }

        let first = suffix.split(separator: "/").first.map(String.init) ?? ""
        // Already transformed, or not a version segment we recognise: leave it.
        if hasTransformation(first) { return url }
        guard first.range(of: #"^v?\d"#, options: .regularExpression) != nil else { return url }

        return URL(string: "\(prefix)\(transform)/\(suffix)") ?? url
    }

    /// A segment is a transformation if it carries a parameter, rather than
    /// being a version (`v123`) or a bare number.
    private static func hasTransformation(_ segment: String) -> Bool {
        guard !segment.isEmpty else { return false }
        if segment.range(of: #"^v\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if segment.range(of: #"^\d+$"#, options: .regularExpression) != nil { return false }
        return segment.contains(",") || segment.contains("_")
    }
}
