import SwiftUI

enum CodexMeterWindowID {
    static let developerOptions = "developer-options"
}

@main
struct CodexMeterApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var usageService: CodexUsageService

    init() {
        // The service and settings UI must share one settings instance so changes
        // such as notification thresholds take effect immediately.
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _usageService = StateObject(wrappedValue: CodexUsageService(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(service: usageService, settings: settings)
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
            DeveloperOptionsView(settings: settings)
        }
        .defaultSize(width: 540, height: 680)
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
