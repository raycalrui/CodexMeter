import Foundation

/// Resolves String Catalog entries from either the selected app language or macOS.
enum L10n {
    private static var languageCode: String?

    static func setLanguage(_ code: String?) {
        languageCode = code
    }

    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Localizable", bundle: bundle, value: key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }

    static func formattedDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func remainingDuration(until date: Date, from now: Date) -> String {
        let totalMinutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))

        if totalMinutes == 0 {
            return string("duration.remaining_now")
        }

        let days = totalMinutes / 1_440
        let hours = totalMinutes % 1_440 / 60
        let minutes = totalMinutes % 60

        if days > 0, hours > 0 {
            return format("duration.remaining_days_hours_format", days, hours)
        }
        if days > 0 {
            return format("duration.remaining_days_format", days)
        }
        if hours > 0, minutes > 0 {
            return format("duration.remaining_hours_minutes_format", hours, minutes)
        }
        if hours > 0 {
            return format("duration.remaining_hours_format", hours)
        }
        return format("duration.remaining_minutes_format", minutes)
    }

    static var locale: Locale {
        languageCode.map(Locale.init(identifier:)) ?? .current
    }

    private static var bundle: Bundle {
        // Loading a language-specific bundle enables runtime switching without restart.
        guard let languageCode,
              let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            return .main
        }
        return localizedBundle
    }
}
