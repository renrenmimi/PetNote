import Foundation
import Testing

@testable import PetNote

/// Every name in `Callables` is a function the backend actually exports.
///
/// The names are a contract with code this client does not own. A typo is a
/// runtime failure on a path that may only be reached by one user action —
/// someone's upload stops working and the report arrives days later. Checking
/// them against `functions/src` turns that into a test failure at the moment
/// the typo is written, and turns a rename on the backend side into a failure
/// too, which is the half that a client-only constant list cannot give.
///
/// It reads the TypeScript sources rather than talking to Firebase: no network,
/// no credentials, no deployed environment, and it works on a laptop with
/// nothing running.
struct CallableNameTests {
    /// The repository root, from this file at ios-native/PetNoteAppTests/…
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Names the backend exports as callables, read out of `functions/src`.
    static func exportedCallables() throws -> Set<String> {
        let directory = repositoryRoot.appendingPathComponent("functions/src")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".ts") }
        var found: Set<String> = []
        // `export const name = onCall(` and the two that do not follow it:
        // `deleteUserAccount` and `sendNotification` are declared the same way
        // but were named before the suffix convention.
        let pattern = #"export\s+const\s+(\w+)\s*=\s*onCall"#
        for file in files {
            let source = try String(
                contentsOf: directory.appendingPathComponent(file), encoding: .utf8
            )
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            let regex = try NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: source, range: range) {
                if let r = Range(match.range(at: 1), in: source) {
                    found.insert(String(source[r]))
                }
            }
        }
        return found
    }

    @Test func everyNameTheClientUsesIsExportedByTheBackend() throws {
        let exported = try Self.exportedCallables()
        // A parser that found nothing would pass this test for every name, so
        // it is checked first. This is the shape that has already reported a
        // clean bill of health over 258 unparsed tests in this project.
        #expect(
            exported.count > 20,
            """
            Only \(exported.count) callables were found in functions/src, which \
            is too few to be right — the parser, not the client, is what this \
            would be measuring.
            """
        )

        let missing = Callables.all.filter { !exported.contains($0) }.sorted()
        #expect(
            missing.isEmpty,
            """
            These names are in Callables but no function exports them. Either \
            the name is wrong here or it was renamed on the backend:
            \(missing.joined(separator: "\n"))
            """
        )
    }

    @Test func theRegistryHasNoDuplicates() {
        let counts = Dictionary(grouping: Callables.all, by: { $0 }).mapValues(\.count)
        let repeated = counts.filter { $0.value > 1 }.keys.sorted()
        #expect(
            repeated.isEmpty,
            """
            Listed more than once in Callables.all, so the coverage check above \
            is weaker than it looks: \(repeated.joined(separator: ", "))
            """
        )
    }

    /// The reset flow that must stay unreachable.
    ///
    /// Not an oversight to be tidied up later: the numeric-code reset needs
    /// three secrets that do not exist in production, and a client that called
    /// it would send people who already cannot sign in into a flow that cannot
    /// finish. The web client uses Firebase's own reset link. If this ever
    /// fails, the question to answer first is whether those secrets exist —
    /// not how to make the test pass.
    @Test func theNumericCodeResetIsNotWiredUp() {
        let offLimits = ["requestPasswordResetCodeCallable", "confirmPasswordResetCodeCallable"]
        let wired = Callables.all.filter { offLimits.contains($0) }
        #expect(
            wired.isEmpty,
            """
            The numeric-code password reset is disabled in production and its \
            secrets do not exist there: \(wired.joined(separator: ", "))
            """
        )
    }

    /// The online recomputes that were switched off on purpose.
    ///
    /// Counts are maintained by the server's triggers. These three entries
    /// rewrote them on demand and were disabled; a client that called them
    /// would be re-enabling something the owner turned off. If this fails,
    /// the question is whether that decision changed — not how to make the
    /// test pass.
    ///
    /// Reads the app's source as well as the registry: a name passed as a
    /// literal at a call site never goes through `Callables.all`, and the
    /// registry check alone would stay green over it.
    @Test func theDisabledRecomputesAreNotWiredUp() throws {
        let offLimits = [
            "recomputePetPostCountCallable",
            "recomputePostInteractionCountsCallable",
            "recomputeLocationReviewAggregatesCallable",
        ]
        let registered = Callables.all.filter { offLimits.contains($0) }
        #expect(
            registered.isEmpty,
            "These online recomputes were deliberately disabled: \(registered.joined(separator: ", "))"
        )

        let appRoot = Self.repositoryRoot.appendingPathComponent("ios-native")
        var scanned = 0
        var mentions: [String] = []
        for folder in ["App", "Core", "Features", "DesignSystem", "Support"] {
            let directory = appRoot.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(atPath: directory.path) else { continue }
            for case let path as String in walker where path.hasSuffix(".swift") {
                let text = try String(
                    contentsOf: directory.appendingPathComponent(path), encoding: .utf8
                )
                scanned += 1
                for name in offLimits where text.contains("\"\(name)\"") {
                    mentions.append("\(folder)/\(path): \(name)")
                }
            }
        }
        // A scan that read nothing would find nothing and pass.
        #expect(scanned > 50, "Only \(scanned) app source files were read")
        #expect(
            mentions.isEmpty,
            "A disabled recompute is named in the app source:\n\(mentions.joined(separator: "\n"))"
        )
    }
}
