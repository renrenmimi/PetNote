import Foundation

/// A post's age as the web client writes it (`src/utils/timeAgo.ts`), step
/// for step: under 5 seconds "just now", then seconds, minutes, hours, days
/// and weeks as one short unit ("30m", "30分钟前"), and from four weeks on
/// the date — month and day, with the year only when it is not this year.
///
/// It replaced `Text(date, style: .relative)`, which printed "31 min, 44 sec"
/// under every post and redrew it every second.
///
/// The short form is for the eye. VoiceOver gets `spoken`, the full phrase —
/// "30m" can be read out as thirty metres.
enum PostAge {
    static func short(
        _ date: Date,
        now: Date = Date(),
        bundle: Bundle = .main,
        locale: Locale? = nil,
        calendar: Calendar = .current
    ) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 5 {
            return String(localized: "post.age.now", defaultValue: "just now", bundle: bundle,
                          comment: "A post's age under five seconds")
        }
        if seconds < 60 {
            return String(localized: "post.age.seconds", defaultValue: "\(seconds)s", bundle: bundle,
                          comment: "A post's age in seconds, short: 42s")
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return String(localized: "post.age.minutes", defaultValue: "\(minutes)m", bundle: bundle,
                          comment: "A post's age in minutes, short: 30m")
        }
        let hours = minutes / 60
        if hours < 24 {
            return String(localized: "post.age.hours", defaultValue: "\(hours)h", bundle: bundle,
                          comment: "A post's age in hours, short: 5h")
        }
        let days = hours / 24
        if days < 7 {
            return String(localized: "post.age.days", defaultValue: "\(days)d", bundle: bundle,
                          comment: "A post's age in days, short: 3d")
        }
        let weeks = days / 7
        if weeks < 4 {
            return String(localized: "post.age.weeks", defaultValue: "\(weeks)w", bundle: bundle,
                          comment: "A post's age in weeks, short: 2w")
        }
        let locale = locale ?? interfaceLocale(bundle)
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .month(.defaultDigits).day(.defaultDigits)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year(.defaultDigits)
        }
        return date.formatted(style)
    }

    /// The same age in words, in the interface's language, for VoiceOver.
    static func spoken(
        _ date: Date, now: Date = Date(), bundle: Bundle = .main, locale: Locale? = nil
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale ?? interfaceLocale(bundle)
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    /// The language the interface is in, which is the bundle's first
    /// localization, not necessarily the phone's: PetNote can be set to
    /// Chinese on its own in Settings.
    private static func interfaceLocale(_ bundle: Bundle) -> Locale {
        Locale(identifier: bundle.preferredLocalizations.first ?? "en")
    }
}
