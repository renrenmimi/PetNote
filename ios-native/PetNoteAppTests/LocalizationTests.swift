import Foundation
import Testing

@testable import PetNote

/// The Chinese interface, read from the app as built — not from the catalog
/// file, which says what was meant and not what shipped.
struct LocalizationTests {
    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func catalog() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("App/Localizable.xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(json["strings"] as? [String: Any])
    }

    private static func chinese(in entry: Any) -> String? {
        guard let entry = entry as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let zh = localizations["zh-Hans"] as? [String: Any],
              let unit = zh["stringUnit"] as? [String: Any] else { return nil }
        return unit["value"] as? String
    }

    private static func chineseBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"), "the app was built without Chinese")
        return try #require(Bundle(path: path))
    }

    /// Every translation in the catalog is in the built app, under the key
    /// the code asks for. A key that differs by one character — an escaped
    /// `%`, a curly apostrophe — would fall back to English without a word.
    @Test func everyTranslationReachedTheApp() throws {
        let bundle = try Self.chineseBundle()
        let missing = "\u{0}missing"
        var lost: [String] = []
        var count = 0
        for (key, entry) in try Self.catalog() {
            guard let expected = Self.chinese(in: entry) else { continue }
            count += 1
            let found = bundle.localizedString(forKey: key, value: missing, table: nil)
            if found != expected { lost.append("\(key) → \(found == missing ? "missing" : found)") }
        }
        #expect(count > 600, "only \(count) translations in the catalog")
        #expect(lost.isEmpty, "\(lost.count) not in the app as written:\n\(lost.prefix(20).joined(separator: "\n"))")
    }

    /// What the screens do with it: the same calls the app makes, in Chinese.
    @Test func theAppsOwnCallsComeOutInChinese() throws {
        let zh = Locale(identifier: "zh-Hans")
        let bundle = try Self.chineseBundle()
        #expect(String(localized: "Couldn't load notifications.", bundle: bundle, locale: zh) == "通知加载失败。")
        // A key that is not its English text.
        #expect(String(localized: "tab.create", defaultValue: "Create", bundle: bundle, locale: zh) == "发布")
        // An argument, filled in.
        let count = 3
        #expect(String(localized: "\(count) unread", bundle: bundle, locale: zh) == "3 条未读")
        // A literal `%` with no argument after it.
        #expect(String(localized: "At least one special character (!@#$%...)", bundle: bundle, locale: zh)
            == "至少包含一个特殊字符 (!@#$%...)")
    }

    /// And in English: the key that is not its own text reads as the web
    /// client's label for the same tab, `nav.create` = "Create" (it read
    /// "Post" until 09-25, which was not the web's word).
    @Test func englishIsUnchanged() {
        let en = Locale(identifier: "en")
        #expect(String(localized: "tab.create", defaultValue: "Create", locale: en) == "Create")
        #expect(PasswordPolicy.Strength.strong.label == "Strong")
        #expect(PasswordPolicy.requirements(for: "").first?.text == "At least 8 characters")
    }

    /// A translation keeps its arguments: the same number and kinds, so a
    /// Chinese line never reads a name where a count should be.
    @Test func translationsKeepTheirArguments() throws {
        let spec = try NSRegularExpression(pattern: #"%(?:\d+\$)?(lld|ld|d|@|f|\.\d+f|u)"#)
        func kinds(_ s: String) -> [String] {
            spec.matches(in: s, range: NSRange(s.startIndex..., in: s))
                .compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } }
                .sorted()
        }
        var mismatched: [String] = []
        for (key, entry) in try Self.catalog() {
            guard let zh = Self.chinese(in: entry) else { continue }
            let english = ((entry as? [String: Any])?["localizations"] as? [String: Any])
                .flatMap { $0["en"] as? [String: Any] }
                .flatMap { $0["stringUnit"] as? [String: Any] }
                .flatMap { $0["value"] as? String } ?? key
            if kinds(zh) != kinds(english) { mismatched.append("\(key) → \(zh)") }
        }
        #expect(mismatched.isEmpty, "\(mismatched.joined(separator: "\n"))")
    }
}
