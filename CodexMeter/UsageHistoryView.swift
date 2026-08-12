import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct UsageHistoryView: View {
    @ObservedObject var service: CodexUsageService
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: UsageHistoryModel
    @State private var selectedWindowID: String?
    @State private var quotaMode: QuotaHistoryMode = .currentCycle
    @State private var calendarPeriod: QuotaCalendarPeriod = .week
    @State private var calendarOffset = 0
    @State private var calendarQuotaSamples: [QuotaHistorySample] = []
    @State private var oldestQuotaSampleDate: Date?
    @State private var isLoadingCalendarQuota = false
    @State private var tokenRange: TokenActivityRange = .month
    @State private var showsClearConfirmation = false
    @State private var actionError: String?

    var body: some View {
        ZStack {
            HistoryBackdrop()
            historyContent
        }
        .frame(
            minWidth: 700,
            idealWidth: 900,
            maxWidth: .infinity,
            minHeight: 600,
            idealHeight: 820,
            maxHeight: .infinity
        )
        .background(HistoryWindowConfigurator(title: L10n.string("history.title")))
        .task(id: loadIdentifier) {
            await history.load()
            let availableIDs = Set(selectableWindows.map(\.id))
            if selectedWindowID == nil || !availableIDs.contains(selectedWindowID ?? "") {
                selectedWindowID = preferredWindow?.id
            }
        }
        .task(id: calendarLoadIdentifier) {
            await loadCalendarQuotaIfNeeded()
        }
        .alert(L10n.string("history.clear.title"), isPresented: $showsClearConfirmation) {
            Button(L10n.string("action.cancel"), role: .cancel) {}
            Button(L10n.string("history.clear.confirm"), role: .destructive) {
                Task { await history.clearAll() }
            }
        } message: {
            Text(L10n.string("history.clear.message"))
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if #available(macOS 26.0, *) {
            historyScrollView
                .safeAreaBar(edge: .top, spacing: 0) {
                    header
                }
        } else {
            historyScrollView
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        header
                        Divider().opacity(0.45)
                    }
                    .background(.ultraThinMaterial)
                }
        }
    }

    private var historyScrollView: some View {
        ScrollView {
            cardStack
                .padding(.horizontal, 22)
                .padding(.top, 14)
                .padding(.bottom, 24)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("history.title"))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(L10n.string("history.summary.local"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if history.isLoading {
                ProgressView().controlSize(.small)
            }

        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var cardStack: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 18) {
                cards
            }
        } else {
            cards
        }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 18) {
            weeklyQuotaCard
            tokenActivityCard
            storageCard

            if let error = history.errorMessage ?? actionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var weeklyQuotaCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("history.quota.title"))
                        .font(.title3.weight(.bold))
                    Text(quotaRangeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if selectableWindows.count > 1 {
                    Picker(L10n.string("history.window"), selection: $selectedWindowID) {
                        ForEach(selectableWindows) { window in
                            Text(window.name).tag(Optional(window.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 210)
                } else if let window = selectedWindow {
                    Text(window.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            HistoryRangePicker(
                options: QuotaHistoryMode.allCases,
                selection: $quotaMode,
                title: { $0.localizedName }
            )

            quotaRangeControls

            if let series = quotaSeries {
                HStack(alignment: .lastTextBaseline, spacing: 18) {
                    MetricHeadline(
                        title: L10n.string("quota.remaining"),
                        value: latestRemaining.map { "\($0)%" } ?? "—",
                        tint: HistoryPalette.accentBright
                    )

                    if quotaMode != .currentCycle,
                       let consumption = observedQuotaConsumption {
                        MetricHeadline(
                            title: L10n.string("history.quota.observed_consumed"),
                            value: observedConsumptionText(consumption),
                            tint: .primary
                        )
                        .help(consumption.isLowerBound
                            ? L10n.string("history.quota.observed_lower_bound_help")
                            : L10n.string("history.quota.observed_complete_help"))
                    }

                    if quotaMode == .currentCycle, let reset = selectedWindow?.resetsAt {
                        MetricHeadline(
                            title: L10n.string("history.cycle.resets_in"),
                            value: L10n.remainingDuration(until: reset, from: Date()),
                            tint: .primary
                        )
                    }

                    Spacer()
                }

                QuotaHistoryChart(series: series)
                    .frame(height: 270)

                HStack(spacing: 16) {
                    Label(L10n.string("history.legend.actual"), systemImage: "waveform.path")
                        .foregroundStyle(HistoryPalette.accentBright)
                    Label(L10n.string("history.legend.ideal"), systemImage: "line.diagonal")
                        .foregroundStyle(.secondary)
                    if !series.gaps.isEmpty {
                        Label(L10n.string("history.legend.gap"), systemImage: "rectangle.inset.filled")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)

                if quotaMode == .currentCycle {
                    estimateView(samples: currentCycle?.samples ?? [])
                }
            } else if isLoadingCalendarQuota {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                EmptyHistoryView(
                    icon: "chart.xyaxis.line",
                    title: L10n.string("history.empty.title"),
                    message: L10n.string("history.empty.message")
                )
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .historyGlassCard()
    }

    @ViewBuilder
    private var quotaRangeControls: some View {
        switch quotaMode {
        case .browse:
            HStack(alignment: .center, spacing: 12) {
                HistoryRangePicker(
                    options: QuotaCalendarPeriod.allCases,
                    selection: Binding(
                        get: { calendarPeriod },
                        set: { period in
                            calendarPeriod = period
                            calendarOffset = 0
                        }
                    ),
                    title: { $0.localizedName }
                )

                CalendarPeriodNavigator(
                    title: calendarInterval.map {
                        L10n.formattedCalendarInterval($0, period: calendarPeriod)
                    } ?? "—",
                    returnTitle: calendarPeriod == .week
                        ? L10n.string("history.quota.calendar.current_week")
                        : L10n.string("history.quota.calendar.current_month"),
                    canNavigateBackward: canNavigateCalendarBackward,
                    canNavigateForward: calendarOffset < 0,
                    showsReturn: calendarOffset != 0,
                    navigateBackward: { calendarOffset -= 1 },
                    navigateForward: { calendarOffset += 1 },
                    returnToCurrent: { calendarOffset = 0 }
                )
            }
        case .currentCycle, .sevenDays, .fourteenDays, .month:
            EmptyView()
        }
    }

    @ViewBuilder
    private func estimateView(samples: [QuotaHistorySample]) -> some View {
        if let estimate = QuotaExhaustionEstimate.calculate(samples: samples, now: Date()) {
            Label(
                L10n.format(
                    "history.estimate.format",
                    L10n.formattedDateTime(estimate.exhaustedAt),
                    L10n.formattedTime(estimate.calculatedAt)
                ),
                systemImage: "waveform.path.ecg"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        } else {
            Label(L10n.string("history.estimate.unavailable"), systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tokenActivityCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("history.tokens.title"))
                        .font(.title3.weight(.bold))
                    Text(L10n.string("history.tokens.local_help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HistoryRangePicker(
                options: TokenActivityRange.allCases,
                selection: $tokenRange,
                title: { $0.localizedName }
            )

            if service.isTokenUsageUnavailable && tokenSnapshot == nil {
                EmptyHistoryView(
                    icon: "chart.bar.fill",
                    title: L10n.string("history.tokens.unavailable"),
                    message: service.tokenUsageErrorMessage
                        ?? L10n.string("history.tokens.unavailable_help")
                )
            } else if tokenPoints.isEmpty {
                EmptyHistoryView(
                    icon: "chart.bar.fill",
                    title: L10n.string("history.tokens.no_daily"),
                    message: L10n.string("history.tokens.unavailable_help")
                )
            } else {
                HStack(spacing: 28) {
                    MetricHeadline(
                        title: tokenRange.localizedName,
                        value: compactToken(selectedTokenTotal),
                        tint: HistoryPalette.accentBright
                    )
                    MetricHeadline(
                        title: L10n.string("history.tokens.latest"),
                        value: compactToken(tokenPoints.last?.tokens),
                        tint: .primary
                    )
                    MetricHeadline(
                        title: L10n.string("history.tokens.peak_period"),
                        value: compactToken(tokenPoints.map(\.tokens).max()),
                        tint: .primary
                    )
                    Spacer()
                }

                CompactTokenActivityChart(
                    points: tokenPoints,
                    showsAxes: true,
                    granularity: tokenRange.chartGranularity,
                    isInteractive: true
                )
                    .frame(height: 220)

                if let summary = tokenSnapshot?.summary {
                    tokenSummary(summary)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .historyGlassCard()
    }

    private func tokenSummary(_ summary: TokenUsageSummary) -> some View {
        HStack(spacing: 10) {
            SummaryPill(
                title: L10n.string("history.tokens.lifetime"),
                value: compactToken(summary.lifetimeTokens)
            )
            SummaryPill(
                title: L10n.string("history.tokens.current_streak"),
                value: formattedDays(summary.currentStreakDays)
            )
            SummaryPill(
                title: L10n.string("history.tokens.longest_streak"),
                value: formattedDays(summary.longestStreakDays)
            )
            SummaryPill(
                title: L10n.string("history.tokens.longest_turn"),
                value: formattedDuration(summary.longestRunningTurnSeconds)
            )
        }
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("history.storage.title"))
                .font(.headline)

            HStack {
                Picker(L10n.string("history.retention"), selection: $settings.historyRetention) {
                    ForEach(HistoryRetention.allCases) { retention in
                        Text(retention.localizedName).tag(retention)
                    }
                }
                .onChange(of: settings.historyRetention) { retention in
                    Task { await history.applyRetention(retention) }
                }

                Spacer()

                Text(ByteCountFormatter.string(
                    fromByteCount: history.storageSize,
                    countStyle: .file
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button(L10n.string("history.export")) { exportHistory() }
                Button(L10n.string("history.clear"), role: .destructive) {
                    showsClearConfirmation = true
                }
                Spacer()
            }

            Text(L10n.string("history.storage.privacy"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .historyGlassCard()
    }

    private var selectableWindows: [QuotaHistoryWindow] {
        history.quotaWindows
    }

    private var preferredWindow: QuotaHistoryWindow? {
        selectableWindows.first(where: \.isWeekly)
            ?? selectableWindows.max {
                ($0.windowDurationMins ?? 0) < ($1.windowDurationMins ?? 0)
            }
    }

    private var selectedWindow: QuotaHistoryWindow? {
        selectableWindows.first(where: { $0.id == selectedWindowID }) ?? preferredWindow
    }

    private var currentCycle: QuotaHistorySeries? {
        guard let selectedWindow else { return nil }
        return QuotaHistorySeries.makeCurrentCycle(
            samples: selectedQuotaSamples,
            window: selectedWindow,
            now: Date()
        )
    }

    private var quotaSeries: QuotaHistorySeries? {
        guard let selectedWindow else { return nil }
        if let range = quotaMode.historyRange {
            if range == .currentCycle {
                return currentCycle
            }
            return QuotaHistorySeries.makeHistorical(
                samples: selectedQuotaSamples,
                window: selectedWindow,
                range: range,
                now: Date()
            )
        }

        guard let calendarInterval else { return nil }
        return QuotaHistorySeries.makeHistorical(
            samples: calendarQuotaSamples,
            window: selectedWindow,
            interval: calendarInterval,
            range: calendarPeriod == .week ? .sevenDays : .month,
            usesLiveWindowReset: calendarInterval.contains(Date())
        )
    }

    private var quotaRangeDescription: String {
        if let range = quotaMode.historyRange {
            return range.localizedName
        }
        return calendarInterval.map {
            L10n.formattedCalendarInterval($0, period: calendarPeriod)
        } ?? calendarPeriod.localizedName
    }

    private var calendarInterval: DateInterval? {
        calendarPeriod.interval(
            offset: calendarOffset,
            containing: Date(),
            calendar: .autoupdatingCurrent
        )
    }

    private var canNavigateCalendarBackward: Bool {
        guard let oldestQuotaSampleDate, let calendarInterval else { return false }
        return oldestQuotaSampleDate < calendarInterval.start
    }

    private func loadCalendarQuotaIfNeeded() async {
        guard quotaMode == .browse,
              let selectedWindow,
              let calendarInterval else {
            calendarQuotaSamples = []
            oldestQuotaSampleDate = nil
            isLoadingCalendarQuota = false
            return
        }

        isLoadingCalendarQuota = true
        async let samples = history.quotaSamples(
            windowID: selectedWindow.id,
            interval: calendarInterval
        )
        async let oldest = history.oldestQuotaSampleDate(windowID: selectedWindow.id)
        let (loadedSamples, loadedOldest) = await (samples, oldest)
        guard !Task.isCancelled else { return }
        calendarQuotaSamples = loadedSamples
        oldestQuotaSampleDate = loadedOldest
        isLoadingCalendarQuota = false
    }

    private var selectedQuotaSamples: [QuotaHistorySample] {
        guard let selectedWindow else { return [] }
        return history.quotaSamples.filter { $0.windowID == selectedWindow.id }
    }

    private var latestRemaining: Int? {
        quotaSeries?.samples.last?.remainingPercent ?? quotaSeries?.points.last.map {
            Int($0.remainingPercent.rounded())
        }
    }

    private var observedQuotaConsumption: ObservedQuotaConsumption? {
        guard let selectedWindow, let series = quotaSeries else { return nil }
        let now = Date()
        let visibleEnd = min(series.end, now)
        guard series.start < visibleEnd else { return nil }
        let samples = quotaMode == .browse
            ? calendarQuotaSamples
            : selectedQuotaSamples
        return ObservedQuotaConsumption.calculate(
            samples: samples,
            window: selectedWindow,
            interval: DateInterval(start: series.start, end: visibleEnd),
            usesLiveWindowReset: quotaMode != .browse
                || calendarInterval?.contains(now) == true
        )
    }

    private func observedConsumptionText(_ consumption: ObservedQuotaConsumption) -> String {
        if consumption.isLowerBound {
            return L10n.format(
                "history.quota.observed_at_least_format",
                Int64(consumption.percent)
            )
        }
        return L10n.formattedInteger(Int64(consumption.percent)) + "%"
    }

    private var tokenSnapshot: TokenUsageSnapshot? {
        history.tokenUsage ?? service.tokenUsage
    }

    private var tokenPoints: [TokenChartPoint] {
        TokenChartData.displayPoints(
            TokenChartData.points(from: tokenSnapshot),
            range: tokenRange,
            now: Date()
        )
    }

    private var selectedTokenTotal: Int64 {
        tokenPoints.reduce(0) { partial, point in
            let (sum, overflow) = partial.addingReportingOverflow(point.tokens)
            return overflow ? Int64.max : sum
        }
    }

    private var loadIdentifier: String {
        String(history.dataRevision)
    }

    private var calendarLoadIdentifier: String {
        [
            quotaMode.rawValue,
            selectedWindowID ?? "none",
            calendarPeriod.rawValue,
            String(calendarOffset),
            String(history.dataRevision)
        ].joined(separator: ":")
    }

    private func compactToken(_ value: Int64?) -> String {
        value.map { CompactTokenFormatter.string($0, locale: L10n.locale) } ?? "—"
    }

    private func formattedDays(_ value: Int64?) -> String {
        value.map { L10n.format("history.days.format", $0) } ?? "—"
    }

    private func formattedDuration(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return L10n.compactDuration(seconds: value)
    }

    private func exportHistory() {
        Task {
            do {
                let data = try await history.exportCSV()
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.commaSeparatedText]
                panel.nameFieldStringValue = "CodexMeter-History.csv"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

private struct MetricHeadline: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }
}

private struct SummaryPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct HistoryRangePicker<Option: Identifiable & Equatable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    var body: some View {
        HStack(spacing: 5) {
            ForEach(options) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selection = option
                    }
                } label: {
                    Text(title(option))
                        .font(.caption.weight(selection == option ? .semibold : .regular))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background {
                            if selection == option {
                                Capsule().fill(HistoryPalette.accent.opacity(0.20))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == option ? HistoryPalette.accentBright : .secondary)
            }
        }
        .padding(4)
        .background(.secondary.opacity(0.08), in: Capsule())
    }
}

private struct CalendarPeriodNavigator: View {
    let title: String
    let returnTitle: String
    let canNavigateBackward: Bool
    let canNavigateForward: Bool
    let showsReturn: Bool
    let navigateBackward: () -> Void
    let navigateForward: () -> Void
    let returnToCurrent: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: navigateBackward) {
                Image(systemName: "chevron.left")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!canNavigateBackward)
            .help(L10n.string("history.quota.calendar.previous"))

            Text(title)
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .frame(minWidth: 155)

            Button(action: navigateForward) {
                Image(systemName: "chevron.right")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!canNavigateForward)
            .help(L10n.string("history.quota.calendar.next"))

            if showsReturn {
                Button(returnTitle, action: returnToCurrent)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HistoryPalette.accentBright)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.secondary.opacity(0.08), in: Capsule())
    }
}

private struct EmptyHistoryView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(HistoryPalette.accent)
            Text(title).font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }
}

private struct HistoryBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.black : Color(nsColor: .windowBackgroundColor))
            RadialGradient(
                colors: [HistoryPalette.accent.opacity(colorScheme == .dark ? 0.16 : 0.10), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 620
            )
        }
        .ignoresSafeArea()
    }
}

/// Configures the history scene as a content-integrated macOS window while
/// keeping the native traffic-light controls and full-screen behavior.
private struct HistoryWindowConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> WindowConfigurationView {
        WindowConfigurationView(title: title)
    }

    func updateNSView(_ nsView: WindowConfigurationView, context: Context) {
        nsView.configure(title: title)
    }

    final class WindowConfigurationView: NSView {
        private var currentTitle: String

        init(title: String) {
            currentTitle = title
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyConfiguration()
        }

        func configure(title: String) {
            currentTitle = title
            applyConfiguration()
        }

        private func applyConfiguration() {
            guard let window else { return }
            window.title = currentTitle
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert([.fullSizeContentView, .resizable])
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.zoomButton)?.isEnabled = true
        }
    }
}
