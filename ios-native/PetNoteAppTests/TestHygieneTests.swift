import Foundation
import Testing

/// A guard against the one mistake this UI suite has made five times.
///
/// The shape: collect elements with `allElementsBoundByIndex`, then read
/// `.frame` / `.label` / `.value` off them **afterwards**. That is two
/// traversals of a tree that moves between them, and the second one fails with
/// `Failed to get matching snapshot` — which reads like "the control is gone"
/// and is actually "the query expired". Five separate commits in this project
/// have fixed one instance of it and left the others; the note in
/// `SessionFlow.popToFeed` says as much.
///
/// So this does not fix an instance. It scans the UI test sources for the
/// shape, so the *next* person writing one finds out at once.
///
/// **Three shapes, and why each is two traversals.**
///
///   - `twoPasses` — two or more chained closures off one
///     `allElementsBoundByIndex` where **both** read a UI property.
///     `.filter { $0.exists }.map { $0.label }` walks the tree twice.
///   - `elementsEscape` — the chain hands back `XCUIElement`s and they are
///     bound to a name. Every property read on that name later is a new
///     traversal against a snapshot that has already been taken.
///   - `forInOverElements` — `for element in …allElementsBoundByIndex` and
///     then property reads in the body: one traversal per element, all of them
///     after the list was fixed.
///
/// **What is deliberately not flagged.** A single closure that takes the value
/// out in the same pass — `compactMap { (element, element.frame) }` — is the
/// fix, not the defect, and the scanner must not report it or nobody will
/// apply it. `SessionFlow.popToFeed` is written that way and this scanner
/// finds nothing in `SessionFlow.swift`; that is one half of the positive
/// control below, and it is the half that stops this guard from being noise.
struct TestHygieneTests {
    /// ios-native/, from this file at ios-native/PetNoteAppTests/…
    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var uiTestDirectory: URL {
        projectRoot.appendingPathComponent("PetNoteAppUITests")
    }

    // MARK: - Vocabulary

    enum Shape: String, Sendable {
        case twoPasses
        case elementsEscape
        case forInOverElements
    }

    struct Finding: Sendable, CustomStringConvertible {
        let file: String
        let line: Int
        let shape: Shape
        let snippet: String

        var description: String { "\(file):\(line): \(shape.rawValue) — \(snippet)" }
    }

    private static let needle = "allElementsBoundByIndex"

    /// Operations that walk the collection. The chain is read only as far as
    /// the first token that is not one of these, so a `.first?.0 ?? …` tail
    /// ends it rather than dragging the next statement in.
    private static let collectionOps: Set<String> = [
        "filter", "map", "compactMap", "flatMap", "min", "max", "sorted", "first", "last",
        "contains", "allSatisfy", "forEach", "reduce", "prefix", "suffix", "enumerated",
        "count", "isEmpty", "joined", "dropFirst", "dropLast", "reversed",
    ]

    /// Operations after which the chain no longer holds `XCUIElement`s.
    private static let valueOps: Set<String> = ["map", "compactMap", "flatMap", "reduce", "joined"]

    /// Tails that still hand back elements. The empty string is a bare
    /// `allElementsBoundByIndex` with nothing chained onto it.
    private static let elementTails: Set<String> = [
        "", "filter", "prefix", "suffix", "sorted", "reversed", "dropFirst", "dropLast",
        "min", "max", "first", "last",
    ]

    /// Reads that need a fresh snapshot of the accessibility tree. This is the
    /// list that decides whether a closure is a *traversal* or just
    /// arithmetic: `.min { $0.1 < $1.1 }` over tuples somebody already
    /// extracted touches the tree not at all, and must not be counted.
    private static let uiProperties = [
        ".exists", ".frame", ".label", ".value", ".identifier", ".isHittable",
        ".isEnabled", ".isSelected", ".title", ".elementType", ".placeholderValue",
        ".debugDescription", ".buttons", ".staticTexts", ".images", ".otherElements",
    ]

    // MARK: - The scan

    /// Blanks whole-line `//` comments. Prose that describes the shape — and
    /// there is a lot of it in this suite, because the shape has bitten five
    /// times — must not be reported as the shape.
    static func withoutLineComments(_ source: String) -> String {
        source.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : $0 }
            .joined(separator: "\n")
    }

    static func findings(in source: String, file: String) -> [Finding] {
        let text = Array(withoutLineComments(source))
        let needleChars = Array(needle)
        var results: [Finding] = []

        var i = 0
        while i + needleChars.count <= text.count {
            guard matches(needleChars, in: text, at: i) else {
                i += 1
                continue
            }
            let after = i + needleChars.count
            let chain = chain(in: text, from: after)
            let ops = operations(in: Array(chain))

            let traversals = ops.filter(\.readsUI).count
            let names = ops.map(\.name)
            let yieldsElements = !names.contains(where: { valueOps.contains($0) })
                && elementTails.contains(names.last ?? "")

            let head = head(in: text, before: i)
            let isForIn = head.range(of: #"\bfor\b.*\bin\b"#, options: .regularExpression) != nil
            let isBound = head.range(of: #"\b(let|var|return)\b"#, options: .regularExpression) != nil

            let line = text[0..<i].reduce(into: 1) { $0 += ($1 == "\n" ? 1 : 0) }
            let snippet = chain.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(72)

            if traversals >= 2 {
                results.append(Finding(file: file, line: line, shape: .twoPasses,
                                       snippet: String(snippet)))
            }
            if yieldsElements, isForIn {
                results.append(Finding(file: file, line: line, shape: .forInOverElements,
                                       snippet: String(snippet)))
            } else if yieldsElements, isBound {
                results.append(Finding(file: file, line: line, shape: .elementsEscape,
                                       snippet: String(snippet)))
            }
            i = after
        }
        return results
    }

    private static func matches(_ pattern: [Character], in text: [Character], at index: Int) -> Bool {
        for (offset, character) in pattern.enumerated() where text[index + offset] != character {
            return false
        }
        return true
    }

    /// The chained expression that starts just after the needle.
    ///
    /// It ends at the first unbalanced closer, at a `;`, or at a newline whose
    /// next line does not continue the chain with a `.`. Bounded, because a
    /// runaway chain would swallow the rest of the file and report operations
    /// belonging to a different statement.
    private static func chain(in text: [Character], from start: Int) -> String {
        var index = start
        var depth = 0
        let limit = min(text.count, start + 800)
        while index < limit {
            let character = text[index]
            if character == "(" || character == "[" || character == "{" {
                depth += 1
            } else if character == ")" || character == "]" || character == "}" {
                if depth == 0 { break }
                depth -= 1
            } else if character == ";", depth == 0 {
                break
            } else if character == "\n", depth == 0 {
                var next = index + 1
                while next < text.count, text[next] == " " || text[next] == "\t" { next += 1 }
                if next >= text.count || text[next] != "." { break }
            }
            index += 1
        }
        return String(text[start..<index])
    }

    private static func operations(in chain: [Character]) -> [(name: String, readsUI: Bool)] {
        var ops: [(name: String, readsUI: Bool)] = []
        var index = 0
        while index < chain.count {
            guard chain[index] == "." else {
                if chain[index] == "(" || chain[index] == "[" || chain[index] == "{" {
                    index = endOfBalancedGroup(in: chain, from: index)
                } else {
                    index += 1
                }
                continue
            }
            var cursor = index + 1
            var name = ""
            while cursor < chain.count,
                  chain[cursor].isLetter || chain[cursor].isNumber || chain[cursor] == "_" {
                name.append(chain[cursor])
                cursor += 1
            }
            guard collectionOps.contains(name) else { break }
            while cursor < chain.count,
                  chain[cursor] == " " || chain[cursor] == "\t" || chain[cursor] == "\n" {
                cursor += 1
            }
            var body = ""
            var end = cursor
            if cursor < chain.count, chain[cursor] == "{" {
                end = endOfBalancedGroup(in: chain, from: cursor)
                body = String(chain[cursor..<end])
            } else if cursor < chain.count, chain[cursor] == "(" {
                end = endOfBalancedGroup(in: chain, from: cursor)
                let inner = String(chain[cursor..<end])
                if inner.contains("{") { body = inner }
            }
            ops.append((name, uiProperties.contains { body.contains($0) }))
            index = max(end, cursor)
        }
        return ops
    }

    private static func endOfBalancedGroup(in chain: [Character], from start: Int) -> Int {
        var depth = 0
        var index = start
        while index < chain.count {
            let character = chain[index]
            if character == "(" || character == "[" || character == "{" {
                depth += 1
            } else if character == ")" || character == "]" || character == "}" {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return chain.count
    }

    /// The text in front of the needle on its own line, plus the line above it
    /// when the chain is wrapped — `let x = app.buttons` on one line and
    /// `.allElementsBoundByIndex` on the next is one statement, and the `let`
    /// is the part that says the elements escape.
    private static func head(in text: [Character], before index: Int) -> String {
        var lineStart = index
        while lineStart > 0, text[lineStart - 1] != "\n" { lineStart -= 1 }
        var head = String(text[lineStart..<index])
        if head.trimmingCharacters(in: .whitespaces).hasPrefix(".") {
            var previousStart = lineStart - 1
            while previousStart > 0, text[previousStart - 1] != "\n" { previousStart -= 1 }
            head = String(text[max(0, previousStart)..<index])
        }
        return head
    }

    // MARK: - The census

    /// What each file holds today. Counts rather than line numbers: these
    /// files are edited by several people in a round and a line number is
    /// stale within the hour, while "AuthUITests has three" survives a rename
    /// and an insertion.
    ///
    /// Every entry is a real instance of the shape. None of them are fixed
    /// here — the files belong to other people's work in this round, and two
    /// agents editing one file produces a conflict rather than a fix. The
    /// list exists so the number cannot go up quietly. One site can count
    /// twice — `.filter { …frame… }.min { …frame… }` bound to a name is both
    /// `twoPasses` and `elementsEscape` — because they are two separate things
    /// to fix and a single number would hide one of them.
    private static let census: [String: Int] = [
        "AccessibilityUITests.swift": 5,
        "AuthUITests.swift": 2,   // was 3; one was fixed while this round ran
        "CommentUITests.swift": 1,
        "DeviceAcceptanceUITests.swift": 4,
        "HitRegionBoundaryUITests.swift": 1,
        "LikeUITests.swift": 2,
        "NavigationUITests.swift": 2,
        "ScreenshotUITests.swift": 4,   // was 5; one was fixed while this round ran
        "VideoPlaybackUITests.swift": 1,
    ]

    static func scanUITestSources() throws -> [String: [Finding]] {
        let fm = FileManager.default
        var byFile: [String: [Finding]] = [:]
        let contents = try fm.contentsOfDirectory(at: uiTestDirectory, includingPropertiesForKeys: nil)
        for url in contents where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            let source = try String(contentsOf: url, encoding: .utf8)
            let found = findings(in: source, file: name)
            if !found.isEmpty { byFile[name] = found }
        }
        return byFile
    }

    // MARK: - The tests

    /// No file may grow a new instance of the shape.
    ///
    /// This is the half that matters: it is the one a person writing the sixth
    /// instance trips over, and it does not care where in the file they put it.
    @Test func noUITestFileGrowsANewStaleQueryRead() throws {
        let byFile = try Self.scanUITestSources()
        var grown: [String] = []
        for (file, found) in byFile.sorted(by: { $0.key < $1.key }) {
            let allowed = Self.census[file] ?? 0
            guard found.count > allowed else { continue }
            grown.append("""
                \(file): \(found.count) now, \(allowed) in the census
                \(found.map { "    \($0)" }.joined(separator: "\n"))
                """)
        }
        #expect(
            grown.isEmpty,
            """
            A UI test collects elements with allElementsBoundByIndex and reads a \
            property off them afterwards. That is two traversals of a tree that \
            moves, and the second one fails with "Failed to get matching \
            snapshot" — which reads like a missing control and is not one.

            Take the value out in the same pass that selects it:

                .compactMap { element -> (XCUIElement, CGRect)? in
                    guard element.exists else { return nil }
                    let frame = element.frame          // read here, once
                    return frame.isEmpty ? nil : (element, frame)
                }

            \(grown.joined(separator: "\n\n"))
            """
        )
    }

    /// And the census may not rot into a permanent exemption.
    ///
    /// Separate from the test above on purpose. A file dropping below its
    /// entry is somebody fixing one, which is good news and must not read as
    /// the same alarm as somebody adding one — but it does have to be noticed,
    /// or the number stops describing anything and the guard above starts
    /// tolerating a replacement instance.
    @Test func theCensusStillDescribesTheseFiles() throws {
        let byFile = try Self.scanUITestSources()
        var stale: [String] = []
        for (file, allowed) in Self.census.sorted(by: { $0.key < $1.key }) {
            let now = byFile[file]?.count ?? 0
            if now < allowed { stale.append("\(file): \(now) now, census says \(allowed)") }
        }
        #expect(
            stale.isEmpty,
            """
            Good news, and it still has to be recorded: these files hold fewer \
            stale-query reads than the census claims. Lower the numbers in \
            TestHygieneTests.census, or the guard above will wave through a \
            replacement instance on the strength of a fix that has already \
            happened.

            \(stale.joined(separator: "\n"))
            """
        )
    }

    // MARK: - The positive control

    /// The scanner catches each of the three shapes.
    ///
    /// A guard nobody has watched fail is a guard nobody knows works; this
    /// project has shipped two of those. Each snippet below is written the way
    /// the real instances are written, wrapping and all.
    @Test func theScannerCatchesEachShape() {
        let twoPasses = """
            private func labels(of query: XCUIElementQuery) -> [String] {
                query.allElementsBoundByIndex.filter { $0.exists }.map { $0.label }
            }
            """
        #expect(Self.findings(in: twoPasses, file: "A.swift").contains { $0.shape == .twoPasses },
                "two closures over one collection went unnoticed")

        let escaping = """
            let buttons = bar.buttons.allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty }
            let leftmost = buttons.min { $0.frame.minX < $1.frame.minX }
            """
        #expect(Self.findings(in: escaping, file: "B.swift").contains { $0.shape == .elementsEscape },
                "elements stored for a later property read went unnoticed")

        let iterated = """
            for element in app.staticTexts.allElementsBoundByIndex
            where element.exists && !element.frame.isEmpty {
                XCTAssertGreaterThan(element.frame.minX, 0, element.label)
            }
            """
        #expect(Self.findings(in: iterated, file: "C.swift").contains { $0.shape == .forInOverElements },
                "a for-in over collected elements went unnoticed")

        let wrapped = """
            let ours = app.buttons
                .allElementsBoundByIndex
                .filter { $0.exists && $0.isEnabled }
            """
        #expect(!Self.findings(in: wrapped, file: "D.swift").isEmpty,
                "a chain wrapped onto the next line hid the binding from the scanner")
    }

    /// And it does **not** catch the fix.
    ///
    /// This is the half that keeps the guard usable. If reading the value
    /// inside the selecting pass were reported too, the only way to satisfy
    /// the scanner would be to stop using `allElementsBoundByIndex` at all,
    /// and nobody would.
    @Test func theScannerLeavesTheFixAlone() {
        let fixed = """
            let bar = app.navigationBars.allElementsBoundByIndex
                .compactMap { element -> (XCUIElement, CGRect)? in
                    guard element.exists, element.identifier != "PetNote" else { return nil }
                    let frame = element.frame
                    return frame.isEmpty ? nil : (element, frame)
                }
                .first?.0 ?? app.navigationBars.firstMatch
            """
        #expect(Self.findings(in: fixed, file: "Fixed.swift").isEmpty,
                "the single-pass form is the fix and must not be reported")

        let arithmetic = """
            let back = bar.buttons.allElementsBoundByIndex
                .compactMap { button -> (XCUIElement, CGFloat)? in
                    guard button.exists else { return nil }
                    let frame = button.frame
                    return frame.isEmpty ? nil : (button, frame.minX)
                }
                .min { $0.1 < $1.1 }?.0 ?? bar.buttons.firstMatch
            """
        #expect(Self.findings(in: arithmetic, file: "Arithmetic.swift").isEmpty,
                "a second closure over values somebody already extracted touches no tree")

        let valuesOnly = """
            let ids = app.navigationBars.allElementsBoundByIndex.map { $0.identifier }
            """
        #expect(Self.findings(in: valuesOnly, file: "Values.swift").isEmpty,
                "one pass that hands back values is not two passes")

        let prose = """
            // let buttons = bar.buttons.allElementsBoundByIndex.filter { $0.exists }
            /// and then reading $0.frame off them is the mistake this describes.
            """
        #expect(Self.findings(in: prose, file: "Prose.swift").isEmpty,
                "a comment explaining the shape was reported as the shape")
    }

    /// `SessionFlow.swift` is the file that carries the note about this being
    /// the fifth instance, and it is written the fixed way throughout.
    ///
    /// Pinned as a test rather than left to the census, because it is the
    /// worked example: if a change makes the scanner report it, either the
    /// file regressed or the scanner started reporting the fix, and both are
    /// worth stopping on.
    @Test func theSharedHelpersAreClean() throws {
        let url = Self.uiTestDirectory.appendingPathComponent("SessionFlow.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let found = Self.findings(in: source, file: "SessionFlow.swift")
        #expect(found.isEmpty,
                "SessionFlow.swift: \(found.map(\.description).joined(separator: "\n"))")
    }
}
