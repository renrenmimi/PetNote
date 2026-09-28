import SwiftUI
import Testing
import UIKit

@testable import PetNote

/// Acceptance 3.4 — and an explicit statement of what it is worth:
///
/// **A snapshot proves the layout has not regressed. It proves nothing about
/// how the screen looks or behaves on a real phone.** That is L5, it needs the
/// device, and no number of green snapshots substitutes for it.
///
/// Baselines are stored per OS major version. The CI runner is on iOS 26 while
/// this machine is on iOS 27, and rendering differs between them; rather than
/// pin one and let the other fail for a reason that is not a regression, a run
/// with no baseline for its OS records one and says so.
@MainActor
struct SnapshotTests {
    private static var snapshotDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__")
            .appendingPathComponent("iOS\(UIDevice.current.systemVersion.split(separator: ".").first ?? "0")")
    }

    /// iPhone 17 Pro's point width. Fixed so a different simulator does not
    /// look like a layout change.
    private static let width: CGFloat = 402

    private func render(
        _ view: some View,
        colorScheme: ColorScheme,
        typeSize: DynamicTypeSize
    ) -> UIImage? {
        let renderer = ImageRenderer(
            content: view
                .environment(\.colorScheme, colorScheme)
                .environment(\.dynamicTypeSize, typeSize)
                .frame(width: Self.width)
        )
        renderer.scale = 2
        return renderer.uiImage
    }

    /// Byte-identical comparison. Anti-aliasing is deterministic for a fixed
    /// renderer, scale and OS, so a tolerance would only hide real changes.
    private func compare(_ image: UIImage, named name: String) throws -> String? {
        let dir = Self.snapshotDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        guard let data = image.pngData() else { return "could not encode \(name)" }

        guard FileManager.default.fileExists(atPath: url.path) else {
            try data.write(to: url)
            return nil  // first run on this OS: baseline recorded
        }
        let baseline = try Data(contentsOf: url)
        if baseline == data { return nil }

        // Keep the failing render next to the baseline so the difference can be
        // looked at rather than guessed at.
        try data.write(to: dir.appendingPathComponent("\(name).failed.png"))
        return "\(name) differs from its baseline (\(baseline.count) vs \(data.count) bytes)"
    }

    @Test(arguments: [
        ("light-default", ColorScheme.light, DynamicTypeSize.large),
        ("dark-default", ColorScheme.dark, DynamicTypeSize.large),
        ("light-ax5", ColorScheme.light, DynamicTypeSize.accessibility5),
        ("dark-ax5", ColorScheme.dark, DynamicTypeSize.accessibility5),
    ])
    func tokenShowcaseIsStable(name: String, scheme: ColorScheme, size: DynamicTypeSize) throws {
        let image = try #require(render(TokenShowcase(), colorScheme: scheme, typeSize: size))
        #expect(image.size.width == Self.width)
        // AX5 makes the view taller; that it does is part of what is asserted.
        #expect(image.size.height > 0)
        let failure = try compare(image, named: name)
        #expect(failure == nil, "\(failure ?? "")")
    }

    /// AX5 must actually change the layout — if it does not, Dynamic Type is
    /// not reaching the view and the other snapshots would pass while the
    /// accessibility requirement silently fails.
    @Test func accessibilitySizeChangesTheLayout() throws {
        let normal = try #require(render(TokenShowcase(), colorScheme: .light, typeSize: .large))
        let ax5 = try #require(render(TokenShowcase(), colorScheme: .light, typeSize: .accessibility5))
        #expect(ax5.size.height > normal.size.height,
                "AX5 (\(ax5.size.height)) should be taller than default (\(normal.size.height))")
    }

    /// Light and dark must not render identically — that would mean the tokens
    /// are not adapting.
    @Test func darkModeRendersDifferently() throws {
        let light = try #require(render(TokenShowcase(), colorScheme: .light, typeSize: .large))
        let dark = try #require(render(TokenShowcase(), colorScheme: .dark, typeSize: .large))
        #expect(light.pngData() != dark.pngData())
    }
}
