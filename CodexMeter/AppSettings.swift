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

    /// A nil code keeps Foundation and the String Catalog on the system language.
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
        case .english: L10n.string("settings.language.english")
        case .simplifiedChinese: L10n.string("settings.language.simplified_chinese")
        case .traditionalChinese: L10n.string("settings.language.traditional_chinese")
        }
    }
}

enum SettingsDestination: Equatable {
    /// Identifies the System Settings pane that can resolve the latest error.
    case notifications
    case loginItems
}

extension MenuBarDisplayStyle {
    var localizedName: String {
        switch self {
        case .progressAndPercentage:
            return L10n.string("settings.style.progress_percentage")
        case .horizontalBarBesidePercentage:
            return L10n.string("settings.style.bar_beside")
        case .compactBarBelowPercentage:
            return L10n.string("settings.style.bar_below")
        case .dualBars:
            return L10n.string("settings.style.dual_bars")
        case .percentageOnly:
            return L10n.string("settings.style.percentage")
        case .progressOnly:
            return L10n.string("settings.style.progress")
        }
    }
}

extension MenuBarFontWeightChoice {
    var localizedName: String {
        L10n.string("developer.font_weight.\(rawValue)")
    }
}

extension MenuBarColorChoice {
    var localizedName: String {
        L10n.string("developer.color_choice.\(rawValue)")
    }
}

extension StaleIndicatorPlacement {
    var localizedName: String {
        L10n.string("developer.stale_placement.\(rawValue)")
    }
}

extension DeveloperPreviewPreset {
    var localizedName: String {
        L10n.string("developer.preset.\(rawValue)")
    }
}

extension HistoryRetention {
    var localizedName: String {
        L10n.string("history.retention.\(rawValue)")
    }
}

extension TokenActivityRange {
    var localizedName: String {
        L10n.string("history.range.\(rawValue)")
    }
}

extension QuotaHistoryRange {
    var localizedName: String {
        L10n.string("history.quota.range.\(rawValue)")
    }
}

/// Persists user preferences and bridges settings that are owned by macOS.
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

    @Published var historyRetention: HistoryRetention {
        didSet { defaults.set(historyRetention.rawValue, forKey: Keys.historyRetention) }
    }

    @Published var includePrereleaseUpdates: Bool {
        didSet { defaults.set(includePrereleaseUpdates, forKey: Keys.includePrereleaseUpdates) }
    }

    @Published var developerAppearance: MenuBarAppearance {
        didSet {
            let normalized = developerAppearance.normalized()
            if normalized != developerAppearance {
                developerAppearance = normalized
                return
            }
            if let data = try? JSONEncoder().encode(normalized) {
                defaults.set(data, forKey: Keys.developerAppearance)
            }
        }
    }

    @Published var developerPreviewEnabled: Bool {
        didSet { defaults.set(developerPreviewEnabled, forKey: Keys.developerPreviewEnabled) }
    }

    @Published var developerPreviewPreset: DeveloperPreviewPreset {
        didSet { defaults.set(developerPreviewPreset.rawValue, forKey: Keys.developerPreviewPreset) }
    }

    @Published private(set) var developerPreviewRemainingPercent: Double {
        didSet {
            defaults.set(
                developerPreviewRemainingPercent,
                forKey: Keys.developerPreviewRemainingPercent
            )
        }
    }

    @Published private(set) var developerPreviewRemainingTimePercent: Double {
        didSet {
            defaults.set(
                developerPreviewRemainingTimePercent,
                forKey: Keys.developerPreviewRemainingTimePercent
            )
        }
    }

    @Published private(set) var launchAtLoginEnabled = false
    @Published var settingsError: String?
    @Published var settingsDestination: SettingsDestination?

    let historyIdentitySalt: String

    private let defaults: UserDefaults

    private enum Keys {
        static let language = "language"
        static let menuBarStyle = "menuBarStyle"
        static let notificationsEnabled = "notificationsEnabled"
        static let notificationThreshold = "notificationThreshold"
        static let historyRetention = "history.retention"
        static let includePrereleaseUpdates = "updates.includePrereleases"
        static let developerAppearance = "developer.appearance"
        static let developerAppearanceDefaultsVersion = "developer.appearanceDefaultsVersion"
        static let developerPreviewEnabled = "developer.previewEnabled"
        static let developerPreviewPreset = "developer.previewPreset"
        static let developerPreviewRemainingPercent = "developer.previewRemainingPercent"
        static let developerPreviewRemainingTimePercent = "developer.previewRemainingTimePercent"
        static let historyIdentitySalt = "history.identitySalt"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let storedSalt = defaults.string(forKey: Keys.historyIdentitySalt),
           !storedSalt.isEmpty {
            historyIdentitySalt = storedSalt
        } else {
            let newSalt = UUID().uuidString
            defaults.set(newSalt, forKey: Keys.historyIdentitySalt)
            historyIdentitySalt = newSalt
        }
        language = AppLanguage(
            rawValue: defaults.string(forKey: Keys.language) ?? ""
        ) ?? .system
        menuBarStyle = MenuBarDisplayStyle(
            rawValue: defaults.string(forKey: Keys.menuBarStyle) ?? ""
        ) ?? .progressAndPercentage
        notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        let storedThreshold = defaults.integer(forKey: Keys.notificationThreshold)
        notificationThreshold = storedThreshold == 0 ? 20 : storedThreshold
        historyRetention = HistoryRetention(
            rawValue: defaults.string(forKey: Keys.historyRetention) ?? ""
        ) ?? .forever
        includePrereleaseUpdates = defaults.bool(forKey: Keys.includePrereleaseUpdates)
        let appearanceDefaultsVersion = defaults.integer(
            forKey: Keys.developerAppearanceDefaultsVersion
        )
        if let data = defaults.data(forKey: Keys.developerAppearance),
           let decoded = try? JSONDecoder().decode(MenuBarAppearance.self, from: data) {
            var migrated = decoded
            if appearanceDefaultsVersion < 1 {
                migrated = migrated.migratingLegacyRingDefaults()
            }
            if appearanceDefaultsVersion < 2 {
                migrated = migrated.migratingLegacyTimeColor()
            }
            let normalized = migrated.normalized()
            developerAppearance = normalized

            if appearanceDefaultsVersion < 2,
               let migratedData = try? JSONEncoder().encode(normalized) {
                defaults.set(migratedData, forKey: Keys.developerAppearance)
            }
        } else {
            developerAppearance = .acceptedV1
        }
        defaults.set(2, forKey: Keys.developerAppearanceDefaultsVersion)
        developerPreviewEnabled = defaults.bool(forKey: Keys.developerPreviewEnabled)
        developerPreviewPreset = DeveloperPreviewPreset(
            rawValue: defaults.string(forKey: Keys.developerPreviewPreset) ?? ""
        ) ?? .normal
        developerPreviewRemainingPercent = Self.storedPreviewPercent(
            defaults,
            key: Keys.developerPreviewRemainingPercent,
            fallback: 72
        )
        developerPreviewRemainingTimePercent = Self.storedPreviewPercent(
            defaults,
            key: Keys.developerPreviewRemainingTimePercent,
            fallback: 55
        )
        L10n.setLanguage(language.languageCode)
        refreshLaunchAtLoginStatus()
    }

    func resetDeveloperOptions() {
        menuBarStyle = .progressAndPercentage
        developerAppearance = .acceptedV1
        developerPreviewEnabled = false
        developerPreviewPreset = .normal
        developerPreviewRemainingPercent = 72
        developerPreviewRemainingTimePercent = 55
    }

    var developerPreviewSnapshot: MenuBarPreviewSnapshot {
        if developerPreviewPreset == .custom {
            return .custom(
                remainingPercent: developerPreviewRemainingPercent,
                remainingTimePercent: developerPreviewRemainingTimePercent
            )
        }

        let snapshot = developerPreviewPreset.snapshot
        guard developerPreviewPreset == .longText else { return snapshot }
        return MenuBarPreviewSnapshot(
            remainingPercent: snapshot.remainingPercent,
            remainingTimePercent: snapshot.remainingTimePercent,
            title: L10n.string("developer.preview_long_title"),
            attentionLevel: snapshot.attentionLevel,
            isStale: snapshot.isStale
        )
    }

    func selectDeveloperPreviewPreset(_ preset: DeveloperPreviewPreset) {
        developerPreviewPreset = preset
        guard preset != .custom else { return }

        let snapshot = developerPreviewSnapshot
        if let remainingPercent = snapshot.remainingPercent {
            developerPreviewRemainingPercent = Double(remainingPercent)
        }
        if let remainingTimePercent = snapshot.remainingTimePercent {
            developerPreviewRemainingTimePercent = remainingTimePercent
        }
    }

    func setDeveloperPreviewRemainingPercent(_ value: Double) {
        developerPreviewRemainingPercent = value.clamped(to: 0...100)
        developerPreviewPreset = .custom
    }

    func setDeveloperPreviewRemainingTimePercent(_ value: Double) {
        developerPreviewRemainingTimePercent = value.clamped(to: 0...100)
        developerPreviewPreset = .custom
    }

    func developerConfigurationJSON() -> String? {
        let configuration = DeveloperAppearanceExport(
            menuBarStyle: menuBarStyle,
            appearance: developerAppearance.normalized()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(configuration) else { return nil }
        return String(data: data, encoding: .utf8)
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
        // These URLs open the pane where macOS owns the final permission state.
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
            // Registration may succeed while macOS still requires user approval.
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
        // Keep the toggle on when registration exists but awaits system approval.
        launchAtLoginEnabled = status == .enabled || status == .requiresApproval
    }

    private static func storedPreviewPercent(
        _ defaults: UserDefaults,
        key: String,
        fallback: Double
    ) -> Double {
        let stored = (defaults.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
        return stored.clamped(to: 0...100)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, self))
    }
}

private struct DeveloperAppearanceExport: Codable {
    let menuBarStyle: MenuBarDisplayStyle
    let appearance: MenuBarAppearance
}
