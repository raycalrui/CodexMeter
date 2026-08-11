import Combine
import Foundation

struct GitHubRelease: Decodable, Equatable, Identifiable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let prerelease: Bool
    let draft: Bool
    let publishedAt: Date?

    var id: String { tagName }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case prerelease
        case draft
        case publishedAt = "published_at"
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(GitHubRelease)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var isDeveloperPreview = false

    private let defaults: UserDefaults
    private let session: URLSession
    private let repository = "raycalrui/CodexMeter"
    private var stateBeforeDeveloperPreview: State?

    private enum Keys {
        static let lastCheckedAt = "updates.lastCheckedAt"
    }

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        lastCheckedAt = defaults.object(forKey: Keys.lastCheckedAt) as? Date
    }

    var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var installedBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    func checkIfNeeded(includePrereleases: Bool) async {
        if let lastCheckedAt,
           Date().timeIntervalSince(lastCheckedAt) < UpdateCheckSchedule.successInterval {
            return
        }
        await check(includePrereleases: includePrereleases)
    }

    func runAutomaticChecks(includePrereleases: Bool) async {
        while !Task.isCancelled {
            await checkIfNeeded(includePrereleases: includePrereleases)

            let delay = UpdateCheckSchedule.nextDelay(
                lastCheckedAt: lastCheckedAt,
                now: Date(),
                lastAttemptFailed: state.isFailure
            )
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    func check(includePrereleases: Bool) async {
        if isDeveloperPreview {
            clearDeveloperPreview()
        }
        guard state != .checking else { return }
        state = .checking

        do {
            let releases = try await fetchReleases()
            let candidates = releases.compactMap { release -> (GitHubRelease, SemanticVersion)? in
                guard !release.draft,
                      includePrereleases || !release.prerelease,
                      let version = SemanticVersion(release.tagName) else {
                    return nil
                }
                return (release, version)
            }
            guard let latest = candidates.max(by: { $0.1 < $1.1 })?.0 else {
                throw URLError(.resourceUnavailable)
            }

            let checkedAt = Date()
            lastCheckedAt = checkedAt
            defaults.set(checkedAt, forKey: Keys.lastCheckedAt)

            if let installed = SemanticVersion(installedVersion),
               let remote = SemanticVersion(latest.tagName),
               installed < remote {
                state = .updateAvailable(latest)
            } else {
                state = .upToDate
            }
        } catch is CancellationError {
            state = .idle
        } catch {
            // Update availability never blocks use of the installed version.
            state = .failed(error.localizedDescription)
        }
    }

    func showDeveloperUpdatePreview() {
        guard let releaseURL = URL(
            string: "https://github.com/raycalrui/CodexMeter/releases/tag/v9.9.9"
        ) else { return }
        if !isDeveloperPreview {
            stateBeforeDeveloperPreview = state
        }
        isDeveloperPreview = true
        state = .updateAvailable(GitHubRelease(
            tagName: "v9.9.9",
            name: "CodexMeter 9.9.9 Preview",
            body: nil,
            htmlURL: releaseURL,
            prerelease: false,
            draft: false,
            publishedAt: nil
        ))
    }

    func clearDeveloperPreview() {
        guard isDeveloperPreview else { return }
        isDeveloperPreview = false
        state = stateBeforeDeveloperPreview ?? .idle
        stateBeforeDeveloperPreview = nil
    }

    private func fetchReleases() async throws -> [GitHubRelease] {
        guard let url = URL(
            string: "https://api.github.com/repos/\(repository)/releases?per_page=20"
        ) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexMeter/\(installedVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubRelease].self, from: data)
    }
}

private extension UpdateChecker.State {
    var isFailure: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}
