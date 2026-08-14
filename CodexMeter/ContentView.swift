import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var service: CodexUsageService
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: UsageHistoryModel
    @ObservedObject var updateChecker: UpdateChecker
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if settings.developerPreviewEnabled {
                previewModeBanner
            }

            if service.isStale {
                staleBanner
            }

            if case .updateAvailable(let release) = updateChecker.state {
                updateBanner(release)
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
            historySection
            Divider()
            SettingsSection(service: service, settings: settings)
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
            service.refreshIfNeeded()
        }
        .task(id: history.dataRevision) {
            // Load the preferred weekly cycle whenever the popover appears or
            // a successful refresh records a new local history sample.
            await history.load()
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

    private func updateBanner(_ release: AvailableUpdate) -> some View {
        Button {
            openWindow(id: CodexMeterWindowID.about)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } label: {
            HStack {
                Label(
                    L10n.format("updates.available_format", release.version),
                    systemImage: "arrow.down.circle.fill"
                )
                Spacer()
                Image(systemName: "chevron.right")
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.blue)
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

    private var previewModeBanner: some View {
        HStack(spacing: 8) {
            Label(
                L10n.string("developer.preview_mode_active"),
                systemImage: "eye.trianglebadge.exclamationmark"
            )
            .font(.caption)
            .foregroundStyle(.orange)

            Spacer()

            Button(L10n.string("developer.return_to_live")) {
                settings.developerPreviewEnabled = false
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
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
        // Update countdowns and pace locally every minute without another API call.
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            VStack(spacing: 16) {
                ForEach(service.windows) { window in
                    UsageWindowRow(
                        window: window,
                        now: context.date,
                        appearance: settings.developerAppearance
                    )

                    if window.id != service.windows.last?.id {
                        Divider()
                    }
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

    private var historySection: some View {
        VStack(spacing: 12) {
            Button(action: openHistoryWindow) {
                menuQuotaSection
            }
            .buttonStyle(.plain)

            Divider()

            Button(action: openHistoryWindow) {
                menuTokenSection
            }
            .buttonStyle(.plain)
        }
    }

    private var menuQuotaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("history.quota.title"))
                        .font(.subheadline.weight(.semibold))
                    Text(L10n.string("history.quota.fixed_cycle"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let remaining = menuQuotaRemaining {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(remaining)%")
                            .font(.headline.monospacedDigit())
                        Text(L10n.string("quota.remaining"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let cycle = menuQuotaCycle {
                QuotaHistoryChart(series: cycle, showsAxes: false)
                    .frame(height: 92)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .foregroundStyle(HistoryPalette.accent)
                    Text(L10n.string("history.empty.message"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var menuTokenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("history.tokens.title"))
                        .font(.subheadline.weight(.semibold))
                    Text(TokenActivityRange.month.localizedName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !menuTokenPoints.isEmpty {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(compactToken(menuTokenTotal))
                            .font(.headline.monospacedDigit())
                        Text(L10n.string("history.tokens.total"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if menuTokenPoints.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.fill")
                        .foregroundStyle(HistoryPalette.accent)
                    Text(historySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            } else {
                CompactTokenActivityChart(points: menuTokenPoints)
                    .frame(height: 92)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var menuQuotaCycle: QuotaHistorySeries? {
        let weeklyWindows = history.quotaWindows.filter(\.isWeekly)
        let window = weeklyWindows.first ?? history.quotaWindows.max {
            ($0.windowDurationMins ?? 0) < ($1.windowDurationMins ?? 0)
        }
        guard let window else { return nil }

        let samples = history.quotaSamples.filter { $0.windowID == window.id }
        guard let cycle = QuotaHistorySeries.makeCurrentCycle(
            samples: samples,
            window: window,
            now: Date()
        ), !cycle.samples.isEmpty else {
            return nil
        }
        return cycle
    }

    private var menuQuotaRemaining: Int? {
        menuQuotaCycle?.samples.last?.remainingPercent
    }

    private func openHistoryWindow() {
        openWindow(id: CodexMeterWindowID.history)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var menuTokenPoints: [TokenChartPoint] {
        TokenChartData.filtered(
            TokenChartData.points(from: history.tokenUsage ?? service.tokenUsage),
            range: .month,
            now: Date()
        )
    }

    private var menuTokenTotal: Int64 {
        menuTokenPoints.reduce(0) { partial, point in
            let (sum, overflow) = partial.addingReportingOverflow(point.tokens)
            return overflow ? Int64.max : sum
        }
    }

    private func compactToken(_ value: Int64) -> String {
        CompactTokenFormatter.string(value, locale: L10n.locale)
    }

    private var historySummary: String {
        if let lifetime = service.tokenUsage?.summary.lifetimeTokens {
            return L10n.format(
                "history.summary.tokens_format",
                CompactTokenFormatter.string(lifetime, locale: L10n.locale)
            )
        }
        return L10n.string("history.summary.local")
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

/// Keeps the disclosure animation local so quota rows are not invalidated on every frame.
private struct SettingsSection: View {
    @ObservedObject var service: CodexUsageService
    @ObservedObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    @State private var isExpanded = false

    private let disclosureAnimation = Animation.easeInOut(duration: 0.18)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(disclosureAnimation) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: "gearshape")
                    Text(L10n.string("settings.title"))
                    Spacer()
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("settings.title"))
            .accessibilityValue(
                isExpanded
                    ? L10n.string("accessibility.expanded")
                    : L10n.string("accessibility.collapsed")
            )

            if isExpanded {
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

                    Button {
                        openWindow(id: CodexMeterWindowID.developerOptions)
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    } label: {
                        HStack {
                            Label(L10n.string("developer.title"), systemImage: "hammer")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.plain)

                    Button {
                        openWindow(id: CodexMeterWindowID.about)
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    } label: {
                        HStack {
                            Label(L10n.string("about.title"), systemImage: "info.circle")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 10)
                .padding(.leading, 17)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .clipped()
    }
}

/// Displays quota and time on the same 0...100 scale for direct comparison.
private struct UsageWindowRow: View {
    let window: CodexUsageWindow
    let now: Date
    let appearance: MenuBarAppearance
    @Environment(\.colorScheme) private var colorScheme

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
                tint: appearance.timeColor.swiftUIColor(for: colorScheme),
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
        .padding(.vertical, 4)
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
        case .normal: appearance.normalColor.swiftUIColor(for: colorScheme)
        case .warning: appearance.warningColor.swiftUIColor(for: colorScheme)
        case .critical: appearance.criticalColor.swiftUIColor(for: colorScheme)
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
