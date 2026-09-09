import AppKit
import SwiftUI

enum CodexMeterWindowID {
    static let developerOptions = "developer-options"
    static let popoverCustomization = "popover-customization"
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
            .appAppearance(settings.appearanceMode)
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
            .appAppearance(settings.appearanceMode)
        }
        .defaultSize(width: 540, height: 680)
        .windowResizability(.contentSize)

        Window(
            "CodexMeter",
            id: CodexMeterWindowID.popoverCustomization
        ) {
            PopoverCustomizationView(
                service: usageService,
                settings: settings
            )
            .appAppearance(settings.appearanceMode)
        }
        .defaultSize(width: 520, height: 620)
        .windowResizability(.contentSize)

        Window("CodexMeter", id: CodexMeterWindowID.history) {
            UsageHistoryView(
                service: usageService,
                settings: settings,
                history: history
            )
            .appAppearance(settings.appearanceMode)
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
            .appAppearance(settings.appearanceMode)
        }
        .defaultSize(width: 500, height: 620)
        .windowResizability(.contentSize)
    }

    private var menuBarSnapshot: MenuBarPreviewSnapshot {
        if settings.developerPreviewEnabled {
            return settings.developerPreviewSnapshot
        }

        let window = settings.popoverContent.selectedMenuBarWindow(
            from: usageService.windows
        )
        return MenuBarPreviewSnapshot(
            remainingPercent: window?.remainingPercent,
            remainingTimePercent: window?.remainingTimePercent(at: Date()),
            title: window.map { "\($0.remainingPercent)%" }
                ?? (usageService.isLoading ? "…" : "--"),
            attentionLevel: window?.attentionLevel(at: Date()) ?? .normal,
            isStale: usageService.isStale
        )
    }
}

private extension View {
    /// Synchronizes both SwiftUI content and the AppKit host window. The latter
    /// is required for MenuBarExtra materials to change appearance immediately.
    func appAppearance(_ mode: AppAppearanceMode) -> some View {
        preferredColorScheme(mode.preferredColorScheme)
            .background(WindowAppearanceSynchronizer(mode: mode))
    }
}

private struct WindowAppearanceSynchronizer: NSViewRepresentable {
    let mode: AppAppearanceMode

    func makeNSView(context: Context) -> AppearanceTrackingView {
        AppearanceTrackingView(mode: mode)
    }

    func updateNSView(_ nsView: AppearanceTrackingView, context: Context) {
        nsView.apply(mode: mode)
    }

    final class AppearanceTrackingView: NSView {
        private var mode: AppAppearanceMode

        init(mode: AppAppearanceMode) {
            self.mode = mode
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyWindowAppearance()
        }

        func apply(mode: AppAppearanceMode) {
            self.mode = mode
            applyWindowAppearance()
        }

        private func applyWindowAppearance() {
            window?.appearance = mode.windowAppearance
        }
    }
}
