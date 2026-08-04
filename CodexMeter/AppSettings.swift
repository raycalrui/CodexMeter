import Combine
import Foundation
import ServiceManagement

enum MenuBarDisplayStyle: String, CaseIterable, Identifiable {
    case progressAndPercentage
    case percentageOnly
    case progressOnly

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .progressAndPercentage:
            return L10n.string("settings.style.progress_percentage")
        case .percentageOnly:
            return L10n.string("settings.style.percentage")
        case .progressOnly:
            return L10n.string("settings.style.progress")
        }
    }
}

final class AppSettings: ObservableObject {
    @Published var menuBarStyle: MenuBarDisplayStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Keys.menuBarStyle) }
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    @Published var notificationThreshold: Int {
        didSet { defaults.set(notificationThreshold, forKey: Keys.notificationThreshold) }
    }

    @Published private(set) var launchAtLoginEnabled = false
    @Published var settingsError: String?

    private let defaults: UserDefaults

    private enum Keys {
        static let menuBarStyle = "menuBarStyle"
        static let notificationsEnabled = "notificationsEnabled"
        static let notificationThreshold = "notificationThreshold"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarStyle = MenuBarDisplayStyle(
            rawValue: defaults.string(forKey: Keys.menuBarStyle) ?? ""
        ) ?? .progressAndPercentage
        notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        let storedThreshold = defaults.integer(forKey: Keys.notificationThreshold)
        notificationThreshold = storedThreshold == 0 ? 20 : storedThreshold
        refreshLaunchAtLoginStatus()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
            settingsError = SMAppService.mainApp.status == .requiresApproval
                ? L10n.string("settings.launch_requires_approval")
                : nil
        } catch {
            refreshLaunchAtLoginStatus()
            settingsError = L10n.format("settings.launch_error_format", error.localizedDescription)
        }
    }

    func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled || status == .requiresApproval
    }
}
