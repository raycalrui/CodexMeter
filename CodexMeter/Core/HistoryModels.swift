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

enum QuotaHistoryRange: String, CaseIterable, Identifiable, Sendable {
    case currentCycle
    case sevenDays
    case fourteenDays
    case month

    var id: String { rawValue }

    var interval: TimeInterval? {
        switch self {
        case .currentCycle: nil
        case .sevenDays: 7 * 24 * 60 * 60
        case .fourteenDays: 14 * 24 * 60 * 60
        case .month: 30 * 24 * 60 * 60
        }
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

struct QuotaHistoryChartPoint: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
    let remainingPercent: Double
    let isSyntheticStart: Bool
    let cycleID: String
}

struct QuotaIdealSegment: Identifiable, Equatable, Sendable {
    let id: String
    let start: Date
    let end: Date
    let startPercent: Double
    let endPercent: Double
}

/// Normalizes reset timestamp jitter before quota samples become chart segments.
/// Codex can slide an unused 100% window forward on every refresh, which is not
/// a real reset and must not create a new curve every minute.
enum QuotaCycleDetection {
    nonisolated static let resetTolerance: TimeInterval = 30 * 60
    nonisolated static let replenishmentThreshold = 3

    nonisolated static func startsNewCycle(
        previousRemaining: Int,
        previousReset: Date?,
        currentRemaining: Int,
        currentReset: Date?
    ) -> Bool {
        if currentRemaining - previousRemaining >= replenishmentThreshold {
            return true
        }

        return resetMeaningfullyChanged(
            previousRemaining: previousRemaining,
            previousReset: previousReset,
            currentRemaining: currentRemaining,
            currentReset: currentReset
        )
    }

    nonisolated static func resetMeaningfullyChanged(
        previousRemaining: Int,
        previousReset: Date?,
        currentRemaining: Int,
        currentReset: Date?
    ) -> Bool {
        // The reset countdown is provisional while the previous sample is
        // unused. Its transition to a locked reset after first use remains the
        // same logical cycle.
        if previousRemaining == 100 {
            return false
        }

        switch (previousReset, currentReset) {
        case let (previous?, current?):
            return abs(current.timeIntervalSince(previous)) > resetTolerance
        case (nil, nil):
            return false
        default:
            return true
        }
    }

    nonisolated static func segments(
        _ samples: [QuotaHistorySample]
    ) -> [[QuotaHistorySample]] {
        let ordered = samples.sorted { $0.sampledAt < $1.sampledAt }
        guard let first = ordered.first else { return [] }

        var result: [[QuotaHistorySample]] = []
        var current = [first]

        for sample in ordered.dropFirst() {
            guard let previous = current.last else { continue }
            if startsNewCycle(
                previousRemaining: previous.remainingPercent,
                previousReset: previous.resetsAt,
                currentRemaining: sample.remainingPercent,
                currentReset: sample.resetsAt
            ) {
                result.append(current)
                current = [sample]
            } else {
                current.append(sample)
            }
        }

        result.append(current)
        return result
    }
}

/// A chart-ready quota series that keeps weekly reset cycles visually separate.
struct QuotaHistorySeries: Equatable, Sendable {
    static let duration: TimeInterval = 7 * 24 * 60 * 60

    let start: Date
    let end: Date
    let range: QuotaHistoryRange
    let points: [QuotaHistoryChartPoint]
    let samples: [QuotaHistorySample]
    let gaps: [HistoryGap]
    let idealSegments: [QuotaIdealSegment]

    static func makeCurrentCycle(
        samples: [QuotaHistorySample],
        window: QuotaHistoryWindow,
        now: Date,
        gapThreshold: TimeInterval = 30 * 60
    ) -> QuotaHistorySeries? {
        let ordered = samples
            .filter { $0.windowID == window.id }
            .sorted { $0.sampledAt < $1.sampledAt }
        guard let cycleEnd = window.resetsAt ?? ordered.last?.resetsAt else { return nil }
        let cycleStart = cycleEnd.addingTimeInterval(-duration)
        let logicalCycle = QuotaCycleDetection.segments(ordered).last ?? []
        let currentSamples = logicalCycle.filter {
            $0.sampledAt >= cycleStart && $0.sampledAt <= cycleEnd
        }
        let cycleID = "cycle-\(logicalCycle.first?.id ?? 0)"

        var points = [QuotaHistoryChartPoint(
            id: "weekly-cycle-start-\(cycleStart.timeIntervalSince1970)",
            date: cycleStart,
            remainingPercent: 100,
            isSyntheticStart: true,
            cycleID: cycleID
        )]
        points.append(contentsOf: currentSamples.filter { $0.sampledAt > cycleStart }.map { sample in
            QuotaHistoryChartPoint(
                id: "quota-sample-\(sample.id)",
                date: sample.sampledAt,
                remainingPercent: Double(min(100, max(0, sample.remainingPercent))),
                isSyntheticStart: false,
                cycleID: cycleID
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

        return QuotaHistorySeries(
            start: cycleStart,
            end: cycleEnd,
            range: .currentCycle,
            points: points,
            samples: currentSamples,
            gaps: gaps,
            idealSegments: [QuotaIdealSegment(
                id: cycleID,
                start: cycleStart,
                end: cycleEnd,
                startPercent: 100,
                endPercent: 0
            )]
        )
    }

    static func makeHistorical(
        samples: [QuotaHistorySample],
        window: QuotaHistoryWindow,
        range: QuotaHistoryRange,
        now: Date,
        gapThreshold: TimeInterval = 30 * 60
    ) -> QuotaHistorySeries? {
        guard let interval = range.interval else {
            return makeCurrentCycle(
                samples: samples,
                window: window,
                now: now,
                gapThreshold: gapThreshold
            )
        }

        let domainStart = now.addingTimeInterval(-interval)
        let domainEnd = now
        let allOrdered = samples
            .filter { $0.windowID == window.id && $0.sampledAt <= domainEnd }
            .sorted { $0.sampledAt < $1.sampledAt }
        let ordered = allOrdered.filter { $0.sampledAt >= domainStart }
        guard !ordered.isEmpty else { return nil }

        let logicalCycles = QuotaCycleDetection.segments(allOrdered)
        var points: [QuotaHistoryChartPoint] = []
        var gaps: [HistoryGap] = []
        var idealSegments: [QuotaIdealSegment] = []

        for (index, logicalCycle) in logicalCycles.enumerated() {
            guard let firstSample = logicalCycle.first else { continue }
            let isLatestCycle = index == logicalCycles.indices.last
            guard let cycleEnd = isLatestCycle
                    ? (window.resetsAt ?? logicalCycle.last?.resetsAt)
                    : logicalCycle.last?.resetsAt else {
                continue
            }
            let cycleStart = cycleEnd.addingTimeInterval(-duration)
            let nextCycleStart = logicalCycles.indices.contains(index + 1)
                ? logicalCycles[index + 1].first?.sampledAt
                : nil
            let visibleStart = max(domainStart, cycleStart)
            let visibleEnd = min(domainEnd, cycleEnd, nextCycleStart ?? domainEnd)
            guard visibleStart < visibleEnd else { continue }

            let cycleID = "cycle-\(firstSample.id)"
            let cycleSamples = logicalCycle.filter { sample in
                sample.sampledAt >= visibleStart && sample.sampledAt <= visibleEnd
            }

            if !cycleSamples.isEmpty, cycleStart >= domainStart {
                points.append(QuotaHistoryChartPoint(
                    id: "weekly-cycle-start-\(cycleID)",
                    date: cycleStart,
                    remainingPercent: 100,
                    isSyntheticStart: true,
                    cycleID: cycleID
                ))
            }
            points.append(contentsOf: cycleSamples.map { sample in
                QuotaHistoryChartPoint(
                    id: "quota-sample-\(sample.id)",
                    date: sample.sampledAt,
                    remainingPercent: Double(min(100, max(0, sample.remainingPercent))),
                    isSyntheticStart: false,
                    cycleID: cycleID
                )
            })

            let observationDates = cycleSamples.map(\.sampledAt)
            if observationDates.isEmpty {
                gaps.append(HistoryGap(start: visibleStart, end: visibleEnd))
            } else {
                let gapDates = [visibleStart] + observationDates + [visibleEnd]
                gaps.append(contentsOf: zip(gapDates, gapDates.dropFirst()).compactMap {
                    earlier, later in
                    guard later.timeIntervalSince(earlier) > gapThreshold else { return nil }
                    return HistoryGap(start: earlier, end: later)
                })
            }

            idealSegments.append(QuotaIdealSegment(
                id: cycleID,
                start: visibleStart,
                end: visibleEnd,
                startPercent: idealRemaining(at: visibleStart, cycleEnd: cycleEnd),
                endPercent: idealRemaining(at: visibleEnd, cycleEnd: cycleEnd)
            ))
        }

        return QuotaHistorySeries(
            start: domainStart,
            end: domainEnd,
            range: range,
            points: points.sorted { $0.date < $1.date },
            samples: ordered,
            gaps: gaps,
            idealSegments: idealSegments
        )
    }

    private static func idealRemaining(at date: Date, cycleEnd: Date) -> Double {
        min(100, max(0, cycleEnd.timeIntervalSince(date) / duration * 100))
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
        let ordered = QuotaCycleDetection.segments(samples
            .filter { !$0.isStale && $0.sampledAt <= now }
        ).last ?? []

        guard ordered.count >= 3,
              let first = ordered.first,
              let last = ordered.last,
              last.sampledAt.timeIntervalSince(first.sampledAt) >= minimumSpan,
              last.remainingPercent > 0,
              !QuotaCycleDetection.resetMeaningfullyChanged(
                previousRemaining: first.remainingPercent,
                previousReset: first.resetsAt,
                currentRemaining: last.remainingPercent,
                currentReset: last.resetsAt
              ) else {
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
