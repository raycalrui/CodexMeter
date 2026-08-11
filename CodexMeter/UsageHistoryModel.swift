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
    @Published private(set) var activeAccountKey: String?

    let databaseURL: URL
    private let store: UsageHistoryStore?
    private var accountPreparationTask: Task<Void, Never>?

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
        retention: HistoryRetention,
        accountKey: String
    ) {
        guard let store else { return }
        let accountPreparationTask = self.accountPreparationTask
        Task {
            await accountPreparationTask?.value
            do {
                try await store.recordQuotaSnapshots(
                    windows,
                    at: date,
                    isStale: isStale,
                    source: source,
                    accountKey: accountKey
                )
                try await store.applyRetention(retention, now: date)
                if activeAccountKey == accountKey {
                    dataRevision += 1
                    await refreshMetadata()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func recordTokenUsage(
        _ snapshot: TokenUsageSnapshot,
        retention: HistoryRetention,
        accountKey: String
    ) {
        guard let store else { return }
        if activeAccountKey == accountKey {
            tokenUsage = snapshot
        }
        let accountPreparationTask = self.accountPreparationTask
        Task {
            await accountPreparationTask?.value
            do {
                try await store.recordTokenUsage(snapshot, accountKey: accountKey)
                try await store.applyRetention(retention, now: snapshot.fetchedAt)
                if activeAccountKey == accountKey {
                    dataRevision += 1
                    await refreshMetadata()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func load(now: Date = Date()) async {
        guard let store else { return }
        guard let accountKey = activeAccountKey else {
            quotaWindows = []
            quotaSamples = []
            tokenUsage = nil
            storageSize = await store.storageSize()
            return
        }
        isLoading = true
        defer {
            if activeAccountKey == accountKey {
                isLoading = false
            }
        }

        do {
            let loadedWindows = try await store.quotaWindows(accountKey: accountKey)
            // Keep one shared 30-day snapshot for the popover and history window.
            // Views filter by window and range without overwriting each other's data.
            let loadedSamples = try await store.quotaSamples(
                since: now.addingTimeInterval(-30 * 24 * 60 * 60),
                accountKey: accountKey
            )
            let loadedTokenUsage = try await store.tokenUsage(accountKey: accountKey)
            let loadedStorageSize = await store.storageSize()
            guard activeAccountKey == accountKey else { return }
            quotaWindows = loadedWindows
            quotaSamples = loadedSamples
            tokenUsage = loadedTokenUsage
            storageSize = loadedStorageSize
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func activateAccount(
        _ accountKey: String,
        resetExisting: Bool,
        claimLegacyHistory: Bool
    ) {
        activeAccountKey = accountKey
        quotaWindows = []
        quotaSamples = []
        tokenUsage = nil
        dataRevision += 1

        guard let store else { return }
        let task = Task {
            do {
                if resetExisting {
                    try await store.clearAccount(accountKey)
                }
                if claimLegacyHistory {
                    try await store.claimLegacyHistory(for: accountKey)
                }
                guard activeAccountKey == accountKey else { return }
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        accountPreparationTask = task
    }

    func deactivateAccount() {
        activeAccountKey = nil
        quotaWindows = []
        quotaSamples = []
        tokenUsage = nil
        dataRevision += 1
        accountPreparationTask = nil
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

    func generateDeveloperPreviewData() async {
        guard let store, let accountKey = activeAccountKey else { return }
        do {
            try await store.replaceDeveloperPreviewData(
                windowName: L10n.string("developer.history_preview_window"),
                accountKey: accountKey
            )
            dataRevision += 1
            await refreshMetadata()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearDeveloperPreviewData() async {
        guard let store, let accountKey = activeAccountKey else { return }
        do {
            try await store.clearDeveloperPreviewData(accountKey: accountKey)
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
        guard let accountKey = activeAccountKey else {
            throw UsageHistoryStoreError.openDatabase("No active account history is available.")
        }
        return try await store.exportCSV(accountKey: accountKey)
    }

    func refreshMetadata() async {
        guard let store else { return }
        do {
            guard let accountKey = activeAccountKey else {
                storageSize = await store.storageSize()
                return
            }
            let loadedWindows = try await store.quotaWindows(accountKey: accountKey)
            let loadedTokenUsage = try await store.tokenUsage(accountKey: accountKey)
            let loadedStorageSize = await store.storageSize()
            guard activeAccountKey == accountKey else { return }
            quotaWindows = loadedWindows
            tokenUsage = loadedTokenUsage
            storageSize = loadedStorageSize
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepare() async {
        guard let store else { return }
        do {
            try await store.prepareDatabase()
            isReady = true
            if activeAccountKey == nil {
                storageSize = await store.storageSize()
            } else {
                await load()
            }
        } catch {
            // History failures remain isolated; live quota display continues normally.
            errorMessage = error.localizedDescription
        }
    }
}
