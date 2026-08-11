import Combine
import Foundation

/// Bridges the actor-backed history store to SwiftUI without blocking the menu bar.
@MainActor
final class UsageHistoryModel: ObservableObject {
    @Published private(set) var quotaWindows: [QuotaHistoryWindow] = []
    @Published private(set) var quotaSamples: [QuotaHistorySample] = []
    @Published private(set) var tokenUsage: TokenUsageSnapshot?
    @Published private(set) var storageSize: Int64 = 0
    @Published private(set) var isReady = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var dataRevision = 0

    let databaseURL: URL
    private let store: UsageHistoryStore?

    init(databaseURL: URL = UsageHistoryStore.defaultDatabaseURL()) {
        self.databaseURL = databaseURL
        do {
            store = try UsageHistoryStore(databaseURL: databaseURL)
        } catch {
            store = nil
            errorMessage = error.localizedDescription
        }

        Task { await prepare() }
    }

    func recordQuota(
        windows: [CodexUsageWindow],
        at date: Date,
        isStale: Bool,
        source: QuotaSampleSource,
        retention: HistoryRetention
    ) {
        guard let store else { return }
        Task {
            do {
                try await store.recordQuotaSnapshots(
                    windows,
                    at: date,
                    isStale: isStale,
                    source: source
                )
                try await store.applyRetention(retention, now: date)
                dataRevision += 1
                await refreshMetadata()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func recordTokenUsage(_ snapshot: TokenUsageSnapshot, retention: HistoryRetention) {
        guard let store else { return }
        tokenUsage = snapshot
        Task {
            do {
                try await store.recordTokenUsage(snapshot)
                try await store.applyRetention(retention, now: snapshot.fetchedAt)
                dataRevision += 1
                await refreshMetadata()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func load(now: Date = Date()) async {
        guard let store else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            quotaWindows = try await store.quotaWindows()
            // Keep one shared 30-day snapshot for the popover and history window.
            // Views filter by window and range without overwriting each other's data.
            quotaSamples = try await store.quotaSamples(
                since: now.addingTimeInterval(-30 * 24 * 60 * 60)
            )
            tokenUsage = try await store.tokenUsage()
            storageSize = await store.storageSize()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyRetention(_ retention: HistoryRetention) async {
        guard let store else { return }
        do {
            try await store.applyRetention(retention)
            dataRevision += 1
            await refreshMetadata()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearAll() async {
        guard let store else { return }
        do {
            try await store.clearAll()
            quotaWindows = []
            quotaSamples = []
            tokenUsage = nil
            dataRevision += 1
            await refreshMetadata()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearTokenUsageForAccountChange() {
        guard let store else { return }
        tokenUsage = nil
        Task {
            do {
                try await store.clearTokenUsage()
                dataRevision += 1
                await refreshMetadata()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func generateDeveloperPreviewData() async {
        guard let store else { return }
        do {
            try await store.replaceDeveloperPreviewData(
                windowName: L10n.string("developer.history_preview_window")
            )
            dataRevision += 1
            await refreshMetadata()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearDeveloperPreviewData() async {
        guard let store else { return }
        do {
            try await store.clearDeveloperPreviewData()
            dataRevision += 1
            await refreshMetadata()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportCSV() async throws -> Data {
        guard let store else {
            throw UsageHistoryStoreError.openDatabase(
                errorMessage ?? "History storage is unavailable."
            )
        }
        return try await store.exportCSV()
    }

    func refreshMetadata() async {
        guard let store else { return }
        do {
            quotaWindows = try await store.quotaWindows()
            tokenUsage = try await store.tokenUsage()
            storageSize = await store.storageSize()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepare() async {
        guard let store else { return }
        do {
            try await store.prepareDatabase()
            isReady = true
            await refreshMetadata()
        } catch {
            // History failures remain isolated; live quota display continues normally.
            errorMessage = error.localizedDescription
        }
    }
}
