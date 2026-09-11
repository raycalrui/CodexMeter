import Combine
import Foundation

/// Owns the Codex App Server process and exposes account quota as UI state.
///
/// Authentication remains inside Codex. This app only exchanges JSON-RPC
/// messages with the locally installed `codex app-server` process over stdio.
final class CodexUsageService: ObservableObject {
    @Published private(set) var windows: [CodexUsageWindow] = []
    @Published private(set) var planType: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshInFlight = false
    @Published private(set) var isStale = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var tokenUsage: TokenUsageSnapshot?
    @Published private(set) var isTokenUsageUnavailable = false
    @Published private(set) var tokenUsageErrorMessage: String?
    @Published private(set) var rateLimitResetCredits: CodexRateLimitResetCreditsSummary?

    private enum RequestKind: Equatable {
        case initialize
        case account
        case rateLimits
        case usage
    }

    private let settings: AppSettings
    private let notificationManager: NotificationManager
    private let history: UsageHistoryModel
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputBuffer = CodexRPCLineBuffer()
    private var standardErrorBuffer = Data()
    private let standardErrorBufferLock = NSLock()
    private let maximumStandardErrorBytes = 8 * 1_024
    private var nextRequestID = 1
    // Request IDs let responses arrive independently without losing their type.
    private var pendingRequests: [Int: RequestKind] = [:]
    private var refreshTimer: Timer?
    private var refreshTimeout: DispatchWorkItem?
    private var usageTimeout: DispatchWorkItem?
    private var restartWorkItem: DispatchWorkItem?
    private var didInitialize = false
    private var didAttemptAccountRecovery = false
    private var rateLimitRequestSources: [Int: QuotaSampleSource] = [:]
    private var usageRequestID: Int?
    private var historyAccountKey: String?
    private var hasPendingAccountBoundary = false

    init(
        settings: AppSettings,
        history: UsageHistoryModel,
        notificationManager: NotificationManager = NotificationManager()
    ) {
        self.settings = settings
        self.history = history
        self.notificationManager = notificationManager

        // Defer startup until StateObject construction has completed on the main run loop.
        DispatchQueue.main.async { [weak self] in
            self?.installRefreshTimer()
            self?.start()
        }
    }

    var mostConstrainedRemainingPercent: Int? {
        mostConstrainedWindow?.remainingPercent
    }

    var mostConstrainedWindow: CodexUsageWindow? {
        // The menu bar should always represent the window closest to exhaustion.
        windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    var menuBarTitle: String {
        guard let remaining = mostConstrainedRemainingPercent else {
            return isLoading ? "…" : "--"
        }
        return "\(remaining)%"
    }

    var accountDescription: String {
        guard let planType else { return L10n.string("account.checking") }
        return L10n.format("account.chatgpt_format", planType.capitalized)
    }

    func start() {
        guard process == nil else { return }

        if windows.isEmpty {
            isLoading = true
        } else {
            isStale = true
        }

        guard let codexURL = locateCodexExecutable() else {
            markFailure(L10n.string("error.codex_not_found"))
            return
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = codexURL
        process.environment = CodexProcessEnvironment.make(
            baseEnvironment: ProcessInfo.processInfo.environment,
            executableURL: codexURL,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        // stdio transport keeps account credentials inside the official Codex process.
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading

        outputHandle.readabilityHandler = { [weak self, weak process] handle in
            do {
                let data = try CodexProcessPipe.readAvailableData(from: handle, maximumBytes: 64 * 1_024)
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                // Backpressure bounds queued output too. FileHandle invokes this on
                // its background queue; framing and process state stay on the main queue.
                DispatchQueue.main.sync {
                    guard let self, self.process === process else { return }
                    self.consumeOutput(data)
                }
            } catch {
                handle.readabilityHandler = nil
                DispatchQueue.main.sync {
                    guard let self, self.process === process else { return }
                    self.stopAppServerForOutputFailure(L10n.string("error.communication"))
                }
            }
        }

        resetStandardErrorBuffer()
        errorHandle.readabilityHandler = { [weak self] handle in
            guard let data = try? CodexProcessPipe.readAvailableData(from: handle, maximumBytes: 8 * 1_024),
                  !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            // App Server may emit harmless diagnostics to stderr. Protocol errors
            // are returned as JSON-RPC messages on stdout. Always drain stderr so
            // unread bytes cannot keep the file descriptor continuously readable.
            self?.consumeStandardError(data)
        }

        process.terminationHandler = { [weak self, weak process] terminatedProcess in
            outputHandle.readabilityHandler = nil
            errorHandle.readabilityHandler = nil

            let terminationStatus = terminatedProcess.terminationStatus
            let terminationReason = terminatedProcess.terminationReason

            DispatchQueue.main.async {
                guard let self, self.process === process else { return }
                let standardError = self.drainStandardErrorBuffer()
                self.clearAppServerResources()
                self.didInitialize = false
                self.pendingRequests.removeAll()
                self.rateLimitRequestSources.removeAll()
                self.cancelRefreshTimeout()
                self.cancelUsageTimeout()
                self.usageRequestID = nil
                self.markFailure(self.appServerStoppedMessage(
                    standardError: standardError,
                    terminationStatus: terminationStatus,
                    terminationReason: terminationReason
                ))
            }
        }

        do {
            try process.run()
            self.process = process
            inputHandle = inputPipe.fileHandleForWriting
            self.outputHandle = outputHandle
            self.errorHandle = errorHandle

            _ = sendRequest(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "codex_meter",
                        "title": "Codex Meter",
                        "version": appVersion
                    ]
                ],
                kind: .initialize
            )
        } catch {
            outputHandle.readabilityHandler = nil
            errorHandle.readabilityHandler = nil
            clearAppServerResources()
            markFailure(L10n.string("error.app_server_start_failed"))
        }
    }

    func refresh() {
        refresh(forceTokenRefresh: false, source: .refresh)
    }

    private func refresh(forceTokenRefresh: Bool, source: QuotaSampleSource) {
        if process == nil {
            start()
            return
        }

        // App Server requires initialization first; skip overlapping refreshes.
        guard didInitialize, !isRefreshInFlight else { return }

        isRefreshInFlight = true
        if windows.isEmpty {
            isLoading = true
        }
        errorMessage = nil

        _ = sendRequest(
            method: "account/read",
            params: ["refreshToken": forceTokenRefresh],
            kind: .account
        )

        guard let requestID = sendRequest(
            method: "account/rateLimits/read",
            params: [:],
            kind: .rateLimits
        ) else {
            if restartAppServerAfterAccountFailure() {
                return
            }
            markFailure(L10n.string("error.communication"))
            return
        }

        rateLimitRequestSources[requestID] = source
        scheduleRefreshTimeout(for: requestID)
    }

    func refreshIfNeeded(maxAge: TimeInterval = 60) {
        guard let lastUpdated else {
            refresh()
            return
        }

        if Date().timeIntervalSince(lastUpdated) >= maxAge {
            refresh()
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        guard enabled else {
            settings.notificationsEnabled = false
            if settings.settingsDestination == .notifications {
                settings.clearSettingsError()
            }
            return
        }

        notificationManager.requestAuthorization { [weak self] granted, error in
            guard let self else { return }
            self.settings.notificationsEnabled = granted
            if granted {
                self.settings.clearSettingsError()
                self.notificationManager.evaluate(
                    windows: self.windows,
                    threshold: self.settings.notificationThreshold
                )
            } else {
                let message = error ?? L10n.string("settings.notification_denied")
                self.settings.showSettingsError(message, destination: .notifications)
            }
        }
    }

    private func installRefreshTimer() {
        guard refreshTimer == nil else { return }
        // This refreshes server data. Countdown-only UI updates use TimelineView.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func clearAppServerResources(terminate: Bool = false) {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil

        let runningProcess = process
        runningProcess?.terminationHandler = nil

        inputHandle?.closeFile()
        outputHandle?.closeFile()
        errorHandle?.closeFile()

        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        outputBuffer = CodexRPCLineBuffer()

        if terminate, runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
    }

    @discardableResult
    private func sendRequest(
        method: String,
        params: Any,
        kind: RequestKind
    ) -> Int? {
        let id = nextRequestID
        nextRequestID += 1
        pendingRequests[id] = kind

        guard send(["method": method, "id": id, "params": params]) else {
            pendingRequests.removeValue(forKey: id)
            return nil
        }
        return id
    }

    @discardableResult
    private func send(_ object: [String: Any]) -> Bool {
        guard let inputHandle else { return false }

        do {
            var data = try JSONSerialization.data(withJSONObject: object)
            // App Server's stdio protocol uses one JSON object per line.
            data.append(0x0A)
            try inputHandle.write(contentsOf: data)
            return true
        } catch {
            markFailure(L10n.string("error.communication"))
            return false
        }
    }

    private func consumeOutput(_ data: Data) {
        let sourceProcess = process
        do {
            for line in try outputBuffer.append(data) {
                // A response may restart the child; discard its remaining messages.
                guard process === sourceProcess else { return }
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                handleMessage(object)
            }
        } catch {
            stopAppServerForOutputFailure(L10n.string("error.app_server_output_too_large"))
        }
    }

    private func stopAppServerForOutputFailure(_ message: String) {
        restartWorkItem?.cancel()
        restartWorkItem = nil
        cancelRefreshTimeout()
        cancelUsageTimeout()
        pendingRequests.removeAll()
        rateLimitRequestSources.removeAll()
        usageRequestID = nil
        didInitialize = false
        clearAppServerResources(terminate: true)
        resetStandardErrorBuffer()
        markFailure(message)
    }

    private func consumeStandardError(_ data: Data) {
        guard !data.isEmpty else { return }

        standardErrorBufferLock.lock()
        defer { standardErrorBufferLock.unlock() }

        if data.count >= maximumStandardErrorBytes {
            standardErrorBuffer = Data(data.suffix(maximumStandardErrorBytes))
            return
        }

        standardErrorBuffer.append(data)
        if standardErrorBuffer.count > maximumStandardErrorBytes {
            standardErrorBuffer.removeFirst(
                standardErrorBuffer.count - maximumStandardErrorBytes
            )
        }
    }

    private func resetStandardErrorBuffer() {
        standardErrorBufferLock.lock()
        standardErrorBuffer.removeAll(keepingCapacity: true)
        standardErrorBufferLock.unlock()
    }

    private func drainStandardErrorBuffer() -> Data {
        standardErrorBufferLock.lock()
        defer { standardErrorBufferLock.unlock() }

        let data = standardErrorBuffer
        standardErrorBuffer.removeAll(keepingCapacity: true)
        return data
    }

    private func appServerStoppedMessage(
        standardError: Data,
        terminationStatus: Int32,
        terminationReason: Process.TerminationReason
    ) -> String {
        if CodexProcessDiagnostic.isNodeRuntimeMissing(in: standardError) {
            return L10n.string("error.node_runtime_not_found")
        }
        if terminationReason == .exit, terminationStatus != 0 {
            return L10n.format(
                "error.app_server_stopped_status_format",
                Int(terminationStatus)
            )
        }
        return L10n.string("error.app_server_stopped")
    }

    private func handleMessage(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            switch method {
            case "account/updated":
                handleAccountUpdated()
            case "account/rateLimits/updated":
                // A server-side quota change should bypass the next scheduled refresh.
                refresh(forceTokenRefresh: false, source: .notification)
            default:
                break
            }
            return
        }

        guard let id = message["id"] as? Int else { return }
        guard let kind = pendingRequests.removeValue(forKey: id) else {
            // Ignore late responses from an App Server that was replaced during recovery.
            return
        }
        let rateLimitSource = rateLimitRequestSources.removeValue(forKey: id) ?? .refresh

        if kind == .usage {
            finishUsageRequest(id: id)
        }

        if let error = message["error"] as? [String: Any] {
            let text = L10n.string(CodexProcessDiagnostic.rpcErrorLocalizationKey(error))
            if (kind == .account || kind == .rateLimits),
               restartAppServerAfterAccountFailure() {
                return
            }

            if kind == .rateLimits {
                cancelRefreshTimeout()
                markFailure(text)
            } else if kind == .usage {
                isTokenUsageUnavailable = true
                tokenUsageErrorMessage = text
            } else if kind == .account {
                errorMessage = text
            } else {
                markFailure(text)
            }
            return
        }

        guard let result = message["result"] as? [String: Any] else {
            return
        }

        switch kind {
        case .initialize:
            didInitialize = true
            _ = send(["method": "initialized", "params": [:]])
            refresh()
        case .account:
            parseAccount(result)
        case .rateLimits:
            cancelRefreshTimeout()
            parseRateLimits(result, source: rateLimitSource)
        case .usage:
            parseTokenUsage(result)
        }
    }

    private func handleAccountUpdated() {
        cancelRefreshTimeout()
        pendingRequests = pendingRequests.filter { $0.value == .initialize }
        rateLimitRequestSources.removeAll()
        cancelUsageTimeout()
        usageRequestID = nil
        isRefreshInFlight = false

        // Never keep the previous account's quota visible after an explicit auth change.
        windows = []
        planType = nil
        lastUpdated = nil
        isLoading = true
        isStale = false
        errorMessage = nil
        tokenUsage = nil
        isTokenUsageUnavailable = false
        tokenUsageErrorMessage = nil
        rateLimitResetCredits = nil
        historyAccountKey = nil
        hasPendingAccountBoundary = true
        history.deactivateAccount()
        notificationManager.resetEvaluationState()

        // App Server has already applied the auth change. Force its managed ChatGPT
        // token refresh before asking for the new account's quota.
        refresh(forceTokenRefresh: true, source: .notification)
    }

    private func parseAccount(_ result: [String: Any]) {
        let account = result["account"] as? [String: Any]
        let type = account?["type"] as? String
        let plan = account?["planType"] as? String

        if type == "chatgpt" {
            planType = plan ?? "unknown"
        } else if type == "apiKey" {
            planType = "API Key"
        } else if type == "amazonBedrock" {
            planType = "Bedrock"
        } else if account == nil {
            errorMessage = L10n.string("error.not_logged_in")
            historyAccountKey = nil
            hasPendingAccountBoundary = false
            history.deactivateAccount()
            return
        }

        guard let type else { return }

        let identity = HistoryAccountIdentity.make(
            accountType: type,
            email: account?["email"] as? String,
            salt: settings.historyIdentitySalt
        )
        let accountChanged = historyAccountKey != identity.key || hasPendingAccountBoundary
        let shouldResetAnonymousHistory = hasPendingAccountBoundary && !identity.isStable
        historyAccountKey = identity.key
        hasPendingAccountBoundary = false

        if accountChanged {
            history.activateAccount(
                identity.key,
                resetExisting: shouldResetAnonymousHistory,
                claimLegacyHistory: identity.isStable
            )

            // A rate-limit response can arrive before account/read. Save the live
            // snapshot once its owning account is known instead of dropping it.
            if let lastUpdated, !windows.isEmpty {
                history.recordQuota(
                    windows: windows,
                    at: lastUpdated,
                    isStale: isStale,
                    source: .refresh,
                    retention: settings.historyRetention,
                    accountKey: identity.key
                )
            }
        }

        // Token usage is requested only after the account identity is known so a
        // late response can never be written into another account's partition.
        requestTokenUsageIfNeeded()
    }

    private func parseRateLimits(_ result: [String: Any], source: QuotaSampleSource) {
        var parsed: [CodexUsageWindow] = []

        // Support both current multi-bucket responses and the legacy single snapshot.
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any],
           !buckets.isEmpty {
            for (bucketID, value) in buckets {
                guard let snapshot = value as? [String: Any] else { continue }
                parsed.append(contentsOf: parseSnapshot(snapshot, fallbackID: bucketID))
            }
        } else if let snapshot = result["rateLimits"] as? [String: Any] {
            parsed = parseSnapshot(snapshot, fallbackID: "codex")
        }

        // Shorter windows appear first in the details popover.
        parsed.sort {
            ($0.windowDurationMins ?? Int.max) < ($1.windowDurationMins ?? Int.max)
        }

        guard !parsed.isEmpty else {
            if restartAppServerAfterAccountFailure() {
                return
            }
            markFailure(L10n.string("error.no_windows"))
            return
        }

        let updatedAt = Date()
        windows = parsed
        rateLimitResetCredits = CodexRateLimitResetCreditsSummary.decode(
            fromRateLimitsResult: result
        )
        isLoading = false
        isRefreshInFlight = false
        isStale = false
        lastUpdated = updatedAt
        errorMessage = nil
        didAttemptAccountRecovery = false

        if let historyAccountKey {
            history.recordQuota(
                windows: parsed,
                at: updatedAt,
                isStale: false,
                source: source,
                retention: settings.historyRetention,
                accountKey: historyAccountKey
            )
        }

        if settings.notificationsEnabled {
            notificationManager.evaluate(
                windows: parsed,
                threshold: settings.notificationThreshold
            )
        }
    }

    private func requestTokenUsageIfNeeded() {
        guard usageRequestID == nil else { return }
        guard let id = sendRequest(
            method: "account/usage/read",
            params: NSNull(),
            kind: .usage
        ) else {
            return
        }
        usageRequestID = id
        scheduleUsageTimeout(for: id)
    }

    private func parseTokenUsage(_ result: [String: Any]) {
        guard let summaryObject = result["summary"] as? [String: Any] else {
            isTokenUsageUnavailable = true
            tokenUsageErrorMessage = L10n.string("history.tokens.unavailable")
            return
        }

        let buckets: [TokenUsageDailyBucket]?
        if let rawBuckets = result["dailyUsageBuckets"] as? [[String: Any]] {
            buckets = rawBuckets.compactMap { object in
                guard let startDate = object["startDate"] as? String,
                      let tokens = int64(object["tokens"]) else {
                    return nil
                }
                return TokenUsageDailyBucket(startDate: startDate, tokens: tokens)
            }
        } else {
            buckets = nil
        }

        let snapshot = TokenUsageSnapshot(
            dailyBuckets: buckets,
            summary: TokenUsageSummary(
                lifetimeTokens: int64(summaryObject["lifetimeTokens"]),
                peakDailyTokens: int64(summaryObject["peakDailyTokens"]),
                currentStreakDays: int64(summaryObject["currentStreakDays"]),
                longestStreakDays: int64(summaryObject["longestStreakDays"]),
                longestRunningTurnSeconds: int64(summaryObject["longestRunningTurnSec"])
            ),
            fetchedAt: Date()
        )
        tokenUsage = snapshot
        isTokenUsageUnavailable = false
        tokenUsageErrorMessage = nil
        if let historyAccountKey {
            history.recordTokenUsage(
                snapshot,
                retention: settings.historyRetention,
                accountKey: historyAccountKey
            )
        }
    }

    private func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        return value as? Int64
    }

    private func parseSnapshot(
        _ snapshot: [String: Any],
        fallbackID: String
    ) -> [CodexUsageWindow] {
        let limitID = snapshot["limitId"] as? String ?? fallbackID
        let rawName = snapshot["limitName"] as? String
        let bucketName = friendlyBucketName(rawName ?? limitID)
        var result: [CodexUsageWindow] = []

        if let primary = snapshot["primary"] as? [String: Any],
           let window = makeWindow(primary, id: "\(limitID)-primary", bucketName: bucketName) {
            result.append(window)
        }

        if let secondary = snapshot["secondary"] as? [String: Any],
           let window = makeWindow(secondary, id: "\(limitID)-secondary", bucketName: bucketName) {
            result.append(window)
        }

        return result
    }

    private func makeWindow(
        _ object: [String: Any],
        id: String,
        bucketName: String
    ) -> CodexUsageWindow? {
        guard let usedPercent = object["usedPercent"] as? Int else { return nil }

        let duration = object["windowDurationMins"] as? Int
        let resetTimestamp = (object["resetsAt"] as? NSNumber)?.doubleValue
        let durationName = friendlyDuration(duration)
        let displayName = bucketName == "Codex"
            ? durationName
            : L10n.format("duration.bucket_format", bucketName, durationName)

        return CodexUsageWindow(
            id: id,
            name: displayName,
            usedPercent: usedPercent,
            windowDurationMins: duration,
            resetsAt: resetTimestamp.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func friendlyDuration(_ minutes: Int?) -> String {
        guard let minutes else { return L10n.string("duration.quota") }
        switch minutes {
        case 300:
            return L10n.string("duration.five_hours")
        case 10_080:
            return L10n.string("duration.weekly")
        case let value where value.isMultiple(of: 1_440):
            return L10n.format("duration.days_format", value / 1_440)
        case let value where value.isMultiple(of: 60):
            return L10n.format("duration.hours_format", value / 60)
        default:
            return L10n.format("duration.minutes_format", minutes)
        }
    }

    private func friendlyBucketName(_ value: String) -> String {
        switch value.lowercased() {
        case "codex": return "Codex"
        default:
            return value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func scheduleRefreshTimeout(for requestID: Int) {
        cancelRefreshTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingRequests[requestID] == .rateLimits else {
                return
            }
            self.pendingRequests.removeValue(forKey: requestID)
            self.rateLimitRequestSources.removeValue(forKey: requestID)
            if self.restartAppServerAfterAccountFailure() {
                return
            }
            self.markFailure(L10n.string("error.request_timeout"))
        }
        refreshTimeout = workItem
        // Avoid leaving the UI in a permanent loading state if App Server stalls.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: workItem)
    }

    private func cancelRefreshTimeout() {
        refreshTimeout?.cancel()
        refreshTimeout = nil
    }

    private func scheduleUsageTimeout(for requestID: Int) {
        cancelUsageTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.usageRequestID == requestID else { return }
            self.pendingRequests.removeValue(forKey: requestID)
            self.usageRequestID = nil
            self.isTokenUsageUnavailable = true
            self.tokenUsageErrorMessage = L10n.string("error.request_timeout")
        }
        usageTimeout = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: workItem)
    }

    private func finishUsageRequest(id: Int) {
        guard usageRequestID == id else { return }
        usageRequestID = nil
        cancelUsageTimeout()
    }

    private func cancelUsageTimeout() {
        usageTimeout?.cancel()
        usageTimeout = nil
    }

    @discardableResult
    private func restartAppServerAfterAccountFailure() -> Bool {
        guard !didAttemptAccountRecovery, restartWorkItem == nil else {
            return false
        }

        didAttemptAccountRecovery = true
        cancelRefreshTimeout()
        pendingRequests.removeAll()
        rateLimitRequestSources.removeAll()
        cancelUsageTimeout()
        usageRequestID = nil
        didInitialize = false
        isRefreshInFlight = false

        if windows.isEmpty {
            isLoading = true
        } else {
            isStale = true
        }
        errorMessage = nil

        clearAppServerResources(terminate: true)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            self.start()
        }
        restartWorkItem = workItem

        // Give Codex a brief moment to finish replacing its persisted login state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        return true
    }

    private func markFailure(_ message: String) {
        isLoading = false
        isRefreshInFlight = false
        // Preserve the last successful snapshot and explicitly mark it as stale.
        isStale = !windows.isEmpty
        errorMessage = message
    }

    private func locateCodexExecutable() -> URL? {
        CodexExecutableLocator.locate(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    deinit {
        refreshTimer?.invalidate()
        refreshTimeout?.cancel()
        usageTimeout?.cancel()
        restartWorkItem?.cancel()
        clearAppServerResources(terminate: true)
    }
}
