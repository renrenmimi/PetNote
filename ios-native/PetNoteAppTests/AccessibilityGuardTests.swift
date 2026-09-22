import Foundation
import Testing

/// Two accessibility settings whose correctness is a property of the source
/// rather than of a rendered frame, checked by reading the source.
///
/// This is not a substitute for turning the settings on and looking — that is
/// in AccessibilityUITests (simulator) and, for the visual half, still needs a
/// device. It is here because a scan answers a question a screenshot cannot:
/// *is there anything of this kind anywhere*, including on screens no test
/// happens to visit.
struct AccessibilityGuardTests {
    /// ios-native/, derived from this file at ios-native/PetNoteAppTests/…
    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func appSources() throws -> [(name: String, text: String)] {
        let fm = FileManager.default
        var out: [(String, String)] = []
        for dir in ["App", "Core", "Features", "DesignSystem", "Support"] {
            let base = projectRoot.appendingPathComponent(dir)
            guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return out
    }

    private static func hits(_ pattern: String, in sources: [(name: String, text: String)]) -> [String] {
        var found: [String] = []
        for file in sources {
            for (index, rawLine) in file.text.components(separatedBy: .newlines).enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                // Prose about a rule is not a use of it.
                if line.hasPrefix("//") || line.hasPrefix("///") { continue }
                if line.range(of: pattern, options: .regularExpression) != nil {
                    found.append("\(file.name) line \(index + 1): \(line)")
                }
            }
        }
        return found
    }

    /// §6.5 asks that frosted glass become solid when "Reduce Transparency" is
    /// on.
    ///
    /// This used to assert that no translucent surface existed anywhere. That
    /// was a real answer while it was true, and it stopped being true the
    /// moment a control had to sit on top of a photograph: there is no known
    /// background behind it to compute a ratio against, so it needs something.
    ///
    /// The rule is therefore stricter now, not looser. A material is allowed,
    /// but only in the single file that also performs the substitution — so
    /// the failure this catches has changed from "translucency appeared" to
    /// "translucency appeared somewhere that does not honour the setting",
    /// which is the thing §6.5 is actually about.
    @Test func translucencyOnlyExistsWhereTheSettingIsHonoured() throws {
        let sources = try Self.appSources()
        let translucent = #"(\.(ultraThin|thin|regular|thick|ultraThick|bar)Material\b|Material\.|\.blur\(|VisualEffect|UIBlurEffect)"#
        let offenders = Self.hits(translucent, in: sources)
            .filter { !$0.hasPrefix("ControlScrim.swift") }

        #expect(
            offenders.isEmpty,
            """
            A translucent surface appeared outside ControlScrim.swift, which is \
            the one place that reads accessibilityReduceTransparency and \
            substitutes a solid Palette colour. Route it through \
            `.controlScrim()`, or give this file the same treatment and widen \
            the allowance deliberately:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// And the allowance above is only safe while the file it names actually
    /// does the substitution. Without this, deleting the branch inside
    /// ControlScrim would leave the guard green and the setting ignored —
    /// the exact failure the allowance was supposed to make impossible.
    @Test func theAllowedFileReallyHonoursTheSetting() throws {
        let scrim = try Self.appSources().first { $0.name == "ControlScrim.swift" }
        let text = try #require(scrim?.text, "ControlScrim.swift is gone; the allowance above now permits unguarded translucency")

        #expect(text.contains("accessibilityReduceTransparency"),
                "ControlScrim no longer reads the setting it exists to honour")
        #expect(text.contains("Palette.opaqueScrim"),
                "ControlScrim no longer substitutes a solid colour")
    }

    /// The scan, checked against a sample, so "no hits" means "nothing matched
    /// a working pattern" rather than "the pattern never matches anything".
    @Test func theTranslucencyScanCatchesAViolation() {
        let sample = [(name: "Sample.swift", text: "Text(\"x\").background(.ultraThinMaterial)")]
        let found = Self.hits(
            #"(\.(ultraThin|thin|regular|thick|ultraThick|bar)Material\b|Material\.|\.blur\(|VisualEffect|UIBlurEffect)"#,
            in: sample
        )
        #expect(found.count == 1)
    }

    /// §6.2 is about the largest accessibility sizes working, and the quietest
    /// way to fail it is to clamp text below them — the interface then looks
    /// intact in a screenshot while ignoring the setting.
    ///
    /// `clampedDynamicType` exists for controls that genuinely cannot grow. It
    /// is currently used nowhere, and this records that: if it starts being
    /// used, the use has to be a deliberate, visible decision rather than a
    /// convenient way to make a layout stop complaining.
    @Test func noTextIsClampedBelowTheAccessibilitySizes() throws {
        let sources = try Self.appSources()
        let found = Self.hits(#"(clampedDynamicType|\.dynamicTypeSize\()"#, in: sources)
            .filter { !$0.hasPrefix("Typography.swift") }   // where it is defined
        #expect(
            found.isEmpty,
            """
            Dynamic Type is being clamped. If that is right for this control, \
            say why here and allow it by name — a blanket clamp is how support \
            for the largest sizes stops being true without anything failing:
            \(found.joined(separator: "\n"))
            """
        )
    }

    // MARK: - A touch target sized from outside the button

    /// `Button("Title") { … }.frame(minHeight: 44)` looks like a 44pt control
    /// and is not one. The frame is outside the button: it makes the row
    /// taller, and leaves the button — what a finger and VoiceOver get — at
    /// its text's height. `AccessibilityUITests` measured it: "Forgot your
    /// password?" was 17pt tall at the smallest type size, and six "Try again"
    /// buttons were written the same way. The height belongs on the label.
    static func buttonsSizedFromOutside(in text: String, named name: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        var found: [String] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"),
                  trimmed.range(of: #"Button\("[^"]*"(, role: [^)]*)?\)"#, options: .regularExpression) != nil
            else { continue }
            // The modifiers attached to that button: the lines that follow and
            // start with a dot, up to the first one that does not.
            for next in lines.dropFirst(index + 1).prefix(6) {
                let modifier = next.trimmingCharacters(in: .whitespaces)
                guard modifier.hasPrefix(".") else { break }
                if modifier.hasPrefix(".frame(minHeight: Layout.minTouchTarget")
                    || modifier.hasPrefix(".frame(minWidth: Layout.minTouchTarget") {
                    found.append("\(name) line \(index + 1): \(trimmed)")
                    break
                }
            }
        }
        return found
    }

    @Test func noButtonIsSizedFromOutsideItsLabel() throws {
        let found = try Self.appSources().flatMap { Self.buttonsSizedFromOutside(in: $0.text, named: $0.name) }
        #expect(
            found.isEmpty,
            """
            These buttons get their 44pt from a frame outside the button, which             sizes the row and not the control. Put the frame and a             .contentShape(.rect) on the label instead:
            \(found.joined(separator: "\n"))
            """
        )
    }

    @Test func theOutsideSizingGuardCatchesTheShapeItIsFor() {
        let violation = """
            Button("Try again") { retry() }
                .font(Typography.body)
                .frame(minHeight: Layout.minTouchTarget)
            """
        let fixed = """
            Button { retry() } label: {
                Text("Try again")
                    .frame(minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
            }
            """
        #expect(Self.buttonsSizedFromOutside(in: violation, named: "v").count == 1)
        #expect(Self.buttonsSizedFromOutside(in: fixed, named: "f").isEmpty)
    }
}
