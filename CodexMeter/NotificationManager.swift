import Foundation
import UserNotifications

/// Sends transition-based alerts so each unsafe state is announced only once.
final class NotificationManager {
    private static let trackerDefaultsKey = "notifications.alertTracker"

    private let defaults: UserDefaults
    private var tracker: QuotaAlertTracker
    private let center = UNUserNotificationCenter.current()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tracker = defaults.data(forKey: Self.trackerDefaultsKey)
            .flatMap { try? JSONDecoder().decode(QuotaAlertTracker.self, from: $0) }
            ?? QuotaAlertTracker()
    }

    func resetEvaluationState() {
        tracker.reset()
        saveTracker()
    }

    func requestAuthorization(completion: @escaping (Bool, String?) -> Void) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }

            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async {
                    completion(true, nil)
                }
            case .denied:
                DispatchQueue.main.async {
                    completion(false, L10n.string("settings.notification_denied"))
                }
            case .notDetermined:
                self.center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    DispatchQueue.main.async {
                        completion(granted, error?.localizedDescription)
                    }
                }
            @unknown default:
                DispatchQueue.main.async {
                    completion(false, L10n.string("settings.notification_denied"))
                }
            }
        }
    }

    func evaluate(
        windows: [CodexUsageWindow],
        threshold: Int,
        at date: Date = Date()
    ) {
        let previousTracker = tracker
        let deliveries = tracker.evaluate(windows: windows, threshold: threshold, at: date)
        if tracker != previousTracker {
            saveTracker()
        }

        for delivery in deliveries {
            let window = delivery.window
            switch delivery.alert {
            case .overPace:
                send(
                    identifier: "codexmeter.\(window.historyID).pace",
                    title: L10n.string("notification.pace.title"),
                    body: L10n.format("notification.pace.body_format", window.name)
                )
            case .lowQuota:
                send(
                    identifier: "codexmeter.\(window.historyID).low",
                    title: L10n.string("notification.low.title"),
                    body: L10n.format(
                        "notification.low.body_format",
                        window.name,
                        window.remainingPercent
                    )
                )
            }
        }
    }

    private func saveTracker() {
        guard let data = try? JSONEncoder().encode(tracker) else { return }
        defaults.set(data, forKey: Self.trackerDefaultsKey)
    }

    private func send(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
