import Foundation

/// Every destination the app can be sent to, from a tap or from a link.
///
/// One enum for both on purpose: programmatic navigation and link handling that
/// each build their own destination drift apart, and then a link opens something
/// subtly different from the tap that opens "the same" screen.
enum Route: Hashable, Sendable {
    case feed
    case postDetail(postID: String)
}

/// Turns an incoming link into a `Route`.
///
/// **This is input validation, not convenience** (engineering spec §10.6).
/// Rules, all of them enforced below:
///
///   - only known shapes are accepted; anything else lands on the feed,
///     without an error and without guessing what was meant;
///   - identifiers are length- and character-checked before they are used in a
///     query, and are checked *after* percent-decoding, so `%2F` cannot smuggle
///     a path separator past the check;
///   - nothing about permission is ever derived from a link.
///
/// Universal Links are not enabled in stage 1. This exists now because the
/// validation is the part that must not be written in a hurry later.
enum DeepLink {
    /// Hosts we will answer for. An `https` link to anywhere else is somebody
    /// else's site and is not ours to route.
    static let allowedHosts: Set<String> = ["petnote.app", "www.petnote.app"]
    static let scheme = "petnote"

    static func route(for url: URL) -> Route {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .feed
        }

        switch components.scheme?.lowercased() {
        case scheme:
            // petnote://post/<id> — the id may arrive as host or first path
            // component depending on how the link was written.
            var parts = [components.host].compactMap { $0 }
            parts += components.path.split(separator: "/").map(String.init)
            return route(forPathComponents: parts)
        case "https":
            guard let host = components.host?.lowercased(), allowedHosts.contains(host) else {
                return .feed
            }
            return route(forPathComponents: components.path.split(separator: "/").map(String.init))
        default:
            // http, file, javascript, data, or no scheme at all.
            return .feed
        }
    }

    /// For an in-app path such as `/post/abc123`.
    static func route(forPath path: String) -> Route {
        // A protocol-relative path ("//evil.example") is another origin, and a
        // colon means a scheme snuck in. Both are refused before anything is
        // split up, mirroring the web client's browseExitTarget.
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains(":") else {
            return .feed
        }
        return route(forPathComponents: path.split(separator: "/").map(String.init))
    }

    private static func route(forPathComponents parts: [String]) -> Route {
        let decoded = parts.map { $0.removingPercentEncoding ?? $0 }
        switch decoded.first {
        case "post":
            guard decoded.count == 2, let id = validDocumentID(decoded[1]) else { return .feed }
            return .postDetail(postID: id)
        case "feed", nil, "":
            return .feed
        default:
            return .feed
        }
    }

    /// Firestore's own rules for a document id, checked here so a malformed one
    /// never reaches a query: non-empty, at most 1500 bytes, no path separator,
    /// not "." or "..", and not the reserved `__…__` form.
    static func validDocumentID(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= 1500 else { return nil }
        guard !raw.contains("/") else { return nil }
        guard raw != ".", raw != ".." else { return nil }
        guard !(raw.hasPrefix("__") && raw.hasSuffix("__")) else { return nil }
        // Control characters would not survive a round trip through a URL and
        // have no business in an id.
        guard raw.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return raw
    }
}
