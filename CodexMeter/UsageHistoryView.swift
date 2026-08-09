import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct UsageHistoryView: View {
    @ObservedObject var service: CodexUsageService
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: UsageHistoryModel
    @State private var selectedWindowID: String?
    @State private var tokenRange: TokenActivityRange = .month
    @State private var showsClearConfirmation = false
    @State private var actionError: String?

    var body: some View {
        ZStack {
            HistoryBackdrop()

            VStack(spacing: 0) {
                header

                ScrollView {
                    cardStack
                        .padding(.horizontal, 22)
                        .padding(.bottom, 24)
                }
            }
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
            await history.load(windowID: selectedWindowID)
            let availableIDs = Set(selectableWindows.map(\.id))
            if selectedWindowID == nil || !availableIDs.contains(selectedWindowID ?? "") {
                selectedWindowID = preferredWindow?.id
            }
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
        .padding(.bottom, 18)
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
                    Text(L10n.string("history.quota.fixed_cycle"))
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

            if let cycle = weeklyCycle {
                HStack(alignment: .lastTextBaseline, spacing: 18) {
                    MetricHeadline(
                        title: L10n.string("quota.remaining"),
                        value: latestRemaining.map { "\($0)%" } ?? "—",
                        tint: HistoryPalette.accentBright
                    )

                    if let reset = selectedWindow?.resetsAt {
                        MetricHeadline(
                            title: L10n.string("history.cycle.resets_in"),
                            value: L10n.remainingDuration(until: reset, from: Date()),
                            tint: .primary
                        )
                    }

                    Spacer()
                }

                weeklyChart(cycle)
                    .frame(height: 270)

                HStack(spacing: 16) {
                    Label(L10n.string("history.legend.actual"), systemImage: "waveform.path")
                        .foregroundStyle(HistoryPalette.accentBright)
                    Label(L10n.string("history.legend.ideal"), systemImage: "line.diagonal")
                        .foregroundStyle(.secondary)
                    if !cycle.gaps.isEmpty {
                        Label(L10n.string("history.legend.gap"), systemImage: "rectangle.inset.filled")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)

                estimateView(samples: cycle.samples)
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

    private func weeklyChart(_ cycle: WeeklyQuotaCycle) -> some View {
        Chart {
            ForEach(cycle.gaps) { gap in
                RectangleMark(
                    xStart: .value(L10n.string("history.gap.start"), gap.start),
                    xEnd: .value(L10n.string("history.gap.end"), gap.end),
                    yStart: .value(L10n.string("history.chart.minimum"), 0),
                    yEnd: .value(L10n.string("history.chart.maximum"), 100)
                )
                .foregroundStyle(.secondary.opacity(0.10))
            }

            ForEach(idealPoints(for: cycle)) { point in
                LineMark(
                    x: .value(L10n.string("history.chart.time"), point.date),
                    y: .value(L10n.string("history.legend.ideal"), point.remainingPercent)
                )
                .foregroundStyle(.secondary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [5, 5]))
            }

            ForEach(cycle.points) { point in
                AreaMark(
                    x: .value(L10n.string("history.chart.time"), point.date),
                    y: .value(L10n.string("quota.remaining"), point.remainingPercent)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [HistoryPalette.accent.opacity(0.28), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value(L10n.string("history.chart.time"), point.date),
                    y: .value(L10n.string("quota.remaining"), point.remainingPercent)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(HistoryPalette.accentBright)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }

            if let latest = cycle.points.last {
                PointMark(
                    x: .value(L10n.string("history.chart.time"), latest.date),
                    y: .value(L10n.string("quota.remaining"), latest.remainingPercent)
                )
                .foregroundStyle(HistoryPalette.accentBright)
                .symbolSize(38)
            }
        }
        .chartXScale(domain: cycle.start...cycle.end)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.weekday(.abbreviated))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.16))
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text("\(Int(percent.rounded()))%")
                    }
                }
            }
        }
        .accessibilityLabel(L10n.string("history.quota.title"))
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

            TokenRangePicker(selection: $tokenRange)

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
        let weekly = history.quotaWindows.filter(\.isWeekly)
        return weekly.isEmpty ? history.quotaWindows : weekly
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

    private var weeklyCycle: WeeklyQuotaCycle? {
        guard let selectedWindow else { return nil }
        return WeeklyQuotaCycle.make(
            samples: history.quotaSamples,
            window: selectedWindow,
            now: Date()
        )
    }

    private var latestRemaining: Int? {
        weeklyCycle?.samples.last?.remainingPercent ?? weeklyCycle?.points.last.map {
            Int($0.remainingPercent.rounded())
        }
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
        "\(selectedWindowID ?? "weekly")-\(history.dataRevision)"
    }

    private func idealPoints(for cycle: WeeklyQuotaCycle) -> [IdealQuotaPoint] {
        [
            IdealQuotaPoint(date: cycle.start, remainingPercent: 100),
            IdealQuotaPoint(date: cycle.end, remainingPercent: 0)
        ]
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

private struct IdealQuotaPoint: Identifiable {
    let date: Date
    let remainingPercent: Double

    var id: Date { date }
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

private struct TokenRangePicker: View {
    @Binding var selection: TokenActivityRange

    var body: some View {
        HStack(spacing: 5) {
            ForEach(TokenActivityRange.allCases) { range in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selection = range
                    }
                } label: {
                    Text(range.localizedName)
                        .font(.caption.weight(selection == range ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background {
                            if selection == range {
                                Capsule().fill(HistoryPalette.accent.opacity(0.20))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == range ? HistoryPalette.accentBright : .secondary)
            }
        }
        .padding(4)
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
