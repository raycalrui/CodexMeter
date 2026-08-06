import Foundation

enum MenuBarDisplayStyle: String, CaseIterable, Codable, Identifiable {
    case progressAndPercentage
    case horizontalBarBesidePercentage
    case compactBarBelowPercentage
    case dualBars
    case percentageOnly
    case progressOnly

    var id: String { rawValue }
}

enum MenuBarFontWeightChoice: String, CaseIterable, Codable, Identifiable {
    case regular
    case medium
    case semibold
    case bold

    var id: String { rawValue }
}

enum MenuBarColorChoice: String, CaseIterable, Codable, Identifiable {
    case system
    case blue
    case teal
    case green
    case yellow
    case orange
    case red
    case pink
    case purple
    case white

    var id: String { rawValue }
}

enum StaleIndicatorPlacement: String, CaseIterable, Codable, Identifiable {
    case leading
    case trailing

    var id: String { rawValue }
}

/// Experimental values are clamped before rendering so a malformed preference
/// cannot produce an unusable or excessively large menu bar item.
struct MenuBarAppearance: Codable, Equatable {
    var percentageFontSize = 10.5
    var percentageFontWeight = MenuBarFontWeightChoice.semibold
    var percentageVerticalOffset = 0.0

    var captionText = "Codex"
    var showsCaption = true
    var captionFontSize = 6.5
    var captionFontWeight = MenuBarFontWeightChoice.medium
    var captionColor = MenuBarColorChoice.system
    var captionVerticalOffset = 0.0

    var itemHeight = 20.0
    var ringDiameter = 18.0
    var outerRingStrokeWidth = 2.7
    var innerRingStrokeWidth = 2.2
    var ringGap = 0.3
    var ringStartAngle = 90.0
    var trackOpacity = 0.22
    var indicatorTextSpacing = 2.0
    var horizontalPadding = 1.0
    var textWidth = 40.0
    var barWidth = 26.0
    var barHeight = 3.0

    var normalColor = MenuBarColorChoice.system
    var warningColor = MenuBarColorChoice.yellow
    var criticalColor = MenuBarColorChoice.red
    var timeColor = MenuBarColorChoice.blue
    var staleColor = MenuBarColorChoice.orange

    var showsStaleIndicator = true
    var staleIndicatorSize = 10.0
    var staleIndicatorPlacement = StaleIndicatorPlacement.trailing

    static let acceptedV1 = MenuBarAppearance()

    func normalized() -> MenuBarAppearance {
        var result = self
        result.percentageFontSize = result.percentageFontSize.clamped(to: 8...14)
        result.percentageVerticalOffset = result.percentageVerticalOffset.clamped(to: -4...4)
        result.captionText = String(result.captionText.prefix(24))
        result.captionFontSize = result.captionFontSize.clamped(to: 5...10)
        result.captionVerticalOffset = result.captionVerticalOffset.clamped(to: -4...4)
        result.itemHeight = result.itemHeight.clamped(to: 18...24)
        result.ringDiameter = result.ringDiameter.clamped(to: 12...20)
        result.outerRingStrokeWidth = result.outerRingStrokeWidth.clamped(to: 1...5)
        result.innerRingStrokeWidth = result.innerRingStrokeWidth.clamped(to: 1...4)
        result.ringGap = result.ringGap.clamped(to: 0...3)
        result.ringStartAngle = result.ringStartAngle.clamped(to: 0...360)
        result.trackOpacity = result.trackOpacity.clamped(to: 0.05...0.5)
        result.indicatorTextSpacing = result.indicatorTextSpacing.clamped(to: 0...8)
        result.horizontalPadding = result.horizontalPadding.clamped(to: 0...6)
        result.textWidth = result.textWidth.clamped(to: 24...56)
        result.barWidth = result.barWidth.clamped(to: 16...40)
        result.barHeight = result.barHeight.clamped(to: 2...6)
        result.staleIndicatorSize = result.staleIndicatorSize.clamped(to: 7...14)
        return result
    }
}

enum DeveloperPreviewPreset: String, CaseIterable, Codable, Identifiable {
    case custom
    case normal
    case warning
    case critical
    case zero
    case stale
    case missingReset
    case longText

    var id: String { rawValue }

    var snapshot: MenuBarPreviewSnapshot {
        switch self {
        case .custom:
            .custom(remainingPercent: 72, remainingTimePercent: 55)
        case .normal:
            MenuBarPreviewSnapshot(
                remainingPercent: 72,
                remainingTimePercent: 55,
                title: "72%",
                attentionLevel: .normal,
                isStale: false
            )
        case .warning:
            MenuBarPreviewSnapshot(
                remainingPercent: 38,
                remainingTimePercent: 62,
                title: "38%",
                attentionLevel: .warning,
                isStale: false
            )
        case .critical:
            MenuBarPreviewSnapshot(
                remainingPercent: 12,
                remainingTimePercent: 30,
                title: "12%",
                attentionLevel: .critical,
                isStale: false
            )
        case .zero:
            MenuBarPreviewSnapshot(
                remainingPercent: 0,
                remainingTimePercent: 18,
                title: "0%",
                attentionLevel: .critical,
                isStale: false
            )
        case .stale:
            MenuBarPreviewSnapshot(
                remainingPercent: 64,
                remainingTimePercent: 48,
                title: "64%",
                attentionLevel: .normal,
                isStale: true
            )
        case .missingReset:
            MenuBarPreviewSnapshot(
                remainingPercent: 56,
                remainingTimePercent: nil,
                title: "56%",
                attentionLevel: .normal,
                isStale: false
            )
        case .longText:
            MenuBarPreviewSnapshot(
                remainingPercent: 100,
                remainingTimePercent: 100,
                title: "100% REMAINING",
                attentionLevel: .normal,
                isStale: false
            )
        }
    }
}

struct MenuBarPreviewSnapshot: Equatable {
    let remainingPercent: Int?
    let remainingTimePercent: Double?
    let title: String
    let attentionLevel: QuotaAttentionLevel
    let isStale: Bool

    static func custom(
        remainingPercent: Double,
        remainingTimePercent: Double
    ) -> MenuBarPreviewSnapshot {
        let quota = Int(remainingPercent.clamped(to: 0...100).rounded())
        let time = remainingTimePercent.clamped(to: 0...100)
        let attentionLevel: QuotaAttentionLevel

        if quota < 20 {
            attentionLevel = .critical
        } else if Double(quota) < time {
            attentionLevel = .warning
        } else {
            attentionLevel = .normal
        }

        return MenuBarPreviewSnapshot(
            remainingPercent: quota,
            remainingTimePercent: time,
            title: "\(quota)%",
            attentionLevel: attentionLevel,
            isStale: false
        )
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
