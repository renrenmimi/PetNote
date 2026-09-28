import Foundation
import Testing

/// A guard against a test that is named after a conclusion it never checks.
///
/// This exists because of one that shipped. `testThirtyVideosInARealListNever
/// ExceedTheCeiling` was cited as evidence that scrolling does not mis-trigger
/// navigation. It asserted the player ceiling, leftover players, and nothing
/// else — there was no navigation assertion anywhere in it. The name carried a
/// claim the body never made, and the name is what got read.
///
/// The general shape is unfalsifiable by a scanner: no regex knows whether
/// "NeverExceedTheCeiling" is covered by the assertions under it. So this
/// checks the one case that *is* decidable and that the general shape always
/// passes through — **a test that asserts nothing at all**. A test with zero
/// assertions can only ever report that it ran, and "it ran" is what a test
/// name plus a duration already claims.
///
/// **Three ways a test legitimately has no assertion**, and all three must say
/// so out loud rather than be inferred:
///
///   - it is a *recorder* — it prints a measurement for a human and decides
///     nothing. Those are named `record…`. `recordTheDisabledSubmitButtonRatio`
///     is one: disabled controls sit outside WCAG 1.4.3, so there is no
///     threshold to assert, and its own doc comment says "Not an assertion — a
///     record."
///   - its check is inside a helper that **throws on failure**.
///     `theSessionIsAmbientBeforeTheFirstFrameIsShown` has no `#expect`; it
///     calls `waitUntil`, which throws `WaitedTooLong` past the deadline. The
///     helper has to be named in `failingHelpers` below — a helper that
///     silently returns instead of throwing is exactly how four assertions
///     stayed green against a rejected query earlier in this project.
///   - it skips.
///
/// Anything else is a test that cannot fail, and a test that cannot fail is a
/// name with a runtime attached.
struct ClaimGuardTests {
    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static let testDirectories = ["PetNoteAppTests", "PetNoteAppUITests"]

    /// Both dialects: the unit target is Swift Testing, the UI target XCTest.
    private static let assertionTokens = [
        "#expect(", "#require(", "XCTAssert", "XCTFail(", "XCTUnwrap",
    ]

    /// Helpers that fail the test themselves. **Add to this list only after
    /// reading the helper and confirming it throws or asserts on the failing
    /// path.** A helper that returns normally when the thing it waited for
    /// never happened turns every caller into a test that cannot fail.
    private static let failingHelpers = [
        "waitUntil",              // TestVideoFixture.swift — throws WaitedTooLong
        "assertServerCommentCount",
        "signIn",                 // SessionFlow — asserts it reached the feed
        "openFirstPost",
    ]

    /// What counts as a helper failing the test itself.
    private static let failureTokens = ["#expect(", "#require(", "XCTAssert", "XCTFail(",
                                        "Issue.record(", "throw "]

    private static let skipTokens = ["XCTSkip", "withKnownIssue"]

    struct Claim: Sendable, CustomStringConvertible {
        let file: String
        let name: String
        var description: String { "\(file): \(name) 断言不了任何事" }
    }

    /// Returns the tests in `source` that assert nothing and do not declare why.
    static func unfalsifiableTests(in source: String, file: String) -> [Claim] {
        var found: [Claim] = []
        for (name, body) in testBodies(in: source) {
            if assertionTokens.contains(where: body.contains) { continue }
            if failingHelpers.contains(where: { body.contains($0 + "(") }) { continue }
            if skipTokens.contains(where: body.contains) { continue }
            if name.hasPrefix("record") || name.hasPrefix("testRecord") { continue }
            found.append(Claim(file: file, name: name))
        }
        return found
    }

    /// Both `@Test func name()` and `func testName()`, with the body taken by
    /// matching braces rather than by indentation — a test that closes on a
    /// differently indented line is still a test.
    static func testBodies(in source: String) -> [(name: String, body: String)] {
        var results: [(String, String)] = []
        let characters = Array(stripped(source))
        var index = 0

        while index < characters.count {
            guard let functionStart = nextFunction(in: characters, from: index) else { break }
            index = functionStart.bodyStart
            let name = functionStart.name
            guard let body = matchedBraces(characters, from: functionStart.bodyStart) else { break }
            index = body.end
            // XCTest only runs zero-argument methods whose name begins with
            // `test`. Without that half of the rule this guard flags its own
            // `testBodies(in:)` helper. Swift Testing's `@Test` does take
            // arguments (parameterized cases), so the rule is prefix-only.
            let isTest = functionStart.isAnnotated
                || (name.hasPrefix("test") && functionStart.takesNoArguments)
            if isTest { results.append((name, String(characters[body.start..<body.end]))) }
        }
        return results
    }

    /// Blanks out comments and string literals, keeping length and newlines
    /// so nothing downstream shifts.
    ///
    /// Without this the scanner reads its own prose. This file's doc comment
    /// contains the words `@Test func name()` as an example, and the first
    /// version of this guard duly reported `name` as a test asserting nothing
    /// — the guard's only finding, in the guard itself. A guard whose first
    /// output is a false positive gets switched off within a week.
    static func stripped(_ source: String) -> String {
        var output: [Character] = []
        let characters = Array(source)
        var index = 0
        var blockDepth = 0

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : " "

            if blockDepth > 0 {
                if character == "/" && next == "*" { blockDepth += 1; output += "  "; index += 2; continue }
                if character == "*" && next == "/" { blockDepth -= 1; output += "  "; index += 2; continue }
                output.append(character == "\n" ? "\n" : " ")
                index += 1
                continue
            }
            if character == "/" && next == "*" { blockDepth = 1; output += "  "; index += 2; continue }
            if character == "/" && next == "/" {
                while index < characters.count && characters[index] != "\n" { output.append(" "); index += 1 }
                continue
            }
            // Multi-line literals first: `"""` starts with the same quote.
            if character == "\"" && next == "\"" && index + 2 < characters.count && characters[index + 2] == "\"" {
                output += "   "
                index += 3
                while index + 2 < characters.count
                    && !(characters[index] == "\"" && characters[index + 1] == "\"" && characters[index + 2] == "\"") {
                    output.append(characters[index] == "\n" ? "\n" : " ")
                    index += 1
                }
                output += "   "
                index += 3
                continue
            }
            if character == "\"" {
                output.append(" ")
                index += 1
                while index < characters.count && characters[index] != "\"" {
                    if characters[index] == "\\" { output.append(" "); index += 1 }
                    if index < characters.count { output.append(" "); index += 1 }
                }
                if index < characters.count { output.append(" "); index += 1 }
                continue
            }
            output.append(character)
            index += 1
        }
        return String(output)
    }

    private struct FunctionHead {
        let name: String
        let bodyStart: Int
        let isAnnotated: Bool
        let takesNoArguments: Bool
    }

    private static func nextFunction(in characters: [Character], from start: Int) -> FunctionHead? {
        let text = String(characters[start...])
        guard let match = text.range(of: #"\bfunc\s+(\w+)"#, options: .regularExpression) else {
            return nil
        }
        let nameText = String(text[match]).replacingOccurrences(
            of: #"^func\s+"#, with: "", options: .regularExpression)
        let offset = start + text.distance(from: text.startIndex, to: match.lowerBound)
        guard let brace = bodyBrace(characters, after: offset) else { return nil }
        let signature = String(characters[offset..<brace])
        return FunctionHead(
            name: nameText,
            bodyStart: brace,
            isAnnotated: isAnnotated(characters, functionAt: offset),
            takesNoArguments: signature.range(of: #"\(\s*\)"#, options: .regularExpression) != nil
        )
    }

    /// The `{` that opens the body — the first one *after* the parameter list,
    /// not the first one after the name.
    ///
    /// A default argument can be a closure. `TestVideoFixture.waitUntil` has
    /// `describe: @escaping () -> String = { "" }`, and taking the first brace
    /// made its body the two characters `""`. The helper's `throw
    /// WaitedTooLong` sits after that, so the meta-check below reported the one
    /// helper it was written around as not failing anything. An injected
    /// control test did not catch this: the injected function had a plain
    /// signature, so it exercised the path that already worked.
    private static func bodyBrace(_ characters: [Character], after offset: Int) -> Int? {
        var index = offset
        // Step over the parameter list by paren depth, so braces inside it
        // never count.
        while index < characters.count, characters[index] != "(" {
            if characters[index] == "{" { return index }   // no parameter list at all
            index += 1
        }
        var depth = 0
        while index < characters.count {
            if characters[index] == "(" { depth += 1 }
            if characters[index] == ")" {
                depth -= 1
                if depth == 0 { index += 1; break }
            }
            index += 1
        }
        while index < characters.count, characters[index] != "{" {
            // A protocol requirement or a declaration without a body ends at
            // the newline before the next declaration; give up rather than
            // swallow the next function's body.
            if characters[index] == ";" { return nil }
            index += 1
        }
        return index < characters.count ? index : nil
    }

    /// Does an `@Test` attach to the `func` at `offset`?
    ///
    /// Taken as: the nearest `@Test` behind it, with no other `func` in
    /// between. The gap matters because the annotation's arguments run across
    /// lines — `@Test("名字", .tags(.slow))` puts hundreds of characters
    /// between the attribute and the declaration it belongs to, and a
    /// same-line-only test finds five of two hundred and fifty-eight.
    private static func isAnnotated(_ characters: [Character], functionAt offset: Int) -> Bool {
        let window = String(characters[max(0, offset - 600)..<offset])
        guard let annotation = window.range(of: "@Test", options: .backwards) else { return false }
        let between = window[annotation.upperBound...]
        return between.range(of: #"\bfunc\b"#, options: .regularExpression) == nil
    }

    private static func matchedBraces(_ characters: [Character], from start: Int) -> (start: Int, end: Int)? {
        var depth = 0
        var index = start
        while index < characters.count {
            if characters[index] == "{" { depth += 1 }
            if characters[index] == "}" {
                depth -= 1
                if depth == 0 { return (start, index) }
            }
            index += 1
        }
        return nil
    }

    // MARK: - The scan

    @Test func noTestInThisProjectAssertsNothing() throws {
        var claims: [Claim] = []
        for directory in Self.testDirectories {
            let url = Self.projectRoot.appendingPathComponent(directory)
            let files = try FileManager.default.contentsOfDirectory(atPath: url.path)
                .filter { $0.hasSuffix(".swift") }
            for file in files {
                let source = try String(contentsOf: url.appendingPathComponent(file), encoding: .utf8)
                claims += Self.unfalsifiableTests(in: source, file: "\(directory)/\(file)")
            }
        }
        #expect(claims.isEmpty, """
            这些测试一条断言都没有，也没说明为什么可以没有。\
            一个不可能失败的测试，等于一个名字加一个运行时长：
            \(claims.map(\.description).joined(separator: "\n"))
            """)
    }

    /// Every definition of an allowlisted helper must fail the test itself.
    ///
    /// The allowlist matches a *name*, and a name is not a function. When this
    /// was written there were three `waitUntil`s: `TestVideoFixture`'s throws
    /// `WaitedTooLong`, `ImageLoaderTests`' calls `Issue.record`, and
    /// `TouchTargetUITests`' returned `Bool` and did nothing on timeout. A test
    /// calling the third one and not checking its result asserts nothing, and
    /// the allowlist would have waved it through on the strength of the other
    /// two sharing its name.
    ///
    /// So the exemption is only honoured if it holds for every definition of
    /// the name. The remedy when this fails is to rename the one that does not
    /// fail — two helpers with the same name and opposite failure semantics is
    /// a hazard whatever this guard does about it.
    @Test func everyAllowlistedHelperFailsTheTestItself() throws {
        var offenders: [String] = []
        for directory in Self.testDirectories {
            let url = Self.projectRoot.appendingPathComponent(directory)
            let files = try FileManager.default.contentsOfDirectory(atPath: url.path)
                .filter { $0.hasSuffix(".swift") }
            for file in files {
                let source = Self.stripped(
                    try String(contentsOf: url.appendingPathComponent(file), encoding: .utf8))
                for (name, body) in Self.namedFunctions(in: source)
                where Self.failingHelpers.contains(name) {
                    if !Self.failureTokens.contains(where: body.contains) {
                        offenders.append("\(directory)/\(file): \(name)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, """
            这些 helper 出现在「断言在 helper 里」的白名单上，但它们自己并不让测试失败。\
            调用它们且没有其他断言的测试，会被守卫放行，而那条测试永远不会红：
            \(offenders.joined(separator: "\n"))
            改名，不要让两个失败语义相反的 helper 共用一个名字。
            """)
    }

    /// Every `func`, not only the ones that are tests.
    static func namedFunctions(in strippedSource: String) -> [(name: String, body: String)] {
        var results: [(String, String)] = []
        let characters = Array(strippedSource)
        var index = 0
        while index < characters.count {
            guard let head = nextFunction(in: characters, from: index) else { break }
            guard let body = matchedBraces(characters, from: head.bodyStart) else { break }
            results.append((head.name, String(characters[body.start..<body.end])))
            index = body.end
        }
        return results
    }

    // MARK: - Controls
    //
    // The scanner has to be shown to separate the two, or "0 findings" is just
    // "the parser matched nothing" — which is how the first version of this
    // audit reported a clean bill of health over 258 tests it had not parsed.

    @Test func theScannerCatchesATestThatAssertsNothing() {
        let source = """
            @Test func theFeedNeverLosesAPost() async throws {
                let feed = await loadFeed()
                print(feed.count)
            }
            """
        #expect(Self.unfalsifiableTests(in: source, file: "x").count == 1)
    }

    @Test func theScannerAcceptsAnAssertionInAThrowingHelper() {
        let source = """
            @Test func theSessionIsAmbient() async throws {
                try await waitUntil("ambient") { session.category == .ambient }
            }
            """
        #expect(Self.unfalsifiableTests(in: source, file: "x").isEmpty)
    }

    @Test func theScannerAcceptsARecorder() {
        let source = """
            @Test func recordTheRatio() {
                print("MEASURED \\(ratio)")
            }
            """
        #expect(Self.unfalsifiableTests(in: source, file: "x").isEmpty)
    }

    @Test func theScannerAcceptsAnOrdinaryAssertingTest() {
        let source = """
            @Test func theCountIsRight() {
                #expect(model.count == 2)
            }
            """
        #expect(Self.unfalsifiableTests(in: source, file: "x").isEmpty)
    }

    /// A closure in a default argument is not the body.
    ///
    /// This is the case the injected control missed, so it gets pinned
    /// separately: the injected test had a plain signature and exercised a path
    /// that already worked, and the parser went on mis-reading every helper
    /// with a default closure until the meta-check accused one of them.
    @Test func theParserStepsOverAClosureInADefaultArgument() {
        let source = """
            func waitUntil(
                _ what: String,
                describe: @escaping () -> String = { "" },
                _ condition: () -> Bool
            ) throws {
                while true { if condition() { return } }
                throw WaitedTooLong(what: what)
            }
            """
        let found = Self.namedFunctions(in: Self.stripped(source))
        #expect(found.count == 1)
        // The body, not the default argument's `{ "" }`.
        #expect(found.first?.body.contains("throw ") == true)
    }

    /// The parser is the part that failed first, so it gets its own control:
    /// it must find every test in a file, not just the ones whose annotation
    /// fits on one line.
    @Test func theParserFindsBothDialectsAndMultiLineAnnotations() {
        let source = """
            @Test func plain() { #expect(true) }
            @Test(
                "跨行的显示名",
                .tags(.slow)
            ) func multiLine() { #expect(true) }
            func testXCTestStyle() { XCTAssertTrue(true) }
            func notATest() { print("x") }
            """
        let names = Self.testBodies(in: source).map(\.name)
        #expect(names.contains("plain"))
        #expect(names.contains("multiLine"))
        #expect(names.contains("testXCTestStyle"))
        #expect(!names.contains("notATest"))
    }
}
