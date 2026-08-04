import SwiftUI

struct MenuBarProgressView: View {
    let remainingPercent: Int?
    let title: String
    let style: MenuBarDisplayStyle
    let isStale: Bool

    var body: some View {
        HStack(spacing: 4) {
            if style != .percentageOnly {
                progressSymbol
            }

            if style != .progressOnly {
                Text(title)
                    .monospacedDigit()
            }

            if isStale {
                Image(systemName: "exclamationmark.circle.fill")
                    .imageScale(.small)
            }
        }
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var progressSymbol: some View {
        if let remainingPercent {
            ZStack {
                Circle()
                    .stroke(lineWidth: 2)
                    .opacity(0.25)
                Circle()
                    .trim(from: 0, to: Double(remainingPercent) / 100)
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
        } else {
            Image(systemName: "gauge")
                .frame(width: 13, height: 13)
        }
    }

    private var accessibilityText: String {
        guard let remainingPercent else { return L10n.string("menubar.unavailable") }
        let quota = L10n.format("menubar.remaining_format", remainingPercent)
        return isStale ? "\(quota), \(L10n.string("data.stale"))" : quota
    }
}
