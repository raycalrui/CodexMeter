import AppKit
import Combine
import Foundation
import ServiceManagement

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese
    case traditionalChinese

    var id: String { rawValue }

    var languageCode: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        case .traditionalChinese: "zh-Hant"
        }
    }

    var localizedName: String {
        switch self {
        case .system: L10n.string("settings.language.system")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        }
    }
}

enum SettingsDestination: Equatable {
    case notifications
    case loginItems
}

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
    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Keys.language)
            L10n.setLanguage(language.languageCode)
        }
    }

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
    @Published var settingsDestination: SettingsDestination?

    private let defaults: UserDefaults

    private enum Keys {
        static let language = "language"
        static let menuBarStyle = "menuBarStyle"
        static let notificationsEnabled = "notificationsEnabled"
        static let notificationThreshold = "notificationThreshold"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(
            rawValue: defaults.string(forKey: Keys.language) ?? ""
        ) ?? .system
        menuBarStyle = MenuBarDisplayStyle(
            rawValue: defaults.string(forKey: Keys.menuBarStyle) ?? ""
        ) ?? .progressAndPercentage
        notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        let storedThreshold = defaults.integer(forKey: Keys.notificationThreshold)
        notificationThreshold = storedThreshold == 0 ? 20 : storedThreshold
        L10n.setLanguage(language.languageCode)
        refreshLaunchAtLoginStatus()
    }

    func showSettingsError(_ message: String, destination: SettingsDestination? = nil) {
        settingsDestination = destination
        settingsError = message
    }

    func clearSettingsError() {
        settingsError = nil
        settingsDestination = nil
    }

    func openRelevantSystemSettings() {
        let urlString: String
        switch settingsDestination {
        case .notifications:
            let bundleID = Bundle.main.bundleIdentifier ?? "com.raycal.CodexMeter"
            urlString = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)"
        case .loginItems:
            urlString = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        case nil:
            return
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
            if SMAppService.mainApp.status == .requiresApproval {
                showSettingsError(
                    L10n.string("settings.launch_requires_approval"),
                    destination: .loginItems
                )
            } else {
                clearSettingsError()
            }
        } catch {
            refreshLaunchAtLoginStatus()
            showSettingsError(
                L10n.format("settings.launch_error_format", error.localizedDescription),
                destination: .loginItems
            )
        }
    }

    func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled || status == .requiresApproval
    }
}
