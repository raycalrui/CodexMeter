import AppKit
import SwiftUI

/// Keeps experimental appearance controls separate from the everyday settings.
struct DeveloperOptionsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: UsageHistoryModel
    @ObservedObject var updateChecker: UpdateChecker
    @Environment(\.dismiss) private var dismiss
    @State private var didCopyConfiguration = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.string("developer.title"), systemImage: "hammer")
                    .font(.headline)
                Spacer()
                Button(L10n.string("action.close")) {
                    dismiss()
                }
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    previewGroup
                    historyPreviewGroup
                    updatePreviewGroup
                    typographyGroup
                    geometryGroup
                    colorGroup
                    staleIndicatorGroup
                    actionGroup
                }
                .padding(16)
            }
        }
        .frame(width: 540, height: 680)
        .background(WindowTitleUpdater(title: L10n.string("developer.title")))
    }

    private var updatePreviewGroup: some View {
        GroupBox(L10n.string("developer.update_preview")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string("developer.update_preview_help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(L10n.string("developer.update_preview_show")) {
                        updateChecker.showDeveloperUpdatePreview()
                    }
                    Button(L10n.string("developer.update_preview_clear")) {
                        updateChecker.clearDeveloperPreview()
                    }
                    .disabled(!updateChecker.isDeveloperPreview)
                    Spacer()
                }
            }
            .padding(.top, 4)
        }
    }

    private var historyPreviewGroup: some View {
        GroupBox(L10n.string("developer.history_preview")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string("developer.history_preview_help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(L10n.string("developer.history_preview_generate")) {
                        Task { await history.generateDeveloperPreviewData() }
                    }
                    Button(L10n.string("developer.history_preview_clear"), role: .destructive) {
                        Task { await history.clearDeveloperPreviewData() }
                    }
                    Spacer()
                }
            }
            .padding(.top, 4)
        }
    }

    private var previewGroup: some View {
        GroupBox(L10n.string("developer.preview")) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(L10n.string("settings.menubar_style"), selection: $settings.menuBarStyle) {
                    ForEach(MenuBarDisplayStyle.allCases) { style in
                        Text(style.localizedName).tag(style)
                    }
                }

                Picker(
                    L10n.string("developer.preview_preset"),
                    selection: Binding(
                        get: { settings.developerPreviewPreset },
                        set: { settings.selectDeveloperPreviewPreset($0) }
                    )
                ) {
                    ForEach(DeveloperPreviewPreset.allCases) { preset in
                        Text(preset.localizedName).tag(preset)
                    }
                }

                DeveloperSliderRow(
                    title: L10n.string("developer.preview_quota"),
                    value: Binding(
                        get: { settings.developerPreviewRemainingPercent },
                        set: { settings.setDeveloperPreviewRemainingPercent($0) }
                    ),
                    range: 0...100,
                    step: 1,
                    valueSuffix: "%"
                )

                DeveloperSliderRow(
                    title: L10n.string("developer.preview_time"),
                    value: Binding(
                        get: { settings.developerPreviewRemainingTimePercent },
                        set: { settings.setDeveloperPreviewRemainingTimePercent($0) }
                    ),
                    range: 0...100,
                    step: 1,
                    valueSuffix: "%"
                )

                Text(L10n.string("developer.preview_sliders_help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    MenuBarProgressView(
                        remainingPercent: previewSnapshot.remainingPercent,
                        remainingTimePercent: previewSnapshot.remainingTimePercent,
                        title: previewSnapshot.title,
                        style: settings.menuBarStyle,
                        attentionLevel: previewSnapshot.attentionLevel,
                        isStale: previewSnapshot.isStale,
                        appearance: settings.developerAppearance
                    )
                    Spacer()
                }
                .frame(height: 44)
                .background(.bar, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 1)
                }

                Toggle(
                    L10n.string("developer.use_preview_in_menubar"),
                    isOn: $settings.developerPreviewEnabled
                )

                if settings.developerPreviewEnabled {
                    Label(
                        L10n.string("developer.preview_active_help"),
                        systemImage: "eye.trianglebadge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)

                    Button(L10n.string("developer.return_to_live")) {
                        settings.developerPreviewEnabled = false
                    }
                }

                Text(L10n.string("developer.preview_language_help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private var typographyGroup: some View {
        GroupBox(L10n.string("developer.typography")) {
            VStack(alignment: .leading, spacing: 10) {
                DeveloperSliderRow(
                    title: L10n.string("developer.percentage_font_size"),
                    value: appearanceBinding(\.percentageFontSize),
                    range: 8...14,
                    step: 0.5,
                    valueSuffix: " pt"
                )

                Picker(
                    L10n.string("developer.percentage_font_weight"),
                    selection: appearanceBinding(\.percentageFontWeight)
                ) {
                    ForEach(MenuBarFontWeightChoice.allCases) { weight in
                        Text(weight.localizedName).tag(weight)
                    }
                }

                DeveloperSliderRow(
                    title: L10n.string("developer.percentage_vertical_position"),
                    value: appearanceBinding(\.percentageVerticalOffset),
                    range: -4...4,
                    step: 0.5,
                    valueSuffix: " pt"
                )

                Divider()

                Toggle(
                    L10n.string("developer.show_caption"),
                    isOn: appearanceBinding(\.showsCaption)
                )

                TextField(
                    L10n.string("developer.caption_text"),
                    text: appearanceBinding(\.captionText)
                )
                .disabled(!settings.developerAppearance.showsCaption)

                Picker(
                    L10n.string("developer.caption_font_weight"),
                    selection: appearanceBinding(\.captionFontWeight)
                ) {
                    ForEach(MenuBarFontWeightChoice.allCases) { weight in
                        Text(weight.localizedName).tag(weight)
                    }
                }
                .disabled(!settings.developerAppearance.showsCaption)

                DeveloperSliderRow(
                    title: L10n.string("developer.caption_font_size"),
                    value: appearanceBinding(\.captionFontSize),
                    range: 5...10,
                    step: 0.5,
                    valueSuffix: " pt"
                )
                .disabled(!settings.developerAppearance.showsCaption)

                DeveloperSliderRow(
                    title: L10n.string("developer.caption_vertical_position"),
                    value: appearanceBinding(\.captionVerticalOffset),
                    range: -4...4,
                    step: 0.5,
                    valueSuffix: " pt"
                )
                .disabled(!settings.developerAppearance.showsCaption)
            }
            .padding(.top, 4)
        }
    }

    private var geometryGroup: some View {
        GroupBox(L10n.string("developer.geometry")) {
            VStack(alignment: .leading, spacing: 10) {
                DeveloperSliderRow(
                    title: L10n.string("developer.item_height"),
                    value: appearanceBinding(\.itemHeight),
                    range: 18...24,
                    step: 1,
                    valueSuffix: " pt"
                )
                DeveloperSliderRow(
                    title: L10n.string("developer.ring_diameter"),
                    value: appearanceBinding(\.ringDiameter),
                    range: 12...20,
                    step: 0.5,
                    valueSuffix: " pt"
                )
                DeveloperSliderRow(
                    title: L10n.string("developer.outer_ring_width"),
                    value: appearanceBinding(\.outerRingStrokeWidth),
                    range: 1...5,
                    step: 0.1,
                    valueSuffix: " pt"
                )
                DeveloperSliderRow(
                    title: L10n.string("developer.inner_ring_width"),
                    value: appearanceBinding(\.innerRingStrokeWidth),
                    range: 1...4,
                    step: 0.1,
                    valueSuffix: " pt"
                )
                DeveloperSliderRow(
                    title: L10n.string("developer.ring_gap"),
                    value: appearanceBinding(\.ringGap),
                    range: 0...3,
                    step: 0.1,
                    valueSuffix: " pt"
                )
                DeveloperSliderRow(
                    title: L10n.string("developer.start_angle"),
                    value: appearanceBinding(\.ringStartAngle),
                    range: 0...360,
                    step: 5,
                    valueSuffix: "°"
                )
                DeveloperSliderRow(
                    title: L10n.string("developer.track_opacity"),
                    value: appearanceBinding(\.trackOpacity),
                    range: 0.05...0.5,
                    step: 0.01,
                    valueSuffix: ""
                )
                DeveloperSliderRow(
                    title: L10n.string("developer.indicator_text_spacing"),
                    value: appearanceBinding(\.indicatorTextSpacing),
                    range: 0...8,
                    step: 0.5,
                    valueSuffix: " pt"
                )
                DeveloperSliderRow(
                    title: L10n.string("developer.horizontal_padding"),
                    value: appearanceBinding(\.horizontalPadding),
                    range: 0...6,
                    step: 0.5,
                    valueSuffix: " pt"
                )
                DeveloperSliderRow(
                    title: L10n.string("developer.text_width"),
                    value: appearanceBinding(\.textWidth),
                    range: 24...56,
                    step: 1,
                    valueSuffix: " pt"
                )
                DeveloperSliderRow(
                    title: L10n.string("developer.bar_width"),
                    value: appearanceBinding(\.barWidth),
                    range: 16...40,
                    step: 1,
                    valueSuffix: " pt"
                )
                DeveloperSliderRow(
                    title: L10n.string("developer.bar_height"),
                    value: appearanceBinding(\.barHeight),
                    range: 2...6,
                    step: 0.5,
                    valueSuffix: " pt"
                )
            }
            .padding(.top, 4)
        }
    }

    private var colorGroup: some View {
        GroupBox(L10n.string("developer.colors")) {
            VStack(alignment: .leading, spacing: 10) {
                colorPicker(
                    L10n.string("developer.normal_color"),
                    selection: appearanceBinding(\.normalColor)
                )
                colorPicker(
                    L10n.string("developer.warning_color"),
                    selection: appearanceBinding(\.warningColor)
                )
                colorPicker(
                    L10n.string("developer.critical_color"),
                    selection: appearanceBinding(\.criticalColor)
                )
                colorPicker(
                    L10n.string("developer.time_color"),
                    selection: appearanceBinding(\.timeColor)
                )
                colorPicker(
                    L10n.string("developer.caption_color"),
                    selection: appearanceBinding(\.captionColor)
                )
            }
            .padding(.top, 4)
        }
    }

    private var staleIndicatorGroup: some View {
        GroupBox(L10n.string("developer.stale_indicator")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    L10n.string("developer.show_stale_indicator"),
                    isOn: appearanceBinding(\.showsStaleIndicator)
                )
                colorPicker(
                    L10n.string("developer.stale_color"),
                    selection: appearanceBinding(\.staleColor)
                )
                .disabled(!settings.developerAppearance.showsStaleIndicator)
                DeveloperSliderRow(
                    title: L10n.string("developer.stale_size"),
                    value: appearanceBinding(\.staleIndicatorSize),
                    range: 7...14,
                    step: 1,
                    valueSuffix: " pt"
                )
                .disabled(!settings.developerAppearance.showsStaleIndicator)
                Picker(
                    L10n.string("developer.stale_placement"),
                    selection: appearanceBinding(\.staleIndicatorPlacement)
                ) {
                    ForEach(StaleIndicatorPlacement.allCases) { placement in
                        Text(placement.localizedName).tag(placement)
                    }
                }
                .disabled(!settings.developerAppearance.showsStaleIndicator)
            }
            .padding(.top, 4)
        }
    }

    private var actionGroup: some View {
        HStack {
            Button(L10n.string("developer.reset_defaults"), role: .destructive) {
                settings.resetDeveloperOptions()
                didCopyConfiguration = false
            }

            Spacer()

            if didCopyConfiguration {
                Label(L10n.string("developer.copied"), systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(L10n.string("developer.copy_json")) {
                copyConfiguration()
            }
        }
    }

    private var previewSnapshot: MenuBarPreviewSnapshot {
        settings.developerPreviewSnapshot
    }

    private func appearanceBinding<Value>(
        _ keyPath: WritableKeyPath<MenuBarAppearance, Value>
    ) -> Binding<Value> {
        Binding(
            get: { settings.developerAppearance[keyPath: keyPath] },
            set: { value in
                var updated = settings.developerAppearance
                updated[keyPath: keyPath] = value
                settings.developerAppearance = updated.normalized()
            }
        )
    }

    private func colorPicker(
        _ title: String,
        selection: Binding<MenuBarColorChoice>
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(MenuBarColorChoice.allCases) { color in
                Text(color.localizedName).tag(color)
            }
        }
    }

    private func copyConfiguration() {
        guard let text = settings.developerConfigurationJSON() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        didCopyConfiguration = true
    }
}

/// Keeps the native window title synchronized with the in-app language choice.
struct WindowTitleUpdater: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> WindowTitleView {
        WindowTitleView(title: title)
    }

    func updateNSView(_ nsView: WindowTitleView, context: Context) {
        nsView.updateTitle(title)
    }

    final class WindowTitleView: NSView {
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
            window?.title = currentTitle
        }

        func updateTitle(_ title: String) {
            currentTitle = title
            window?.title = title
        }
    }
}

private struct DeveloperSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueSuffix: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 170, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text(formattedValue)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
        .font(.caption)
    }

    private var formattedValue: String {
        let decimals = step < 1 ? 1 : 0
        return String(format: "%.*f%@", decimals, value, valueSuffix)
    }
}
