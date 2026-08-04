import Foundation

enum ConsumptionPace: Equatable {
    case onTrack
    case overPace
    case unavailable
}

enum QuotaAttentionLevel: Equatable {
    case normal
    case warning
    case critical
}

struct CodexUsageWindow: Identifiable, Equatable {
    let id: String
    let name: String
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Date?

    var remainingPercent: Int {
        Self.clamp(100 - usedPercent)
    }

    func remainingTimePercent(at date: Date) -> Double? {
        guard let windowDurationMins,
              windowDurationMins > 0,
              let resetsAt else {
            return nil
        }

        let remainingSeconds = resetsAt.timeIntervalSince(date)
        guard remainingSeconds >= 0 else { return nil }

        let durationSeconds = Double(windowDurationMins) * 60
        return min(100, max(0, remainingSeconds / durationSeconds * 100))
    }

    func pace(at date: Date) -> ConsumptionPace {
        guard let remainingTime = remainingTimePercent(at: date) else {
            return .unavailable
        }

        return Double(remainingPercent) >= remainingTime ? .onTrack : .overPace
    }

    func paceDelta(at date: Date) -> Double? {
        guard let remainingTime = remainingTimePercent(at: date) else {
            return nil
        }
        return Double(remainingPercent) - remainingTime
    }

    func attentionLevel(at date: Date, criticalBelow threshold: Int = 20) -> QuotaAttentionLevel {
        if remainingPercent < threshold {
            return .critical
        }

        return pace(at: date) == .overPace ? .warning : .normal
    }

    private static func clamp(_ value: Int) -> Int {
        min(100, max(0, value))
    }
}
