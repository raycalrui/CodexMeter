import Foundation
import UserNotifications

final class NotificationManager {
    private struct AlertState: Equatable {
        let overPace: Bool
        let lowQuota: Bool
    }

    private var previousStates: [String: AlertState] = [:]
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization(completion: @escaping (Bool, String?) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                completion(granted, error?.localizedDescription)
            }
        }
    }

    func evaluate(
        windows: [CodexUsageWindow],
        threshold: Int,
        at date: Date = Date()
    ) {
        for window in windows {
            let state = AlertState(
                overPace: window.pace(at: date) == .overPace,
                lowQuota: window.remainingPercent <= threshold
            )
            let previous = previousStates[window.id]

            if state.overPace && previous?.overPace != true {
                send(
                    identifier: "codexmeter.\(window.id).pace",
                    title: L10n.string("notification.pace.title"),
                    body: L10n.format("notification.pace.body_format", window.name)
                )
            }

            if state.lowQuota && previous?.lowQuota != true {
                send(
                    identifier: "codexmeter.\(window.id).low",
                    title: L10n.string("notification.low.title"),
                    body: L10n.format(
                        "notification.low.body_format",
                        window.name,
                        window.remainingPercent
                    )
                )
            }

            previousStates[window.id] = state
        }
    }

    private func send(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
