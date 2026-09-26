import Foundation
import Testing

@testable import PetNote

/// A post's age reads as the web client's `timeAgo` does, step for step.
struct PostAgeTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21
    private static let gregorianUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func english(_ secondsAgo: TimeInterval) -> String {
        PostAge.short(Self.now.addingTimeInterval(-secondsAgo), now: Self.now,
                      locale: Locale(identifier: "en"), calendar: Self.gregorianUTC)
    }

    @Test func englishStepsAsTheWebDoes() {
        #expect(english(0) == "just now")
        #expect(english(4) == "just now")
        #expect(english(5) == "5s")
        #expect(english(59) == "59s")
        #expect(english(60) == "1m")
        #expect(english(59 * 60 + 59) == "59m")
        #expect(english(3600) == "1h")
        #expect(english(23 * 3600) == "23h")
        #expect(english(24 * 3600) == "1d")
        #expect(english(6 * 86400) == "6d")
        #expect(english(7 * 86400) == "1w")
        #expect(english(27 * 86400) == "3w")
    }

    /// From four weeks on, the date: month and day, the year only when it is
    /// not this one.
    @Test func olderThanFourWeeksIsTheDate() {
        #expect(english(28 * 86400) == "8/24")
        #expect(english(300 * 86400) == "11/25/2025")
    }

    /// A clock that runs behind the server's makes a new post look like it is
    /// from the future. It is "just now", not a negative age.
    @Test func aPostFromTheFutureIsJustNow() {
        #expect(english(-90) == "just now")
    }

    @Test func chineseComesFromTheBuiltApp() throws {
        let path = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        func chinese(_ secondsAgo: TimeInterval) -> String {
            PostAge.short(Self.now.addingTimeInterval(-secondsAgo), now: Self.now, bundle: bundle,
                          locale: Locale(identifier: "zh-Hans"), calendar: Self.gregorianUTC)
        }
        #expect(chinese(2) == "刚刚")
        #expect(chinese(42) == "42秒前")
        #expect(chinese(30 * 60) == "30分钟前")
        #expect(chinese(5 * 3600) == "5小时前")
        #expect(chinese(3 * 86400) == "3天前")
        #expect(chinese(14 * 86400) == "2周前")
    }

    /// What VoiceOver hears is the whole phrase, not "30m".
    @Test func theSpokenFormIsWords() {
        let spoken = PostAge.spoken(Self.now.addingTimeInterval(-30 * 60), now: Self.now,
                                    locale: Locale(identifier: "en"))
        #expect(spoken == "30 minutes ago")
    }
}
