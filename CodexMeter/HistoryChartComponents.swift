import AppKit
import Charts
import SwiftUI

enum HistoryPalette {
    static let accent = Color(red: 0.22, green: 0.72, blue: 0.79)
    static let accentBright = Color(red: 0.33, green: 0.82, blue: 0.88)
    static let warning = Color.orange
}

struct TokenChartPoint: Identifiable, Equatable {
    let date: Date
    let tokens: Int64

    var id: Date { date }
}

struct QuotaHistoryChart: View {
    private struct IdealPoint: Identifiable {
        let date: Date
        let remainingPercent: Double

        var id: Date { date }
    }

    let cycle: WeeklyQuotaCycle
    var showsAxes = true

    var body: some View {
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

            ForEach(idealPoints) { point in
                LineMark(
                    x: .value(L10n.string("history.chart.time"), point.date),
                    y: .value(L10n.string("history.legend.ideal"), point.remainingPercent)
                )
                .foregroundStyle(.secondary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: showsAxes ? 1.25 : 1, dash: [5, 5]))
            }

            ForEach(cycle.points) { point in
                AreaMark(
                    x: .value(L10n.string("history.chart.time"), point.date),
                    y: .value(L10n.string("quota.remaining"), point.remainingPercent)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [HistoryPalette.accent.opacity(showsAxes ? 0.28 : 0.22), .clear],
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
                .lineStyle(StrokeStyle(
                    lineWidth: showsAxes ? 3 : 2.25,
                    lineCap: .round,
                    lineJoin: .round
                ))
            }

            if let latest = cycle.points.last {
                PointMark(
                    x: .value(L10n.string("history.chart.time"), latest.date),
                    y: .value(L10n.string("quota.remaining"), latest.remainingPercent)
                )
                .foregroundStyle(HistoryPalette.accentBright)
                .symbolSize(showsAxes ? 38 : 24)
            }
        }
        .chartXScale(domain: cycle.start...cycle.end)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            if showsAxes {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.weekday(.abbreviated))
                        }
                    }
                }
            }
        }
        .chartYAxis {
            if showsAxes {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.16))
                    AxisValueLabel {
                        if let percent = value.as(Double.self) {
                            Text("\(Int(percent.rounded()))%")
                        }
                    }
                }
            }
        }
        .accessibilityLabel(L10n.string("history.quota.title"))
    }

    private var idealPoints: [IdealPoint] {
        [
            IdealPoint(date: cycle.start, remainingPercent: 100),
            IdealPoint(date: cycle.end, remainingPercent: 0)
        ]
    }
}

extension TokenChartGranularity {
    func periodLabel(for date: Date) -> String {
        switch self {
        case .day:
            let formatter = DateFormatter()
            formatter.locale = L10n.locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        case .week:
            let formatter = DateIntervalFormatter()
            formatter.locale = L10n.locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(
                from: date,
                to: date.addingTimeInterval(6 * 24 * 60 * 60)
            )
        case .month:
            let formatter = DateFormatter()
            formatter.locale = L10n.locale
            formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
            return formatter.string(from: date)
        }
    }

    func axisLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        switch self {
        case .day, .week:
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("MMMyy")
        }
        return formatter.string(from: date)
    }
}

enum TokenChartData {
    static func points(from snapshot: TokenUsageSnapshot?) -> [TokenChartPoint] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        return snapshot?.dailyBuckets?.compactMap { bucket in
            guard let date = formatter.date(from: bucket.startDate) else { return nil }
            return TokenChartPoint(date: date, tokens: bucket.tokens)
        }.sorted { $0.date < $1.date } ?? []
    }

    static func filtered(
        _ points: [TokenChartPoint],
        range: TokenActivityRange,
        now: Date
    ) -> [TokenChartPoint] {
        points.filter { range.includes($0.date, now: now) }
    }

    static func displayPoints(
        _ points: [TokenChartPoint],
        range: TokenActivityRange,
        now: Date
    ) -> [TokenChartPoint] {
        let filteredPoints = filtered(points, range: range, now: now)
        switch range {
        case .week, .month, .threeMonths:
            return filteredPoints
        case .year:
            return aggregate(filteredPoints, component: .weekOfYear)
        case .all:
            return aggregate(filteredPoints, component: .month)
        }
    }

    private static func aggregate(
        _ points: [TokenChartPoint],
        component: Calendar.Component
    ) -> [TokenChartPoint] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let grouped = Dictionary(grouping: points) { point -> Date in
            calendar.dateInterval(of: component, for: point.date)?.start ?? point.date
        }

        return grouped.map { date, values in
            let total = values.reduce(Int64.zero) { partial, point in
                let (sum, overflow) = partial.addingReportingOverflow(point.tokens)
                return overflow ? Int64.max : sum
            }
            return TokenChartPoint(date: date, tokens: total)
        }.sorted { $0.date < $1.date }
    }
}

struct CompactTokenActivityChart: View {
    let points: [TokenChartPoint]
    var showsAxes = false
    var granularity: TokenChartGranularity = .day
    var isInteractive = false

    @State private var selectedPoint: TokenChartPoint?

    var body: some View {
        Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value(
                        L10n.string("history.tokens.date"),
                        point.date,
                        unit: granularity.calendarComponent
                    ),
                    y: .value(L10n.string("history.tokens.count"), point.tokens)
                )
                .cornerRadius(3)
                .foregroundStyle(
                    LinearGradient(
                        colors: [HistoryPalette.accentBright, HistoryPalette.accent],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .chartYAxis {
            if showsAxes {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.16))
                    AxisValueLabel {
                        if let tokenValue = value.as(Int64.self) {
                            Text(CompactTokenFormatter.string(tokenValue, locale: L10n.locale))
                        }
                    }
                }
            }
        }
        .chartXAxis {
            if showsAxes {
                AxisMarks(values: axisDates) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(granularity.axisLabel(for: date))
                        }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if isInteractive {
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    updateSelection(
                                        at: location,
                                        proxy: proxy,
                                        geometry: geometry
                                    )
                                case .ended:
                                    selectedPoint = nil
                                }
                            }

                        if let selectedPoint,
                           let overlayLayout = overlayLayout(
                               for: selectedPoint,
                               proxy: proxy,
                               geometry: geometry
                           ) {
                            Path { path in
                                path.move(
                                    to: CGPoint(
                                        x: overlayLayout.ruleX,
                                        y: overlayLayout.plotFrame.minY
                                    )
                                )
                                path.addLine(
                                    to: CGPoint(
                                        x: overlayLayout.ruleX,
                                        y: overlayLayout.plotFrame.maxY
                                    )
                                )
                            }
                            .stroke(
                                HistoryPalette.accentBright.opacity(0.72),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                            )
                            .allowsHitTesting(false)

                            TokenChartTooltip(
                                period: granularity.periodLabel(for: selectedPoint.date),
                                tokens: CompactTokenFormatter.string(
                                    selectedPoint.tokens,
                                    locale: L10n.locale
                                )
                            )
                            .frame(width: Self.tooltipWidth)
                            .position(overlayLayout.tooltipPosition)
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
        .accessibilityLabel(L10n.string("history.tokens.title"))
    }

    private func updateSelection(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        let plotFrame = geometry[proxy.plotAreaFrame]
        guard plotFrame.contains(location) else {
            selectedPoint = nil
            return
        }

        let localX = location.x - plotFrame.minX
        selectedPoint = points.compactMap { point -> (TokenChartPoint, CGFloat)? in
            guard let centerX = barCenterX(for: point, proxy: proxy) else { return nil }
            return (point, centerX)
        }
        .min { abs($0.1 - localX) < abs($1.1 - localX) }?
        .0
    }

    private var axisDates: [Date] {
        let plottedDates = points.map(\.date)
        guard plottedDates.count > 7 else { return plottedDates }

        let step = max(1, Int(ceil(Double(plottedDates.count) / 7.0)))
        var values = stride(from: 0, to: plottedDates.count, by: step).map { plottedDates[$0] }
        if let last = plottedDates.last,
           values.last.map({ abs($0.timeIntervalSince(last)) > 1 }) != false {
            values.append(last)
        }
        return values
    }

    private static let tooltipWidth: CGFloat = 176

    private struct OverlayLayout {
        let ruleX: CGFloat
        let tooltipPosition: CGPoint
        let plotFrame: CGRect
    }

    /// Resolves the mark's real plotted position. Passing the original value is
    /// important because Swift Charts applies the temporal unit when placing the
    /// bar; manually adding half a day/week/month shifts the rule off its center.
    private func barCenterX(
        for point: TokenChartPoint,
        proxy: ChartProxy
    ) -> CGFloat? {
        if let range = proxy.positionRange(forX: point.date) {
            return (range.lowerBound + range.upperBound) / 2
        }
        return proxy.position(forX: point.date)
    }

    private func overlayLayout(
        for point: TokenChartPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> OverlayLayout? {
        let plotFrame = geometry[proxy.plotAreaFrame]
        guard let relativeX = barCenterX(for: point, proxy: proxy) else {
            return nil
        }

        let ruleX = plotFrame.minX + relativeX
        let tooltipX = TokenTooltipLayout.clampedCenter(
            desiredX: Double(ruleX),
            lowerBound: Double(plotFrame.minX),
            upperBound: Double(plotFrame.maxX),
            width: Double(Self.tooltipWidth)
        )
        return OverlayLayout(
            ruleX: ruleX,
            tooltipPosition: CGPoint(x: CGFloat(tooltipX), y: plotFrame.minY + 31),
            plotFrame: plotFrame
        )
    }
}

private struct TokenChartTooltip: View {
    let period: String
    let tokens: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(period)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(tokens)
                    .font(.headline.monospacedDigit())
                Text(L10n.string("history.tokens.total"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // Keep the hover surface out of the Liquid Glass composition. A nested
        // material changes the glass sampling region every time the pointer moves.
        .background(
            Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.primary.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }
}

extension View {
    /// Uses native Liquid Glass on macOS 26 while preserving the same modern
    /// layout with a material fallback on earlier supported systems.
    @ViewBuilder
    func historyGlassCard(cornerRadius: CGFloat = 22, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                }
        }
    }
}
