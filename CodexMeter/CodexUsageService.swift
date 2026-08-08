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

    private enum RequestKind: Equatable {
        case initialize
        case account
        case rateLimits
    }

    private let settings: AppSettings
    private let notificationManager: NotificationManager
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputBuffer = Data()
    private var nextRequestID = 1
    // Request IDs let responses arrive independently without losing their type.
    private var pendingRequests: [Int: RequestKind] = [:]
    private var refreshTimer: Timer?
    private var refreshTimeout: DispatchWorkItem?
    private var restartWorkItem: DispatchWorkItem?
    private var didInitialize = false
    private var didAttemptAccountRecovery = false

    init(
        settings: AppSettings,
        notificationManager: NotificationManager = NotificationManager()
    ) {
        self.settings = settings
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
        // stdio transport keeps account credentials inside the official Codex process.
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading

        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.consumeOutput(data)
        }

        errorHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            // App Server may emit harmless diagnostics to stderr. Protocol errors
            // are returned as JSON-RPC messages on stdout. Always drain stderr so
            // unread bytes cannot keep the file descriptor continuously readable.
        }

        process.terminationHandler = { [weak self, weak process] _ in
            outputHandle.readabilityHandler = nil
            errorHandle.readabilityHandler = nil

            DispatchQueue.main.async {
                guard let self, self.process === process else { return }
                self.clearAppServerResources()
                self.didInitialize = false
                self.pendingRequests.removeAll()
                self.cancelRefreshTimeout()
                self.markFailure(L10n.string("error.app_server_stopped"))
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
            markFailure(L10n.format("error.app_server_start_format", error.localizedDescription))
        }
    }

    func refresh() {
        refresh(forceTokenRefresh: false)
    }

    private func refresh(forceTokenRefresh: Bool) {
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

        if terminate, runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
    }

    @discardableResult
    private func sendRequest(
        method: String,
        params: [String: Any],
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
            markFailure(L10n.format("error.communication_format", error.localizedDescription))
            return false
        }
    }

    private func consumeOutput(_ data: Data) {
        // Pipe reads may split or combine messages, so retain bytes until a newline.
        outputBuffer.append(data)

        while let newlineIndex = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newlineIndex]
            outputBuffer.removeSubrange(...newlineIndex)

            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                continue
            }

            DispatchQueue.main.async { [weak self] in
                self?.handleMessage(object)
            }
        }
    }

    private func handleMessage(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            switch method {
            case "account/updated":
                handleAccountUpdated()
            case "account/rateLimits/updated":
                // A server-side quota change should bypass the next scheduled refresh.
                refresh()
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

        if let error = message["error"] as? [String: Any] {
            let text = error["message"] as? String ?? L10n.string("error.unknown")
            if (kind == .account || kind == .rateLimits),
               restartAppServerAfterAccountFailure() {
                return
            }

            if kind == .rateLimits {
                cancelRefreshTimeout()
                markFailure(text)
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
            parseRateLimits(result)
        }
    }

    private func handleAccountUpdated() {
        cancelRefreshTimeout()
        pendingRequests = pendingRequests.filter { $0.value == .initialize }
        isRefreshInFlight = false

        // Never keep the previous account's quota visible after an explicit auth change.
        windows = []
        planType = nil
        lastUpdated = nil
        isLoading = true
        isStale = false
        errorMessage = nil
        notificationManager.resetEvaluationState()

        // App Server has already applied the auth change. Force its managed ChatGPT
        // token refresh before asking for the new account's quota.
        refresh(forceTokenRefresh: true)
    }

    private func parseAccount(_ result: [String: Any]) {
        let account = result["account"] as? [String: Any]
        let type = account?["type"] as? String
        let plan = account?["planType"] as? String

        if type == "chatgpt" {
            planType = plan ?? "unknown"
        } else if type == "apiKey" {
            planType = "API Key"
        } else if account == nil {
            errorMessage = L10n.string("error.not_logged_in")
        }
    }

    private func parseRateLimits(_ result: [String: Any]) {
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

        windows = parsed
        isLoading = false
        isRefreshInFlight = false
        isStale = false
        lastUpdated = Date()
        errorMessage = nil
        didAttemptAccountRecovery = false

        if settings.notificationsEnabled {
            notificationManager.evaluate(
                windows: parsed,
                threshold: settings.notificationThreshold
            )
        }
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

    @discardableResult
    private func restartAppServerAfterAccountFailure() -> Bool {
        guard !didAttemptAccountRecovery, restartWorkItem == nil else {
            return false
        }

        didAttemptAccountRecovery = true
        cancelRefreshTimeout()
        pendingRequests.removeAll()
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
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Keep discovery deterministic and never invoke a shell to resolve PATH.
        let candidates = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.npm-global/bin/codex"
        ]

        return candidates
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    deinit {
        refreshTimer?.invalidate()
        refreshTimeout?.cancel()
        restartWorkItem?.cancel()
        clearAppServerResources(terminate: true)
    }
}
