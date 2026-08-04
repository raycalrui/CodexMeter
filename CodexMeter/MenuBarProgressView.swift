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

    var body: some View {
        Image(nsImage: statusImage)
            .renderingMode(.original)
            .accessibilityLabel(accessibilityText)
    }

    private var imageSize: NSSize {
        let baseWidth: CGFloat
        switch style {
        case .progressAndPercentage: baseWidth = 62
        case .percentageOnly: baseWidth = 38
        case .progressOnly: baseWidth = 20
        }
        return NSSize(width: baseWidth + (isStale ? 12 : 0), height: 20)
    }

    private var statusImage: NSImage {
        let size = imageSize
        let image = NSImage(size: size, flipped: false) { rect in
            var cursorX: CGFloat = 1

            if style != .percentageOnly {
                drawProgressRings(in: NSRect(x: cursorX, y: 1, width: 18, height: 18))
                cursorX += 20
            }

            if style != .progressOnly {
                let trailingSpace: CGFloat = isStale ? 12 : 1
                let textWidth = max(20, rect.width - cursorX - trailingSpace)
                drawText(in: NSRect(x: cursorX, y: 0, width: textWidth, height: rect.height))
            }

            if isStale {
                drawStaleIndicator(in: rect)
            }
            return true
        }
        // Preserve quota and warning colors instead of applying template tinting.
        image.isTemplate = false
        return image
    }

    private func drawProgressRings(in rect: NSRect) {
        // The outer ring represents remaining quota and uses the attention color.
        let outerRect = rect.insetBy(dx: 1.25, dy: 1.25)
        let background = NSBezierPath(ovalIn: outerRect)
        background.lineWidth = 2.7
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        background.stroke()

        guard let remainingPercent else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            ("?" as NSString).draw(
                in: NSRect(x: rect.minX, y: rect.minY + 2, width: rect.width, height: 12),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph
                ]
            )
            return
        }

        let fraction = CGFloat(min(100, max(0, remainingPercent))) / 100
        if fraction > 0 {
            let progress = NSBezierPath()
            progress.appendArc(
                withCenter: NSPoint(x: rect.midX, y: rect.midY),
                radius: outerRect.width / 2,
                startAngle: 90,
                endAngle: 90 - 360 * fraction,
                clockwise: true
            )
            progress.lineWidth = 2.7
            progress.lineCapStyle = .round
            ringColor.setStroke()
            progress.stroke()
        }

        drawTimeRing(in: rect.insetBy(dx: 3.1, dy: 3.1))
    }

    private func drawTimeRing(in rect: NSRect) {
        // Omit the inner ring when App Server does not provide reset timing.
        guard let remainingTimePercent else { return }

        let ringRect = rect.insetBy(dx: 0.9, dy: 0.9)
        let background = NSBezierPath(ovalIn: ringRect)
        background.lineWidth = 2.2
        NSColor.systemBlue.withAlphaComponent(0.20).setStroke()
        background.stroke()

        let fraction = CGFloat(min(100, max(0, remainingTimePercent))) / 100
        guard fraction > 0 else { return }

        let progress = NSBezierPath()
        progress.appendArc(
            withCenter: NSPoint(x: rect.midX, y: rect.midY),
            radius: ringRect.width / 2,
            startAngle: 90,
            endAngle: 90 - 360 * fraction,
            clockwise: true
        )
        progress.lineWidth = 2.2
        progress.lineCapStyle = .round
        NSColor.systemBlue.setStroke()
        progress.stroke()
    }

    private func drawText(in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping

        (title as NSString).draw(
            in: NSRect(x: rect.minX, y: 8, width: rect.width, height: 12),
            withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )

        (L10n.string("menubar.caption") as NSString).draw(
            in: NSRect(x: rect.minX, y: 0, width: rect.width, height: 8),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 6.5, weight: .medium),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
    }

    private func drawStaleIndicator(in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        ("!" as NSString).draw(
            in: NSRect(x: rect.maxX - 11, y: 3, width: 10, height: 14),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.systemOrange,
                .paragraphStyle: paragraph
            ]
        )
    }

    private var ringColor: NSColor {
        switch attentionLevel {
        case .normal: .labelColor
        case .warning: .systemYellow
        case .critical: .systemRed
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
