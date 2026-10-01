import Foundation

enum QuotaAlert: String, Codable, Equatable, Sendable {
    case overPace
    case lowQuota
}

/// Decides which quota alerts to deliver as windows enter alert states.
///
/// Remaining time falls continuously while quota falls in whole-percent steps,
/// so a window used at roughly the ideal rate keeps crossing the pace line.
/// An alert state therefore clears only after recovering by a margin. State is
/// keyed by the duration-scoped history identity because App Server's
/// primary/secondary slots can swap, and it is codable so a relaunch within the
/// same reset cycle does not repeat alerts that were already delivered.
struct QuotaAlertTracker: Codable, Equatable, Sendable {
    static let paceRecoveryMargin: Double = 2
    static let quotaRecoveryMargin = 2

    struct Delivery: Equatable, Sendable {
        let window: CodexUsageWindow
        let alert: QuotaAlert
    }

    private struct WindowState: Codable, Equatable, Sendable {
        var remainingPercent: Int
        var resetsAt: Date?
        var overPace: Bool
        var lowQuota: Bool
    }

    private var states: [String: WindowState] = [:]

    init() {}

    mutating func reset() {
        states.removeAll()
    }

    mutating func evaluate(
        windows: [CodexUsageWindow],
        threshold: Int,
        at date: Date
    ) -> [Delivery] {
        var deliveries: [Delivery] = []

        for window in windows {
            let key = window.historyID
            var previous = states[key]
            if let state = previous,
               QuotaCycleDetection.startsNewCycle(
                   previousRemaining: state.remainingPercent,
                   previousReset: state.resetsAt,
                   currentRemaining: window.remainingPercent,
                   currentReset: window.resetsAt
               ) {
                previous = nil
            }

            let overPace: Bool
            switch window.paceDelta(at: date) {
            case let delta?:
                overPace = previous?.overPace == true
                    ? delta < Self.paceRecoveryMargin
                    : delta < 0
            case nil:
                overPace = false
            }

            let lowQuota = previous?.lowQuota == true
                ? window.remainingPercent < threshold + Self.quotaRecoveryMargin
                : window.remainingPercent <= threshold

            if overPace && previous?.overPace != true {
                deliveries.append(Delivery(window: window, alert: .overPace))
            }
            if lowQuota && previous?.lowQuota != true {
                deliveries.append(Delivery(window: window, alert: .lowQuota))
            }

            states[key] = WindowState(
                remainingPercent: window.remainingPercent,
                resetsAt: window.resetsAt,
                overPace: overPace,
                lowQuota: lowQuota
            )
        }

        return deliveries
    }
}
