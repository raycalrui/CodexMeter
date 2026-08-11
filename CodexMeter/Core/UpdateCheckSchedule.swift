import Foundation

/// Pure timing rules for recurring update checks while the menu bar app stays open.
enum UpdateCheckSchedule {
    nonisolated static let successInterval: TimeInterval = 24 * 60 * 60
    nonisolated static let failureRetryInterval: TimeInterval = 60 * 60
    nonisolated static let minimumDelay: TimeInterval = 60

    nonisolated static func nextDelay(
        lastCheckedAt: Date?,
        now: Date,
        lastAttemptFailed: Bool
    ) -> TimeInterval {
        if lastAttemptFailed {
            return failureRetryInterval
        }

        guard let lastCheckedAt else {
            return minimumDelay
        }

        let remaining = successInterval - now.timeIntervalSince(lastCheckedAt)
        return max(minimumDelay, remaining)
    }
}
