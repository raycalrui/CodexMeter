import SwiftUI

/// Edits presentation-only popover preferences in an independent window.
/// Keeping this outside MenuBarExtra prevents the controls from disappearing
/// whenever the user interacts with a picker or another app window.
struct PopoverCustomizationView: View {
    @ObservedObject var service: CodexUsageService
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Text(L10n.string("settings.popover.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.string("settings.popover.menu_bar_ring")) {
                Picker(
                    L10n.string("settings.popover.ring_source"),
                    selection: menuBarWindowSelection
                ) {
                    Text(L10n.string("settings.popover.ring_source.automatic"))
                        .tag(String?.none)

                    ForEach(service.windows) { window in
                        Text(window.name)
                            .tag(Optional(window.historyID))
                    }
                }
                .accessibilityHint(L10n.string("settings.popover.ring_source.hint"))
            }

            Section(L10n.string("settings.popover.visible_content")) {
                ForEach(settings.popoverContent.sectionOrder) { section in
                    sectionRow(section)

                    if section == .quotaWindows,
                       settings.popoverContent.isSectionVisible(.quotaWindows) {
                        quotaWindowRows
                    }
                }
            }

            Section(L10n.string("settings.popover.preview")) {
                PopoverContentPreview(
                    service: service,
                    configuration: settings.popoverContent
                )
            }

            Section {
                Button(L10n.string("settings.popover.restore_defaults")) {
                    settings.resetPopoverContent()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.string("settings.popover.title"))
        .frame(minWidth: 500, minHeight: 580)
    }

    private var menuBarWindowSelection: Binding<String?> {
        Binding(
            get: {
                let storedID = settings.popoverContent.menuBarQuotaWindowID
                return service.windows.contains { $0.historyID == storedID } ? storedID : nil
            },
            set: { settings.setMenuBarQuotaWindowID($0) }
        )
    }

    private func sectionRow(_ section: PopoverContentSection) -> some View {
        HStack(spacing: 10) {
            Toggle(
                section.localizedName,
                isOn: Binding(
                    get: { settings.popoverContent.isSectionVisible(section) },
                    set: { settings.setPopoverSection(section, visible: $0) }
                )
            )

            Spacer(minLength: 8)

            Button {
                settings.movePopoverSection(section, by: -1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(sectionIndex(section) == 0)
            .help(L10n.format("settings.popover.move_up_format", section.localizedName))
            .accessibilityLabel(
                L10n.format("settings.popover.move_up_format", section.localizedName)
            )

            Button {
                settings.movePopoverSection(section, by: 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(sectionIndex(section) == settings.popoverContent.sectionOrder.count - 1)
            .help(L10n.format("settings.popover.move_down_format", section.localizedName))
            .accessibilityLabel(
                L10n.format("settings.popover.move_down_format", section.localizedName)
            )
        }
    }

    @ViewBuilder
    private var quotaWindowRows: some View {
        if service.windows.isEmpty {
            Text(L10n.string("settings.popover.no_quota_windows"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 24)
        } else {
            ForEach(service.windows) { window in
                Toggle(
                    window.name,
                    isOn: Binding(
                        get: { settings.popoverContent.isQuotaWindowVisible(window) },
                        set: { settings.setQuotaWindow(window, visible: $0) }
                    )
                )
                .controlSize(.small)
                .padding(.leading, 24)
                .accessibilityLabel(
                    L10n.format("settings.popover.quota_window_format", window.name)
                )
            }
        }
    }

    private func sectionIndex(_ section: PopoverContentSection) -> Int {
        settings.popoverContent.sectionOrder.firstIndex(of: section) ?? 0
    }
}

/// Shows the currently enabled sections in their actual stored order.
private struct PopoverContentPreview: View {
    @ObservedObject var service: CodexUsageService
    let configuration: PopoverContentConfiguration

    private var visibleSections: [PopoverContentSection] {
        configuration.sectionOrder.filter(configuration.isSectionVisible)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("app.title"))
                        .font(.subheadline.weight(.semibold))
                    Text(service.accountDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Divider()

            if previewRows.isEmpty {
                Text(L10n.string("settings.popover.preview_empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            } else {
                ForEach(Array(previewRows.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        Divider()
                    }

                    Label(row.title, systemImage: row.symbolName)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            Label(L10n.string("settings.title"), systemImage: "gearshape")
                .font(.caption)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var previewRows: [PreviewRow] {
        visibleSections.flatMap { section -> [PreviewRow] in
            switch section {
            case .quotaWindows:
                return configuration.visibleQuotaWindows(from: service.windows).map {
                    PreviewRow(title: $0.name, symbolName: "gauge.with.dots.needle.50percent")
                }
            case .resetCredits:
                return [PreviewRow(
                    title: section.localizedName,
                    symbolName: "arrow.counterclockwise.circle"
                )]
            case .quotaHistory:
                return [PreviewRow(title: section.localizedName, symbolName: "chart.xyaxis.line")]
            case .tokenActivity:
                return [PreviewRow(title: section.localizedName, symbolName: "chart.bar.fill")]
            }
        }
    }

    private struct PreviewRow {
        let title: String
        let symbolName: String
    }
}
