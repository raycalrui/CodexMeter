import AppKit
import SwiftUI

/// Renders a compact status item without nested SwiftUI layout containers.
/// AppKit drawing keeps the menu bar dimensions stable across macOS releases.
struct MenuBarProgressView: View {
    let remainingPercent: Int?
    let remainingTimePercent: Double?
    let title: String
    let style: MenuBarDisplayStyle
    let attentionLevel: QuotaAttentionLevel
    let isStale: Bool
    let appearance: MenuBarAppearance

    var body: some View {
        Image(nsImage: statusImage)
            .renderingMode(.original)
            .accessibilityLabel(accessibilityText)
    }

    private var normalizedAppearance: MenuBarAppearance {
        appearance.normalized()
    }

    private var staleWidth: CGFloat {
        guard isStale, normalizedAppearance.showsStaleIndicator else { return 0 }
        return CGFloat(normalizedAppearance.staleIndicatorSize + 3)
    }

    private var imageSize: NSSize {
        let appearance = normalizedAppearance
        let padding = CGFloat(appearance.horizontalPadding * 2)
        let spacing = CGFloat(appearance.indicatorTextSpacing)
        let ring = CGFloat(appearance.ringDiameter)
        let text = CGFloat(appearance.textWidth)
        let bar = CGFloat(appearance.barWidth)
        let contentWidth: CGFloat

        switch style {
        case .progressAndPercentage:
            contentWidth = ring + spacing + text
        case .horizontalBarBesidePercentage, .dualBars:
            contentWidth = bar + spacing + text
        case .compactBarBelowPercentage, .percentageOnly:
            contentWidth = text
        case .progressOnly:
            contentWidth = ring
        }

        return NSSize(
            width: ceil(contentWidth + padding + staleWidth),
            height: CGFloat(appearance.itemHeight)
        )
    }

    private var statusImage: NSImage {
        let appearance = normalizedAppearance
        let size = imageSize
        let image = NSImage(size: size, flipped: false) { rect in
            let leadingStaleWidth = isStale
                && appearance.showsStaleIndicator
                && appearance.staleIndicatorPlacement == .leading ? staleWidth : 0
            var cursorX = CGFloat(appearance.horizontalPadding) + leadingStaleWidth
            let centerY = rect.midY

            switch style {
            case .progressAndPercentage:
                let diameter = CGFloat(appearance.ringDiameter)
                drawProgressRings(
                    in: NSRect(
                        x: cursorX,
                        y: centerY - diameter / 2,
                        width: diameter,
                        height: diameter
                    ),
                    appearance: appearance
                )
                cursorX += diameter + CGFloat(appearance.indicatorTextSpacing)
                drawPercentageAndCaption(
                    in: NSRect(
                        x: cursorX,
                        y: 0,
                        width: CGFloat(appearance.textWidth),
                        height: rect.height
                    ),
                    appearance: appearance
                )

            case .horizontalBarBesidePercentage:
                let barHeight = CGFloat(appearance.barHeight)
                drawProgressBar(
                    value: remainingPercent.map(Double.init),
                    color: attentionColor(appearance: appearance),
                    in: NSRect(
                        x: cursorX,
                        y: centerY - barHeight / 2,
                        width: CGFloat(appearance.barWidth),
                        height: barHeight
                    ),
                    trackOpacity: appearance.trackOpacity
                )
                cursorX += CGFloat(appearance.barWidth + appearance.indicatorTextSpacing)
                drawSingleLineTitle(
                    in: NSRect(
                        x: cursorX,
                        y: 0,
                        width: CGFloat(appearance.textWidth),
                        height: rect.height
                    ),
                    appearance: appearance
                )

            case .compactBarBelowPercentage:
                let textRect = NSRect(
                    x: cursorX,
                    y: CGFloat(appearance.barHeight + 2),
                    width: CGFloat(appearance.textWidth),
                    height: rect.height - CGFloat(appearance.barHeight + 2)
                )
                drawSingleLineTitle(in: textRect, appearance: appearance)
                drawProgressBar(
                    value: remainingPercent.map(Double.init),
                    color: attentionColor(appearance: appearance),
                    in: NSRect(
                        x: cursorX,
                        y: 1,
                        width: CGFloat(appearance.textWidth),
                        height: CGFloat(appearance.barHeight)
                    ),
                    trackOpacity: appearance.trackOpacity
                )

            case .dualBars:
                let barHeight = CGFloat(appearance.barHeight)
                let gap: CGFloat = 3
                let totalHeight = barHeight * 2 + gap
                let barX = cursorX
                let barWidth = CGFloat(appearance.barWidth)
                drawProgressBar(
                    value: remainingPercent.map(Double.init),
                    color: attentionColor(appearance: appearance),
                    in: NSRect(
                        x: barX,
                        y: centerY + gap / 2,
                        width: barWidth,
                        height: barHeight
                    ),
                    trackOpacity: appearance.trackOpacity
                )
                drawProgressBar(
                    value: remainingTimePercent,
                    color: appearance.timeColor.nsColor,
                    in: NSRect(
                        x: barX,
                        y: centerY - totalHeight / 2,
                        width: barWidth,
                        height: barHeight
                    ),
                    trackOpacity: appearance.trackOpacity
                )
                cursorX += barWidth + CGFloat(appearance.indicatorTextSpacing)
                drawSingleLineTitle(
                    in: NSRect(
                        x: cursorX,
                        y: 0,
                        width: CGFloat(appearance.textWidth),
                        height: rect.height
                    ),
                    appearance: appearance
                )

            case .percentageOnly:
                drawPercentageAndCaption(
                    in: NSRect(
                        x: cursorX,
                        y: 0,
                        width: CGFloat(appearance.textWidth),
                        height: rect.height
                    ),
                    appearance: appearance
                )

            case .progressOnly:
                let diameter = CGFloat(appearance.ringDiameter)
                drawProgressRings(
                    in: NSRect(
                        x: cursorX,
                        y: centerY - diameter / 2,
                        width: diameter,
                        height: diameter
                    ),
                    appearance: appearance
                )
            }

            if isStale, appearance.showsStaleIndicator {
                drawStaleIndicator(in: rect, appearance: appearance)
            }
            return true
        }
        // Preserve quota and warning colors instead of applying template tinting.
        image.isTemplate = false
        return image
    }

    private func drawProgressRings(in rect: NSRect, appearance: MenuBarAppearance) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let outerWidth = CGFloat(appearance.outerRingStrokeWidth)
        let innerWidth = CGFloat(appearance.innerRingStrokeWidth)
        let outerRadius = max(1, min(rect.width, rect.height) / 2 - outerWidth / 2)
        let innerRadius = max(
            innerWidth / 2 + 0.5,
            outerRadius - outerWidth / 2 - CGFloat(appearance.ringGap) - innerWidth / 2
        )

        drawRing(
            center: center,
            radius: outerRadius,
            lineWidth: outerWidth,
            value: nil,
            color: NSColor.labelColor.withAlphaComponent(CGFloat(appearance.trackOpacity)),
            startAngle: appearance.ringStartAngle
        )

        guard let remainingPercent else {
            drawUnknown(in: rect)
            return
        }

        drawRing(
            center: center,
            radius: outerRadius,
            lineWidth: outerWidth,
            value: Double(remainingPercent),
            color: attentionColor(appearance: appearance),
            startAngle: appearance.ringStartAngle
        )

        // Omit the inner ring when reset timing is unavailable.
        guard let remainingTimePercent else { return }
        drawRing(
            center: center,
            radius: innerRadius,
            lineWidth: innerWidth,
            value: nil,
            color: appearance.timeColor.nsColor.withAlphaComponent(
                CGFloat(appearance.trackOpacity)
            ),
            startAngle: appearance.ringStartAngle
        )
        drawRing(
            center: center,
            radius: innerRadius,
            lineWidth: innerWidth,
            value: remainingTimePercent,
            color: appearance.timeColor.nsColor,
            startAngle: appearance.ringStartAngle
        )
    }

    private func drawRing(
        center: NSPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        value: Double?,
        color: NSColor,
        startAngle: Double
    ) {
        let path = NSBezierPath()
        if let value {
            let fraction = CGFloat(min(100, max(0, value))) / 100
            guard fraction > 0 else { return }
            path.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: CGFloat(startAngle),
                endAngle: CGFloat(startAngle) - 360 * fraction,
                clockwise: true
            )
            path.lineCapStyle = .round
        } else {
            path.appendOval(in: NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
        path.lineWidth = lineWidth
        color.setStroke()
        path.stroke()
    }

    private func drawProgressBar(
        value: Double?,
        color: NSColor,
        in rect: NSRect,
        trackOpacity: Double
    ) {
        let radius = rect.height / 2
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.labelColor.withAlphaComponent(CGFloat(trackOpacity)).setFill()
        track.fill()

        guard let value else {
            drawUnknown(in: NSRect(x: rect.midX - 5, y: rect.midY - 6, width: 10, height: 12))
            return
        }
        let fraction = CGFloat(min(100, max(0, value))) / 100
        guard fraction > 0 else { return }

        let progressRect = NSRect(
            x: rect.minX,
            y: rect.minY,
            width: max(rect.height, rect.width * fraction),
            height: rect.height
        )
        let progress = NSBezierPath(roundedRect: progressRect, xRadius: radius, yRadius: radius)
        color.setFill()
        progress.fill()
    }

    private func drawPercentageAndCaption(in rect: NSRect, appearance: MenuBarAppearance) {
        let shouldDrawCaption = appearance.showsCaption && !appearance.captionText.isEmpty
        if shouldDrawCaption {
            drawText(
                title,
                in: NSRect(
                    x: rect.minX,
                    y: rect.height - 12 + CGFloat(appearance.percentageVerticalOffset),
                    width: rect.width,
                    height: 12
                ),
                font: .monospacedDigitSystemFont(
                    ofSize: appearance.percentageFontSize,
                    weight: appearance.percentageFontWeight.nsWeight
                ),
                color: .labelColor
            )
            drawText(
                appearance.captionText,
                in: NSRect(
                    x: rect.minX,
                    y: CGFloat(appearance.captionVerticalOffset),
                    width: rect.width,
                    height: 9
                ),
                font: .systemFont(
                    ofSize: appearance.captionFontSize,
                    weight: appearance.captionFontWeight.nsWeight
                ),
                color: appearance.captionColor.nsColor
            )
        } else {
            drawSingleLineTitle(in: rect, appearance: appearance)
        }
    }

    private func drawSingleLineTitle(in rect: NSRect, appearance: MenuBarAppearance) {
        let height = CGFloat(appearance.percentageFontSize + 3)
        drawText(
            title,
            in: NSRect(
                x: rect.minX,
                y: rect.midY - height / 2 + CGFloat(appearance.percentageVerticalOffset),
                width: rect.width,
                height: height
            ),
            font: .monospacedDigitSystemFont(
                ofSize: appearance.percentageFontSize,
                weight: appearance.percentageFontWeight.nsWeight
            ),
            color: .labelColor
        )
    }

    private func drawText(_ value: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping
        (value as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }

    private func drawUnknown(in rect: NSRect) {
        drawText(
            "?",
            in: rect,
            font: .systemFont(ofSize: 8, weight: .semibold),
            color: .secondaryLabelColor
        )
    }

    private func drawStaleIndicator(in rect: NSRect, appearance: MenuBarAppearance) {
        let size = CGFloat(appearance.staleIndicatorSize)
        let x: CGFloat
        switch appearance.staleIndicatorPlacement {
        case .leading:
            x = CGFloat(appearance.horizontalPadding)
        case .trailing:
            x = rect.maxX - staleWidth + 1
        }
        drawText(
            "!",
            in: NSRect(x: x, y: rect.midY - size / 2, width: size, height: size + 2),
            font: .systemFont(ofSize: size, weight: .bold),
            color: appearance.staleColor.nsColor
        )
    }

    private func attentionColor(appearance: MenuBarAppearance) -> NSColor {
        switch attentionLevel {
        case .normal: appearance.normalColor.nsColor
        case .warning: appearance.warningColor.nsColor
        case .critical: appearance.criticalColor.nsColor
        }
    }

    private var accessibilityText: String {
        guard let remainingPercent else { return L10n.string("menubar.unavailable") }
        let quota = L10n.format("menubar.remaining_format", remainingPercent)
        var components = [quota]
        if let remainingTimePercent {
            components.append(L10n.format("menubar.time_remaining_format", remainingTimePercent))
        }
        if isStale {
            components.append(L10n.string("data.stale"))
        }
        return components.joined(separator: ", ")
    }
}

private extension MenuBarFontWeightChoice {
    var nsWeight: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

private extension MenuBarColorChoice {
    var nsColor: NSColor {
        switch self {
        case .system: .labelColor
        case .blue: .systemBlue
        case .teal: .systemTeal
        case .green: .systemGreen
        case .yellow: .systemYellow
        case .orange: .systemOrange
        case .red: .systemRed
        case .pink: .systemPink
        case .purple: .systemPurple
        case .white: .white
        }
    }
}
