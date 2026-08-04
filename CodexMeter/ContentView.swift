import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var service: CodexUsageService
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if service.isStale {
                staleBanner
            }

            Divider()

            if service.isLoading && service.windows.isEmpty {
                loadingView
            } else if let errorMessage = service.errorMessage,
                      service.windows.isEmpty {
                errorView(errorMessage)
            } else {
                usageView
            }

            Divider()
            settingsView
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
            service.refreshIfNeeded()
        }
        .alert(
            L10n.string("settings.error_title"),
            isPresented: Binding(
                get: { settings.settingsError != nil },
                set: { if !$0 { settings.clearSettingsError() } }
            )
        ) {
            Button(L10n.string("action.ok")) {
                settings.clearSettingsError()
            }

            if settings.settingsDestination != nil {
                Button(L10n.string("action.open_system_settings")) {
                    settings.openRelevantSystemSettings()
                    settings.clearSettingsError()
                }
            }
        } message: {
            Text(settings.settingsError ?? "")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("app.title"))
                    .font(.headline)

                Text(service.accountDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if service.isRefreshInFlight {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                service.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help(L10n.string("action.refresh"))
            .disabled(service.isRefreshInFlight)
        }
    }

    private var staleBanner: some View {
        Label(L10n.string("data.stale"), systemImage: "clock.badge.exclamationmark")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var loadingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(L10n.string("loading.usage"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.string("error.cannot_read"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.string("action.retry")) {
                service.refresh()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
    }

    private var usageView: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            VStack(spacing: 16) {
                ForEach(service.windows) { window in
                    UsageWindowRow(window: window, now: context.date)
                }

                if let errorMessage = service.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var settingsView: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Picker(
                    L10n.string("settings.language"),
                    selection: Binding(
                        get: { settings.language },
                        set: { language in
                            settings.language = language
                            service.refresh()
                        }
                    )
                ) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.localizedName).tag(language)
                    }
                }

                Picker(L10n.string("settings.menubar_style"), selection: $settings.menuBarStyle) {
                    ForEach(MenuBarDisplayStyle.allCases) { style in
                        Text(style.localizedName).tag(style)
                    }
                }

                Toggle(
                    L10n.string("settings.notifications"),
                    isOn: Binding(
                        get: { settings.notificationsEnabled },
                        set: { service.setNotificationsEnabled($0) }
                    )
                )

                if settings.notificationsEnabled {
                    Picker(
                        L10n.string("settings.notification_threshold"),
                        selection: $settings.notificationThreshold
                    ) {
                        ForEach([10, 20, 30, 40], id: \.self) { value in
                            Text("\(value)%").tag(value)
                        }
                    }
                }

                Toggle(
                    L10n.string("settings.launch_at_login"),
                    isOn: Binding(
                        get: { settings.launchAtLoginEnabled },
                        set: { settings.setLaunchAtLogin($0) }
                    )
                )
            }
            .padding(.top, 10)
        } label: {
            Label(L10n.string("settings.title"), systemImage: "gearshape")
        }
    }

    private var footer: some View {
        HStack {
            if let lastUpdated = service.lastUpdated {
                Text(L10n.format(
                    "status.updated_at_format",
                    L10n.formattedTime(lastUpdated)
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            } else {
                Text(L10n.string("status.local_server"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(L10n.string("action.quit")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

private struct UsageWindowRow: View {
    let window: CodexUsageWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.name)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                paceLabel
            }

            MetricBar(
                label: L10n.string("quota.remaining"),
                value: Double(window.remainingPercent),
                tint: quotaTint,
                symbol: "battery.75percent"
            )

            MetricBar(
                label: L10n.string("time.remaining"),
                value: window.remainingTimePercent(at: now),
                tint: .blue,
                symbol: "clock"
            )

            HStack {
                if let resetsAt = window.resetsAt {
                    Label(
                        L10n.format(
                            "quota.reset_remaining_format",
                            L10n.remainingDuration(until: resetsAt, from: now)
                        ),
                        systemImage: "hourglass"
                    )
                } else {
                    Label(L10n.string("quota.reset_unavailable"), systemImage: "hourglass")
                }

                Spacer()

                if let resetsAt = window.resetsAt {
                    Text(L10n.format(
                        "quota.reset_format",
                        L10n.formattedDateTime(resetsAt)
                    ))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var paceLabel: some View {
        switch window.pace(at: now) {
        case .onTrack:
            Label(L10n.string("pace.on_track"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help(paceHelpText)
        case .overPace:
            Label(L10n.string("pace.over"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(paceHelpText)
        case .unavailable:
            Label(L10n.string("pace.unavailable"), systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
                .help(L10n.string("pace.unavailable_help"))
        }
    }

    private var paceHelpText: String {
        guard let delta = window.paceDelta(at: now) else {
            return L10n.string("pace.unavailable_help")
        }
        return L10n.format("pace.delta_format", delta)
    }

    private var quotaTint: Color {
        switch window.attentionLevel(at: now) {
        case .normal: .accentColor
        case .warning: .yellow
        case .critical: .red
        }
    }
}

private struct MetricBar: View {
    let label: String
    let value: Double?
    let tint: Color
    let symbol: String

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Label(label, systemImage: symbol)
                Spacer()
                Text(value.map { "\(Int($0.rounded()))%" } ?? "—")
                    .monospacedDigit()
            }
            .font(.caption)

            ProgressView(value: value ?? 0, total: 100)
                .tint(tint)
                .opacity(value == nil ? 0.25 : 1)
        }
        .accessibilityElement(children: .combine)
    }
}
