import Foundation
import Testing

/// Acceptance 3.3: the guard has to be able to catch a *new* hardcoded colour or
/// font size, not just describe a rule nobody enforces. It reads the actual
/// source tree, located from this file's own path.
struct DesignSystemGuardTests {
    /// ios-native/, derived from this file at ios-native/PetNoteAppTests/…
    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PetNoteAppTests
            .deletingLastPathComponent()   // ios-native
    }

    /// Only these may name a raw colour or size.
    private static let exemptFiles: Set<String> = [
        "Palette.swift",     // defines the tokens
        "Typography.swift",  // defines the type scale
        "Spacing.swift",     // defines the grid
    ]

    private static func swiftSources() throws -> [(path: String, name: String, text: String)] {
        let fm = FileManager.default
        var out: [(String, String, String)] = []
        for dir in ["App", "Core", "Features", "DesignSystem", "Support"] {
            let base = projectRoot.appendingPathComponent(dir)
            guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let name = url.lastPathComponent
                guard !exemptFiles.contains(name) else { continue }
                out.append((url.path, name, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return out
    }

    /// Lines that are pure comment are skipped: a hex in prose explaining *why*
    /// a token has a value is documentation, not a hardcoded colour.
    private static func offendingLines(in text: String, matching patterns: [String]) -> [String] {
        var hits: [String] = []
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.hasPrefix("///") || line.hasPrefix("*") { continue }
            for pattern in patterns where line.range(of: pattern, options: .regularExpression) != nil {
                hits.append("line \(index + 1): \(line)")
            }
        }
        return hits
    }

    @Test func noHardcodedColoursOutsideThePalette() throws {
        let patterns = [
            #"#[0-9A-Fa-f]{6}"#,                      // "#AABBCC"
            #"Color\(\s*(red|\.sRGB)"#,               // Color(red:…) / Color(.sRGB…)
            #"UIColor\(\s*red:"#,
            #"Color\.(red|blue|green|purple|pink|orange|yellow|gray|grey)\b"#,
        ]
        var failures: [String] = []
        for file in try Self.swiftSources() {
            for hit in Self.offendingLines(in: file.text, matching: patterns) {
                failures.append("\(file.name) \(hit)")
            }
        }
        #expect(failures.isEmpty, "Colours must come from Palette:\n\(failures.joined(separator: "\n"))")
    }

    @Test func noFixedFontSizes() throws {
        // .system(size:) opts the whole label out of Dynamic Type.
        let patterns = [#"\.system\(size:"#, #"UIFont\.systemFont\(ofSize:"#]
        var failures: [String] = []
        for file in try Self.swiftSources() {
            for hit in Self.offendingLines(in: file.text, matching: patterns) {
                failures.append("\(file.name) \(hit)")
            }
        }
        #expect(failures.isEmpty, "Font sizes must come from Font.TextStyle:\n\(failures.joined(separator: "\n"))")
    }

    /// The guard is only worth having if it fails on a violation, so here is
    /// one, checked through the same code path the real scan uses.
    @Test func theGuardCatchesAViolation() {
        let offending = """
        struct Bad: View {
            var body: some View {
                Text("x")
                    .foregroundStyle(Color(red: 0.6, green: 0.1, blue: 0.9))
                    .font(.system(size: 17))
            }
        }
        """
        let colourHits = Self.offendingLines(in: offending, matching: [#"Color\(\s*(red|\.sRGB)"#])
        let fontHits = Self.offendingLines(in: offending, matching: [#"\.system\(size:"#])
        #expect(colourHits.count == 1)
        #expect(fontHits.count == 1)
    }

    @Test func aHexInACommentIsNotAViolation() {
        let documented = """
        // purple-600 is #9810FA, which is 5.53:1 on white.
        let token = Palette.brandPrimary
        """
        #expect(Self.offendingLines(in: documented, matching: [#"#[0-9A-Fa-f]{6}"#]).isEmpty)
    }
}
