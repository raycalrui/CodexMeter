import SwiftUI

@main
struct CodexMeterApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var usageService: CodexUsageService

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _usageService = StateObject(wrappedValue: CodexUsageService(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(service: usageService, settings: settings)
        } label: {
            MenuBarProgressView(
                remainingPercent: usageService.mostConstrainedRemainingPercent,
                title: usageService.menuBarTitle,
                style: settings.menuBarStyle,
                isStale: usageService.isStale
            )
        }
        .menuBarExtraStyle(.window)
    }
}
