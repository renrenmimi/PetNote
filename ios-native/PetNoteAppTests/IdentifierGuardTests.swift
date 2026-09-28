import Foundation
import Testing

/// Every accessibility identifier a test names must exist in the app.
///
/// Three did not, and the cost was not a typo. `HitRegionBoundaryUITests`
/// looked for `full.close` — the real name is `fullImage.close` — inside the
/// helper whose job was to close a full-screen cover before the next probe.
/// The branch never ran, so every probe after a cover opened was recorded as
/// "missed": the measured hit boundaries were biased, and the control group
/// that was supposed to prove the probe could tell inside from outside could
/// be satisfied by that same misclassification.
///
/// A name that does not exist fails silently in XCUITest. `exists` is simply
/// false, which is indistinguishable from "the control is not on screen right
/// now" — which is exactly what a probe is trying to measure.
struct IdentifierGuardTests {
    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func swiftFiles(in directories: [String]) -> [(name: String, text: String)] {
        let fm = FileManager.default
        var out: [(String, String)] = []
        for dir in directories {
            let base = root.appendingPathComponent(dir)
            guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    out.append((url.lastPathComponent, text))
                }
            }
        }
        return out
    }

    /// Identifiers the app actually sets.
    private static func declared() -> Set<String> {
        var names: Set<String> = []
        let pattern = #"accessibilityIdentifier\(\s*"([^"]+)"\s*\)"#
        for file in swiftFiles(in: ["App", "Core", "Features", "DesignSystem", "Support"]) {
            let range = NSRange(file.text.startIndex..., in: file.text)
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: file.text, range: range) {
                if let r = Range(match.range(at: 1), in: file.text) {
                    names.insert(String(file.text[r]))
                }
            }
        }
        return names
    }

    /// Names in the tests that look like our identifiers.
    ///
    /// Dotted lowercase, which is the convention everywhere in this project.
    /// SF Symbol names and dictionary keys are dotted too, hence the
    /// allow-list rather than a cleverer pattern — a guard nobody can read is
    /// a guard that gets deleted.
    private static let notIdentifiers: Set<String> = [
        "person.crop.circle", "arrow.up.left.and.arrow.down.right",
        "speaker.slash.fill", "speaker.wave.2.fill", "play.circle.fill",
        "com.apple.Accessibility", "dev.local.petnote.native",
    ]

    @Test func everyIdentifierATestNamesExistsInTheApp() {
        let known = Self.declared()
        #expect(known.count > 10, "found almost no identifiers; the scan is looking in the wrong place")

        // Only strings handed to a query, not every dotted literal.
        //
        // A looser pattern buried the four real findings under eleven: probe
        // direction keys ("back.top", "signOut.bottom") and a truncated SF
        // Symbol name ("person.crop") are dotted too. A guard whose output
        // has to be filtered by hand is a guard that gets ignored.
        let pattern = #"(?:buttons|staticTexts|otherElements|textFields|secureTextFields|images|navigationBars)\s*\[\s*"([^"]+)"\s*\]"#
            + #"|matching\(identifier:\s*"([^"]+)"\s*\)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var unknown: [String] = []

        for file in Self.swiftFiles(in: ["PetNoteAppUITests"]) {
            // Prose about a name is not a use of it. A comment explaining
            // that `detail.root` was wrong should not be reported as still
            // using it — the design-system guard learned this already.
            let code = file.text.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let range = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: range) {
                let captured = (1...2).compactMap { Range(match.range(at: $0), in: code) }
                guard let r = captured.first else { continue }
                let name = String(code[r])
                // System strings a test legitimately names: "Not Now" is the
                // save-password sheet's button, "PetNote" and "Post" are
                // navigation bar titles rather than identifiers.
                guard name.contains("."), !name.contains(" ") else { continue }
                guard !known.contains(name), !Self.notIdentifiers.contains(name) else { continue }
                unknown.append("\(file.name): \"\(name)\"")
            }
        }

        #expect(
            unknown.isEmpty,
            """
            A test names an identifier the app never sets. XCUITest reports \
            that as `exists == false`, which is indistinguishable from "the \
            control is off screen" — so the branch silently never runs:
            \(Set(unknown).sorted().joined(separator: "\n"))
            """
        )
    }

    /// The guard has to be able to fail, or it says nothing.
    @Test func theGuardCatchesAnInventedIdentifier() {
        let known = Self.declared()
        #expect(!known.contains("full.close"), "the real name is fullImage.close")
        #expect(known.contains("fullImage.close"), "the app should set fullImage.close")
        #expect(!known.contains("image.full"))
        #expect(!known.contains("detail.root"))
    }
}
