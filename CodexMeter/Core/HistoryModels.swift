import Foundation

enum HistoryRetention: String, CaseIterable, Codable, Identifiable, Sendable {
    case sevenDays
    case thirtyDays
    case ninetyDays
    case oneYear
    case forever

    var id: String { rawValue }

    var days: Int? {
        switch self {
        case .sevenDays: 7
        case .thirtyDays: 30
        case .ninetyDays: 90
        case .oneYear: 365
        case .forever: nil
        }
    }
}

enum TokenActivityRange: String, CaseIterable, Identifiable, Sendable {
    case week
    case month
    case threeMonths
    case year
    case all

    var id: String { rawValue }

    var interval: TimeInterval? {
        switch self {
        case .week: 7 * 24 * 60 * 60
        case .month: 30 * 24 * 60 * 60
        case .threeMonths: 90 * 24 * 60 * 60
        case .year: 365 * 24 * 60 * 60
        case .all: nil
        }
    }

    func includes(_ date: Date, now: Date) -> Bool {
        guard let interval else { return true }
        return date >= now.addingTimeInterval(-interval)
    }
}

enum TokenChartGranularity: Equatable, Sendable {
    case day
    case week
    case month

    var calendarComponent: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    func bucketStart(for date: Date) -> Date {
        let calendar = utcCalendar
        return calendar.dateInterval(of: calendarComponent, for: date)?.start ?? date
    }

    func centerDate(for date: Date) -> Date {
        let calendar = utcCalendar
        guard let interval = calendar.dateInterval(of: calendarComponent, for: date) else {
            return date
        }
        return interval.start.addingTimeInterval(interval.duration / 2)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

extension TokenActivityRange {
    var chartGranularity: TokenChartGranularity {
        switch self {
        case .week, .month, .threeMonths: .day
        case .year: .week
        case .all: .month
        }
    }
}

enum TokenTooltipLayout {
    static func clampedCenter(
        desiredX: Double,
        lowerBound: Double,
        upperBound: Double,
        width: Double
    ) -> Double {
        let halfWidth = max(0, width / 2)
        let minimum = lowerBound + halfWidth
        let maximum = upperBound - halfWidth
        guard minimum <= maximum else {
            return (lowerBound + upperBound) / 2
        }
        return min(max(desiredX, minimum), maximum)
    }
}

enum QuotaSampleSource: String, Codable, Equatable, Sendable {
    case refresh
    case notification
}

struct QuotaHistorySample: Identifiable, Equatable, Sendable {
    let id: Int64
    let windowID: String
    let windowName: String
    let sampledAt: Date
    let remainingPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Date?
    let startsSegment: Bool
    let isAnchor: Bool
    let isStale: Bool
    let source: QuotaSampleSource
}

struct QuotaHistoryWindow: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let windowDurationMins: Int?
    let resetsAt: Date?

    var isWeekly: Bool { windowDurationMins == 7 * 24 * 60 }
}

struct TokenUsageDailyBucket: Identifiable, Equatable, Sendable {
    let startDate: String
    let tokens: Int64

    var id: String { startDate }
}

struct TokenUsageSummary: Equatable, Sendable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
    let longestRunningTurnSeconds: Int64?
}

struct TokenUsageSnapshot: Equatable, Sendable {
    let dailyBuckets: [TokenUsageDailyBucket]?
    let summary: TokenUsageSummary
    let fetchedAt: Date
}

struct HistoryGap: Identifiable, Equatable, Sendable {
    let start: Date
    let end: Date

    var id: String { "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)" }
}

struct WeeklyQuotaChartPoint: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
    let remainingPercent: Double
    let isSyntheticStart: Bool
}

/// A chart-ready view of the current weekly reset cycle.
struct WeeklyQuotaCycle: Equatable, Sendable {
    static let duration: TimeInterval = 7 * 24 * 60 * 60

    let start: Date
    let end: Date
    let points: [WeeklyQuotaChartPoint]
    let samples: [QuotaHistorySample]
    let gaps: [HistoryGap]

    static func make(
        samples: [QuotaHistorySample],
        window: QuotaHistoryWindow,
        now: Date,
        gapThreshold: TimeInterval = 30 * 60
    ) -> WeeklyQuotaCycle? {
        let ordered = samples.sorted { $0.sampledAt < $1.sampledAt }
        guard let cycleEnd = window.resetsAt ?? ordered.last?.resetsAt else { return nil }
        let cycleStart = cycleEnd.addingTimeInterval(-duration)

        // Reset timestamps identify the active cycle. Filtering here prevents a
        // previous week's tail from appearing after the server advances the reset.
        let currentSamples = ordered.filter { sample in
            guard sample.sampledAt >= cycleStart, sample.sampledAt <= cycleEnd else {
                return false
            }
            guard let reset = sample.resetsAt else { return true }
            return abs(reset.timeIntervalSince(cycleEnd)) < 1
        }

        var points = [WeeklyQuotaChartPoint(
            id: "weekly-cycle-start-\(cycleStart.timeIntervalSince1970)",
            date: cycleStart,
            remainingPercent: 100,
            isSyntheticStart: true
        )]
        points.append(contentsOf: currentSamples.filter { $0.sampledAt > cycleStart }.map { sample in
            WeeklyQuotaChartPoint(
                id: "quota-sample-\(sample.id)",
                date: sample.sampledAt,
                remainingPercent: Double(min(100, max(0, sample.remainingPercent))),
                isSyntheticStart: false
            )
        })

        let observationDates = [cycleStart] + currentSamples.map(\.sampledAt)
        var gaps: [HistoryGap] = zip(
            observationDates,
            observationDates.dropFirst()
        ).compactMap { earlier, later in
            guard later.timeIntervalSince(earlier) > gapThreshold else { return nil }
            return HistoryGap(start: earlier, end: later)
        }
        let observedUntil = min(now, cycleEnd)
        if let last = observationDates.last,
           observedUntil.timeIntervalSince(last) > gapThreshold {
            gaps.append(HistoryGap(start: last, end: observedUntil))
        }

        return WeeklyQuotaCycle(
            start: cycleStart,
            end: cycleEnd,
            points: points,
            samples: currentSamples,
            gaps: gaps
        )
    }
}

enum CompactTokenFormatter {
    /// Formats token counts without scientific notation using product-standard units.
    static func string(_ value: Int64, locale: Locale = .current) -> String {
        let nonnegative = max(0, value)
        let units: [(threshold: Int64, suffix: String)] = [
            (1_000_000_000, "B"),
            (1_000_000, "M"),
            (1_000, "k")
        ]

        guard let unit = units.first(where: { nonnegative >= $0.threshold }) else {
            return decimalString(Double(nonnegative), maximumFractionDigits: 0, locale: locale)
        }
        let scaled = Double(nonnegative) / Double(unit.threshold)
        let decimals = scaled < 100 && scaled.rounded() != scaled ? 1 : 0
        return decimalString(scaled, maximumFractionDigits: decimals, locale: locale) + unit.suffix
    }

    private static func decimalString(
        _ value: Double,
        maximumFractionDigits: Int,
        locale: Locale
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? "0"
    }
}

struct QuotaExhaustionEstimate: Equatable, Sendable {
    let exhaustedAt: Date
    let calculatedAt: Date

    /// Produces a conservative linear estimate only within one reliable reset segment.
    static func calculate(
        samples: [QuotaHistorySample],
        now: Date,
        minimumSpan: TimeInterval = 15 * 60
    ) -> QuotaExhaustionEstimate? {
        let ordered = samples
            .filter { !$0.isStale && $0.sampledAt <= now }
            .sorted { $0.sampledAt < $1.sampledAt }

        guard ordered.count >= 3,
              let first = ordered.first,
              let last = ordered.last,
              last.sampledAt.timeIntervalSince(first.sampledAt) >= minimumSpan,
              last.remainingPercent > 0,
              first.resetsAt == last.resetsAt,
              !ordered.dropFirst().contains(where: \.startsSegment) else {
            return nil
        }

        // A rising remaining percentage means a reset or non-monotonic correction occurred.
        for pair in zip(ordered, ordered.dropFirst()) where pair.1.remainingPercent > pair.0.remainingPercent {
            return nil
        }

        guard first.remainingPercent - last.remainingPercent >= 2 else { return nil }

        let origin = first.sampledAt.timeIntervalSinceReferenceDate
        let points = ordered.map {
            (
                x: $0.sampledAt.timeIntervalSinceReferenceDate - origin,
                y: Double($0.remainingPercent)
            )
        }
        let meanX = points.map(\.x).reduce(0, +) / Double(points.count)
        let meanY = points.map(\.y).reduce(0, +) / Double(points.count)
        let numerator = points.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) }
        let denominator = points.reduce(0) { $0 + pow($1.x - meanX, 2) }

        guard denominator > 0 else { return nil }
        let slope = numerator / denominator
        guard slope < 0 else { return nil }

        let secondsUntilEmpty = Double(last.remainingPercent) / -slope
        let exhaustedAt = last.sampledAt.addingTimeInterval(secondsUntilEmpty)
        guard exhaustedAt > now else { return nil }

        // The official reset remains authoritative; an estimate after it has no useful meaning.
        if let resetsAt = last.resetsAt, exhaustedAt >= resetsAt {
            return nil
        }

        return QuotaExhaustionEstimate(exhaustedAt: exhaustedAt, calculatedAt: now)
    }
}

extension Array where Element == QuotaHistorySample {
    func gaps(longerThan interval: TimeInterval = 20 * 60) -> [HistoryGap] {
        let ordered = sorted { $0.sampledAt < $1.sampledAt }
        return zip(ordered, ordered.dropFirst()).compactMap { earlier, later in
            guard later.sampledAt.timeIntervalSince(earlier.sampledAt) > interval else {
                return nil
            }
            return HistoryGap(start: earlier.sampledAt, end: later.sampledAt)
        }
    }
}
