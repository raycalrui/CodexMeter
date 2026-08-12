import AppKit
import SwiftUI

struct AboutView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: UsageHistoryModel
    @ObservedObject var updateChecker: UpdateChecker
    @Environment(\.dismiss) private var dismiss

    private let repositoryURL = URL(string: "https://github.com/raycalrui/CodexMeter")!

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    identitySection
                    updateSection
                    dataSection
                    privacySection
                    licenseSection
                }
                .padding(18)
            }
        }
        .frame(width: 500, height: 620)
        .background(WindowTitleUpdater(title: L10n.string("about.title")))
    }

    private var header: some View {
        HStack {
            Label(L10n.string("about.title"), systemImage: "info.circle")
                .font(.headline)
            Spacer()
            Button(L10n.string("action.close")) { dismiss() }
        }
        .padding(16)
    }

    private var identitySection: some View {
        GroupBox {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 5) {
                    Text("CodexMeter").font(.title2.weight(.semibold))
                    Text(L10n.format(
                        "about.version_format",
                        updateChecker.installedVersion,
                        updateChecker.installedBuild
                    ))
                    .foregroundStyle(.secondary)
                    Link(destination: repositoryURL) {
                        Label(L10n.string("about.github"), systemImage: "link")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var updateSection: some View {
        GroupBox(L10n.string("updates.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    L10n.string("updates.include_prereleases"),
                    isOn: Binding(
                        get: { settings.includePrereleaseUpdates },
                        set: { includePrereleases in
                            settings.includePrereleaseUpdates = includePrereleases
                            updateChecker.setIncludesPrereleases(includePrereleases)
                        }
                    )
                )

                Toggle(
                    L10n.string("updates.automatic_install"),
                    isOn: Binding(
                        get: { updateChecker.automaticallyInstallsUpdates },
                        set: { updateChecker.setAutomaticallyInstallsUpdates($0) }
                    )
                )
                .disabled(!updateChecker.allowsAutomaticUpdates)

                updateStatus

                Button {
                    updateChecker.check(
                        includePrereleases: settings.includePrereleaseUpdates
                    )
                } label: {
                    if updateChecker.state == .checking {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(L10n.string("updates.checking"))
                        }
                    } else {
                        Text(L10n.string("updates.check"))
                    }
                }
                .disabled(!updateChecker.canCheckForUpdates)
            }
            .padding(.top, 6)
        }
        .onAppear {
            updateChecker.refreshPreferences()
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updateChecker.state {
        case .idle:
            Text(L10n.string("updates.not_checked"))
                .foregroundStyle(.secondary)
        case .checking:
            Text(L10n.string("updates.checking"))
                .foregroundStyle(.secondary)
        case .upToDate:
            Label(L10n.string("updates.up_to_date"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(L10n.string("updates.failed"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .updateAvailable(let release):
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    L10n.format("updates.available_format", release.version),
                    systemImage: "arrow.down.circle.fill"
                )
                .foregroundStyle(.blue)

                if let notes = release.releaseNotes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }

                Button(L10n.string("updates.install")) {
                    updateChecker.check(
                        includePrereleases: settings.includePrereleaseUpdates
                    )
                }

                Link(
                    L10n.string("updates.open_release"),
                    destination: release.releasePageURL
                )
            }
        }
    }

    private var dataSection: some View {
        GroupBox(L10n.string("about.local_data")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(history.databaseURL.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button(L10n.string("about.reveal_data")) {
                    let target = FileManager.default.fileExists(atPath: history.databaseURL.path)
                        ? history.databaseURL
                        : history.databaseURL.deletingLastPathComponent()
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                }
            }
            .padding(.top, 6)
        }
    }

    private var privacySection: some View {
        GroupBox(L10n.string("about.privacy")) {
            Text(L10n.string("about.privacy_description"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    private var licenseSection: some View {
        GroupBox(L10n.string("about.license")) {
            Text(L10n.string("about.license_undeclared"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }
}
