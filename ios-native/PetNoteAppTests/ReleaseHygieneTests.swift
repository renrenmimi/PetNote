import Foundation
import Testing

/// Nothing that exists for a test may exist in the candidate build.
///
/// The rule is the owner's and it is absolute: fault injection is for isolated
/// test builds, and the final candidate package carries no test switch and no
/// probe. "Absolute" is the part that needs a machine. There are already eight
/// of these switches across five files, they were added one at a time by
/// people each solving a different problem, and the next one will be added the
/// same way — so the thing worth writing down is not a list of the ones that
/// exist today but a check that fails on the one added tomorrow.
///
/// **Compiled out, not skipped at runtime.** `if isTestBuild { … }` leaves the
/// flag name, the branch and whatever it reaches sitting in the shipped
/// binary, where `strings` finds them and where anything that can set a launch
/// argument can reach them. `#if DEBUG` means the code is never handed to the
/// compiler at all. That is the property checked here, and it rests on
/// `Release.xcconfig` defining no debug-only condition — which is why
/// `theReleaseConfigurationDefinesNoDebugOnlyCondition` exists alongside the
/// source scan rather than being taken on trust.
///
/// **What this can and cannot say.** It reads source, so it proves the gate is
/// written; it does not watch the compiler obey it. The end-to-end version of
/// that is a Release build with `strings` run over the product, which cannot
/// happen from inside a test bundle running on a simulator. It was run by hand
/// once against this tree and the result is in the delivery report; this test
/// is what keeps the source in the state that made that result true.
struct ReleaseHygieneTests {
    /// ios-native/, from this file at ios-native/PetNoteAppTests/…
    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PetNoteAppTests
            .deletingLastPathComponent()   // ios-native
    }

    /// Compilation conditions that are defined only by debug configurations.
    ///
    /// `DEBUG` is the one in use. `PETNOTE_TEST_HOOKS` is listed so the project
    /// can move to a dedicated condition — one that says what it is for, and
    /// that a future "debuggable release" configuration could not turn on by
    /// accident — without this file having to change on the same commit as the
    /// xcconfigs. Either way `theReleaseConfigurationDefinesNoDebugOnlyCondition`
    /// is what makes the name mean something.
    /// `PETNOTE_FAULT_INJECTION` is the dedicated condition this comment
    /// anticipated, and it is narrower than `DEBUG` on purpose: `DEBUG` is set
    /// in `Debug-TestCloud`, which is the configuration that goes on the
    /// owner's phone, so a switch that makes a refresh fail was reaching the
    /// acceptance package. Read-only probes stay behind `DEBUG`; anything that
    /// makes the app misbehave is behind this, and `Debug-Emulator` is the
    /// only configuration that sets it.
    private static let debugOnlyConditions: Set<String> = [
        "DEBUG", "PETNOTE_TEST_HOOKS", faultInjection,
    ]

    // MARK: - What counts as a test switch

    /// A shape that only a test switch has.
    ///
    /// Deliberately about the *mechanism* rather than about the names. A list
    /// of known flags catches nothing new, and "new" is the whole point: any
    /// switch a test can throw has to be read from the launch arguments, the
    /// environment, or a defaults key this app owns, because those are the
    /// only channels an XCUITest has into the process. Watching the channels
    /// catches a probe whose name nobody here has thought of.
    struct Probe: Sendable {
        let needle: String
        let what: String
    }

    private static let probes: [Probe] = [
        Probe(needle: "-petnote-", what: "a PetNote launch flag"),
        Probe(needle: "ProcessInfo.processInfo.arguments", what: "a read of the launch arguments"),
        Probe(needle: "ProcessInfo.processInfo.environment", what: "a read of the process environment"),
        Probe(needle: #"forKey: "petnote"#, what: "a PetNote UserDefaults override"),
    ]

    struct Hit: Sendable, CustomStringConvertible {
        let file: String
        let line: Int
        let what: String
        let text: String

        var description: String { "\(file):\(line): \(what) — \(text)" }
    }

    /// Every probe in `text` that is **not** inside a debug-only `#if`.
    ///
    /// Separated from the file walk so it can be pointed at a string, which is
    /// what `theScannerCatchesAnUngatedProbe` does: a guard nobody has watched
    /// fail is a guard nobody knows works. This project has shipped two of
    /// those already.
    ///
    /// The `#else` of a `#if DEBUG` is treated as *not* gated, which is the
    /// only reading that is safe — that branch is precisely the one a release
    /// build compiles.
    static func ungatedProbes(in text: String, file: String = "<memory>") -> [Hit] {
        var hits: [Hit] = []
        /// One entry per open `#if`: whether its *currently active* branch is
        /// guarded by a debug-only condition.
        var stack: [Bool] = []

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#if ") {
                stack.append(isDebugOnly(condition: String(line.dropFirst(4))))
                continue
            }
            if line.hasPrefix("#elseif ") {
                if !stack.isEmpty { stack[stack.count - 1] = isDebugOnly(condition: String(line.dropFirst(8))) }
                continue
            }
            if line == "#else" {
                if !stack.isEmpty { stack[stack.count - 1] = false }
                continue
            }
            if line == "#endif" {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }

            // Prose that names a flag is documentation, not a switch. The same
            // exemption the design-system guard makes, for the same reason:
            // without it, explaining why a gate is there would trip the gate.
            if line.hasPrefix("//") || line.hasPrefix("*") { continue }
            guard !stack.contains(true) else { continue }

            for probe in probes where line.contains(probe.needle) {
                hits.append(Hit(file: file, line: index + 1, what: probe.what, text: line))
            }
        }
        return hits
    }

    /// Whether a `#if` condition can only be true in a debug build.
    ///
    /// Conservative on purpose. `DEBUG && somethingElse` still cannot be true
    /// without `DEBUG`, so a conjunct is enough; `!DEBUG`, a bare `||`, and
    /// anything this does not recognise are all treated as not a gate.
    private static func isDebugOnly(condition: String) -> Bool {
        let conjuncts = condition
            .components(separatedBy: "&&")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ()\t")) }
        return conjuncts.contains { debugOnlyConditions.contains($0) }
    }

    // MARK: - What ships

    /// The directories the app target actually compiles, read from the project
    /// rather than written down here.
    ///
    /// This is not tidiness. `Tools/PerfSignposts.swift` reads `-petnote-perf`
    /// and is in no target at all, so it is not in the candidate build and a
    /// hardcoded directory list would either miss that or wrongly indict it.
    /// The day somebody adds `Tools` to the app target, that flag starts
    /// shipping and this test starts failing — which is the correct moment to
    /// find out, and is not a moment a hardcoded list would notice.
    static func shippedDirectories() throws -> [URL] {
        let project = projectRoot
            .appendingPathComponent("PetNoteApp.xcodeproj/project.pbxproj")
        let text = try String(contentsOf: project, encoding: .utf8)

        var pathForID: [String: String] = [:]
        for line in text.components(separatedBy: .newlines)
        where line.contains("isa = PBXFileSystemSynchronizedRootGroup") {
            guard let id = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first,
                  let range = line.range(of: #"path = ([^;]+);"#, options: .regularExpression)
            else { continue }
            let path = line[range]
                .replacingOccurrences(of: "path = ", with: "")
                .replacingOccurrences(of: ";", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            pathForID[id] = path
        }

        // The app target's block, up to its `fileSystemSynchronizedGroups` list.
        guard let target = text.range(of: #"/\* PetNoteApp \*/ = \{\s*isa = PBXNativeTarget;"#,
                                      options: .regularExpression),
              let groups = text.range(of: #"fileSystemSynchronizedGroups = \([^)]*\);"#,
                                      options: .regularExpression, range: target.upperBound..<text.endIndex)
        else {
            Issue.record("could not find the app target's synchronized groups in project.pbxproj")
            return []
        }

        var directories: [URL] = []
        for line in text[groups].components(separatedBy: .newlines) {
            let id = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
            if let path = pathForID[id] { directories.append(projectRoot.appendingPathComponent(path)) }
        }
        return directories
    }

    private static func shippedSources() throws -> [(name: String, text: String)] {
        let fm = FileManager.default
        var out: [(String, String)] = []
        for directory in try shippedDirectories() {
            guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return out
    }

    // MARK: - The switches that are not gated yet

    /// Known, owned, and not fixed here.
    ///
    /// Every entry is a real test switch that a Release build compiles today.
    /// They are listed rather than silently tolerated, and the listing is
    /// checked in both directions: an ungated switch that is **not** here
    /// fails the scan, and an entry here that is no longer ungated **also**
    /// fails — so the list cannot quietly become a permanent exemption after
    /// the file it names has been fixed.
    ///
    /// They are not fixed in this commit because the files belong to other
    /// people's work in this round and two agents editing one file produces a
    /// conflict, not a fix. The exact patches are in the delivery report.
    /// Until this list is empty the candidate build still contains test
    /// switches, and no report should say otherwise.
    ///
    /// It is a snapshot of one moment, and it is meant to shrink to nothing.
    /// If it grows, somebody added a switch after this rule was agreed.
    struct Pending: Sendable {
        let file: String
        let needle: String
        let owner: String
    }

    private static let pending: [Pending] = [
        // The three `account-menu agent` entries that used to sit here are
        // gone for the same reason as the `Core/Media/` ones: the two probe
        // view builders in `FeedView` and the playback-clock task in
        // `SignedInView` are behind `#if DEBUG` now, so a Release build never
        // compiles the flag names at all.
        // The five `Core/Media/` entries that used to sit here are gone: the
        // switches are behind `#if DEBUG` now, so there is nothing left to
        // exempt. Three of them — the two `petnoteVideo*Override` defaults
        // keys and `petnoteImageDelayMilliseconds` — carried no `-petnote-`
        // prefix and so were invisible to the grep that found all the others.
        // That is the lesson worth keeping when this list is next read:
        // scanning by name only finds the switches you already know about.
    ]

    private static func isPending(_ hit: Hit) -> Bool {
        pending.contains { $0.file == hit.file && hit.text.contains($0.needle) }
    }

    // MARK: - The tests

    /// Nothing a test can switch on reaches a Release build, except what is
    /// still on the list above.
    @Test func everyTestSwitchIsCompiledOutOfARelease() throws {
        var unexpected: [Hit] = []
        for source in try Self.shippedSources() {
            for hit in Self.ungatedProbes(in: source.text, file: source.name)
            where !Self.isPending(hit) {
                unexpected.append(hit)
            }
        }
        #expect(
            unexpected.isEmpty,
            """
            A test switch is compiled into the Release build and is not on the \
            known list in ReleaseHygieneTests.pending:

            \(unexpected.map(\.description).joined(separator: "\n"))

            Wrap it in #if DEBUG … #endif. A runtime check is not enough: the \
            flag name and everything it reaches stay in the shipped binary.
            """
        )
    }

    /// The list of known-ungated switches still describes reality.
    ///
    /// Without this the list rots into a permanent exemption: somebody gates
    /// `MediaView`, the entry stays, and the next probe added to that file
    /// with the same flag name is waved through by a line that was meant to
    /// describe a different problem.
    @Test func theKnownUngatedListHasNoStaleEntries() throws {
        var hits: [Hit] = []
        for source in try Self.shippedSources() {
            hits += Self.ungatedProbes(in: source.text, file: source.name)
        }
        let stale = Self.pending.filter { entry in
            !hits.contains { $0.file == entry.file && $0.text.contains(entry.needle) }
        }
        #expect(
            stale.isEmpty,
            """
            These are listed as known-ungated test switches but are no longer \
            ungated (or no longer exist). Delete them from \
            ReleaseHygieneTests.pending:

            \(stale.map { "\($0.file): \($0.needle) — owner: \($0.owner)" }.joined(separator: "\n"))
            """
        )
    }

    /// The scanner catches a probe somebody forgot to gate, and stops catching
    /// it once they gate it.
    ///
    /// This is the test of the test. Both halves matter: the first says the
    /// guard has teeth, and the second says `#if DEBUG` is what removes them —
    /// without it, a scanner that reported nothing at all would pass the first
    /// half every time.
    @Test func theScannerCatchesAnUngatedProbe() {
        let forgotten = """
            struct Newcomer {
                static let showTheThing =
                    ProcessInfo.processInfo.arguments.contains("-petnote-brand-new-probe")
            }
            """
        let found = Self.ungatedProbes(in: forgotten, file: "Newcomer.swift")
        #expect(!found.isEmpty, "an ungated probe went unnoticed")

        let gated = """
            struct Newcomer {
                #if DEBUG
                static let showTheThing =
                    ProcessInfo.processInfo.arguments.contains("-petnote-brand-new-probe")
                #endif
            }
            """
        #expect(Self.ungatedProbes(in: gated, file: "Newcomer.swift").isEmpty,
                "a probe behind #if DEBUG was reported as shipping")
    }

    /// `#if DEBUG` around a probe is worth nothing if the `#else` is where the
    /// probe lives, or if a release build defines `DEBUG`.
    @Test func theScannerIsNotFooledByAnElseBranchOrANegation() {
        let inTheElse = """
            #if DEBUG
            let quiet = true
            #else
            let showTheThing = ProcessInfo.processInfo.arguments.contains("-petnote-probe")
            #endif
            """
        #expect(!Self.ungatedProbes(in: inTheElse, file: "Else.swift").isEmpty,
                "the #else branch of #if DEBUG is exactly what a release compiles")

        let negated = """
            #if !DEBUG
            let showTheThing = ProcessInfo.processInfo.arguments.contains("-petnote-probe")
            #endif
            """
        #expect(!Self.ungatedProbes(in: negated, file: "Negated.swift").isEmpty,
                "#if !DEBUG is a release-only branch, not a gate")
    }

    /// The Release configuration defines none of the conditions the gates use.
    ///
    /// This is the half that makes `#if DEBUG` mean "not in the candidate
    /// build". It is a two-line file today and could be changed in a commit
    /// nobody connects to the switches it would turn back on.
    @Test func theReleaseConfigurationDefinesNoDebugOnlyCondition() throws {
        let conditions = try Self.compilationConditions(inConfigNamed: "Release")
        let leaked = conditions.intersection(Self.debugOnlyConditions)
        #expect(
            leaked.isEmpty,
            """
            Config/Release.xcconfig defines \(leaked.sorted().joined(separator: ", ")), \
            so every #if DEBUG block in the app is compiled into the candidate \
            build. Either remove it or move the gates to a condition Release \
            does not define.
            """
        )
    }

    /// And the debug configurations do define one, so the hooks exist where
    /// the tests need them.
    ///
    /// The failure this catches is the mirror image and is quieter: a gate
    /// that is never compiled anywhere looks exactly like a gate that works,
    /// right up to the UI test that cannot reach the fault it was written for.
    @Test(arguments: ["Debug-Emulator", "Debug-Prod", "Debug-TestCloud"])
    func debugConfigurationsDefineADebugOnlyCondition(name: String) throws {
        let conditions = try Self.compilationConditions(inConfigNamed: name)
        #expect(
            !conditions.intersection(Self.debugOnlyConditions).isEmpty,
            """
            Config/\(name).xcconfig defines none of \
            \(Self.debugOnlyConditions.sorted().joined(separator: ", ")), so nothing behind a \
            #if DEBUG can be reached from it — including the fault injection the UI tests need.
            """
        )
    }

    /// The condition that turns on code whose job is to make the app
    /// misbehave is set by exactly one configuration.
    ///
    /// `debugConfigurationsDefineADebugOnlyCondition` cannot say this. It asks
    /// whether each debug configuration defines *at least one* debug-only
    /// condition, and `Debug-TestCloud` satisfies that with `DEBUG` alone —
    /// which is exactly how a refresh that fails on purpose came to be
    /// compiled into the package that goes on the owner's phone. The rule that
    /// actually has to hold points the other way and names the condition.
    ///
    /// `Release` is in the list for completeness even though
    /// `theReleaseConfigurationDefinesNoDebugOnlyCondition` already covers it:
    /// this is the test somebody reads when they are about to add a line to an
    /// xcconfig, and a list with a hole in it invites the hole to be filled.
    @Test(arguments: ["Debug-Prod", "Debug-TestCloud", "Release"])
    func onlyTheEmulatorConfigurationTurnsOnFaultInjection(name: String) throws {
        let conditions = try Self.compilationConditions(inConfigNamed: name)
        #expect(
            !conditions.contains(Self.faultInjection),
            """
            Config/\(name).xcconfig defines \(Self.faultInjection), so every \
            refresh that fails on purpose, every read that stalls for eight \
            seconds and every page that never arrives is compiled into that \
            build — and into anything installed from it. Only Debug-Emulator \
            may define it; the failure tests run on the simulator and nothing \
            on a phone ever asks for one.
            """
        )
    }

    /// And the one configuration that must define it, does.
    ///
    /// The mirror image, and the quieter failure: a gate that is compiled
    /// nowhere looks exactly like a gate that works, right up to the UI test
    /// that cannot reach the fault it was written for and passes because the
    /// screen never changed.
    @Test func theEmulatorConfigurationTurnsFaultInjectionOn() throws {
        let conditions = try Self.compilationConditions(inConfigNamed: "Debug-Emulator")
        #expect(
            conditions.contains(Self.faultInjection),
            """
            Config/Debug-Emulator.xcconfig does not define \(Self.faultInjection), \
            so nothing behind that gate is compiled anywhere — including the \
            refresh and paging faults RefreshAndPagingUITests and CommentUITests \
            launch the app with.
            """
        )
    }

    /// Named once. It appears in `debugOnlyConditions`, in both tests above,
    /// and in two xcconfigs; a typo in any of them fails open.
    private static let faultInjection = "PETNOTE_FAULT_INJECTION"

    /// And only `Debug-Emulator` turns fault injection on.
    ///
    /// The mirror of the test above, and the one that actually keeps the
    /// device package clean. `debugConfigurationsDefineADebugOnlyCondition`
    /// asks whether a configuration has *at least one* debug-only condition,
    /// which `Debug-TestCloud` satisfies with `DEBUG` alone — so it would go on
    /// passing on the day somebody added `PETNOTE_FAULT_INJECTION` to
    /// `Debug-TestCloud.xcconfig` and put eleven ways of breaking the app back
    /// into the build that goes on the owner's phone.
    ///
    /// Read-only probes are a different question and are deliberately not
    /// covered here: device acceptance needs `-petnote-start-signed-out` and
    /// the video state probe, and the evidence from the last device session
    /// came from them.
    @Test(arguments: ["Debug-Prod", "Debug-TestCloud", "Release"])
    func onlyTheEmulatorConfigurationEnablesFaultInjection(name: String) throws {
        let conditions = try Self.compilationConditions(inConfigNamed: name)
        #expect(
            !conditions.contains("PETNOTE_FAULT_INJECTION"),
            """
            Config/\(name).xcconfig defines PETNOTE_FAULT_INJECTION. That gate holds \
            the switches that make the app fail on purpose — a refresh that fails, a page \
            that never arrives, a stream that stalls. Only Debug-Emulator may define it; \
            \(name) is a configuration somebody installs and uses.
            """
        )
    }

    /// …and `Debug-Emulator` really does, or the fault-injection UI tests are
    /// testing a build where the fault cannot happen and passing for the wrong
    /// reason.
    @Test func theEmulatorConfigurationEnablesFaultInjection() throws {
        let conditions = try Self.compilationConditions(inConfigNamed: "Debug-Emulator")
        #expect(
            conditions.contains("PETNOTE_FAULT_INJECTION"),
            """
            Config/Debug-Emulator.xcconfig no longer defines PETNOTE_FAULT_INJECTION, so every \
            fault-injection test is exercising a build with no faults in it.
            """
        )
    }

    private static func compilationConditions(inConfigNamed name: String) throws -> Set<String> {
        let url = projectRoot.appendingPathComponent("Config/\(name).xcconfig")
        let text = try String(contentsOf: url, encoding: .utf8)
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"),
                  line.hasPrefix("SWIFT_ACTIVE_COMPILATION_CONDITIONS"),
                  let value = line.components(separatedBy: "=").last
            else { continue }
            return Set(value.split(separator: " ").map(String.init))
        }
        return []
    }
}
