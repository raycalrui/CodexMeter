import Combine
import Foundation
import Sparkle

struct AvailableUpdate: Equatable, Identifiable {
    let version: String
    let title: String?
    let releaseNotes: String?
    let releasePageURL: URL
    let publishedAt: Date?

    var id: String { version }
}

@MainActor
final class UpdateChecker: NSObject, ObservableObject, SPUUpdaterDelegate {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(AvailableUpdate)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var automaticallyInstallsUpdates = false
    @Published private(set) var isDeveloperPreview = false

    private let releasesURL = URL(string: "https://github.com/raycalrui/CodexMeter/releases")!
    private var includesPrereleases: Bool
    private var stateBeforeDeveloperPreview: State?
    private var updaterController: SPUStandardUpdaterController!

    init(includePrereleases: Bool = false) {
        includesPrereleases = includePrereleases
        super.init()

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        refreshPreferences()
    }

    var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var installedBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    var allowsAutomaticUpdates: Bool {
        updaterController.updater.allowsAutomaticUpdates
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    func check(includePrereleases: Bool) {
        setIncludesPrereleases(includePrereleases)
        if isDeveloperPreview {
            clearDeveloperPreview()
        }
        state = .checking
        updaterController.checkForUpdates(nil)
    }

    func setIncludesPrereleases(_ includePrereleases: Bool) {
        guard includesPrereleases != includePrereleases else { return }
        includesPrereleases = includePrereleases
        updaterController.updater.resetUpdateCycleAfterShortDelay()
    }

    func setAutomaticallyInstallsUpdates(_ enabled: Bool) {
        updaterController.updater.automaticallyDownloadsUpdates = enabled
        refreshPreferences()
    }

    func refreshPreferences() {
        automaticallyInstallsUpdates = updaterController.updater.automaticallyDownloadsUpdates
    }

    func showDeveloperUpdatePreview() {
        if !isDeveloperPreview {
            stateBeforeDeveloperPreview = state
        }
        isDeveloperPreview = true
        state = .updateAvailable(AvailableUpdate(
            version: "9.9.9",
            title: "CodexMeter 9.9.9 Preview",
            releaseNotes: nil,
            releasePageURL: releasesURL.appending(path: "tag/v9.9.9"),
            publishedAt: nil
        ))
    }

    func clearDeveloperPreview() {
        guard isDeveloperPreview else { return }
        isDeveloperPreview = false
        state = stateBeforeDeveloperPreview ?? .idle
        stateBeforeDeveloperPreview = nil
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        includesPrereleases ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard !isDeveloperPreview else { return }
        state = .updateAvailable(AvailableUpdate(
            version: item.displayVersionString,
            title: item.title,
            releaseNotes: item.itemDescriptionFormat == "plain-text"
                ? item.itemDescription
                : nil,
            releasePageURL: item.infoURL ?? releasesURL,
            publishedAt: item.date
        ))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        guard !isDeveloperPreview else { return }
        state = .upToDate
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard !isDeveloperPreview else { return }
        if state == .upToDate {
            return
        }
        state = .failed(error.localizedDescription)
    }
}
