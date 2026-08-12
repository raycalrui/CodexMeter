import SwiftUI

enum CodexMeterWindowID {
    static let developerOptions = "developer-options"
    static let history = "usage-history"
    static let about = "about"
}

@main
struct CodexMeterApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var history: UsageHistoryModel
    @StateObject private var usageService: CodexUsageService
    @StateObject private var updateChecker: UpdateChecker

    init() {
        // The service and settings UI must share one settings instance so changes
        // such as notification thresholds take effect immediately.
        let settings = AppSettings()
        let history = UsageHistoryModel()
        let updateChecker = UpdateChecker(
            includePrereleases: settings.includePrereleaseUpdates
        )
        _settings = StateObject(wrappedValue: settings)
        _history = StateObject(wrappedValue: history)
        _usageService = StateObject(
            wrappedValue: CodexUsageService(settings: settings, history: history)
        )
        _updateChecker = StateObject(wrappedValue: updateChecker)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(
                service: usageService,
                settings: settings,
                history: history,
                updateChecker: updateChecker
            )
        } label: {
            MenuBarProgressView(
                remainingPercent: menuBarSnapshot.remainingPercent,
                remainingTimePercent: menuBarSnapshot.remainingTimePercent,
                title: menuBarSnapshot.title,
                style: settings.menuBarStyle,
                attentionLevel: menuBarSnapshot.attentionLevel,
                isStale: menuBarSnapshot.isStale,
                appearance: settings.developerAppearance
            )
        }
        .menuBarExtraStyle(.window)

        // A sheet attached to MenuBarExtra disappears when the status window
        // loses focus. Keep developer controls in an independent app window.
        Window(
            "CodexMeter",
            id: CodexMeterWindowID.developerOptions
        ) {
            DeveloperOptionsView(
                settings: settings,
                history: history,
                updateChecker: updateChecker
            )
        }
        .defaultSize(width: 540, height: 680)
        .windowResizability(.contentSize)

        Window("CodexMeter", id: CodexMeterWindowID.history) {
            UsageHistoryView(
                service: usageService,
                settings: settings,
                history: history
            )
        }
        .defaultSize(width: 900, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        Window("CodexMeter", id: CodexMeterWindowID.about) {
            AboutView(
                settings: settings,
                history: history,
                updateChecker: updateChecker
            )
        }
        .defaultSize(width: 500, height: 620)
        .windowResizability(.contentSize)
    }

    private var menuBarSnapshot: MenuBarPreviewSnapshot {
        if settings.developerPreviewEnabled {
            return settings.developerPreviewSnapshot
        }

        let window = usageService.mostConstrainedWindow
        return MenuBarPreviewSnapshot(
            remainingPercent: usageService.mostConstrainedRemainingPercent,
            remainingTimePercent: window?.remainingTimePercent(at: Date()),
            title: usageService.menuBarTitle,
            attentionLevel: window?.attentionLevel(at: Date()) ?? .normal,
            isStale: usageService.isStale
        )
    }
}
