import Combine
import Foundation

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
    private var outputBuffer = Data()
    private var nextRequestID = 1
    private var pendingRequests: [Int: RequestKind] = [:]
    private var refreshTimer: Timer?
    private var refreshTimeout: DispatchWorkItem?
    private var didInitialize = false

    init(
        settings: AppSettings,
        notificationManager: NotificationManager = NotificationManager()
    ) {
        self.settings = settings
        self.notificationManager = notificationManager

        DispatchQueue.main.async { [weak self] in
            self?.installRefreshTimer()
            self?.start()
        }
    }

    var mostConstrainedRemainingPercent: Int? {
        windows.map(\.remainingPercent).min()
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
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeOutput(data)
        }

        errorPipe.fileHandleForReading.readabilityHandler = { _ in
            // App Server may emit harmless diagnostics to stderr. Protocol errors
            // are returned as JSON-RPC messages on stdout.
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.process != nil else { return }
                self.process = nil
                self.inputHandle = nil
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
            self.process = nil
            inputHandle = nil
            markFailure(L10n.format("error.app_server_start_format", error.localizedDescription))
        }
    }

    func refresh() {
        if process == nil {
            start()
            return
        }

        guard didInitialize, !isRefreshInFlight else { return }

        isRefreshInFlight = true
        if windows.isEmpty {
            isLoading = true
        }
        errorMessage = nil

        _ = sendRequest(
            method: "account/read",
            params: ["refreshToken": false],
            kind: .account
        )

        guard let requestID = sendRequest(
            method: "account/rateLimits/read",
            params: [:],
            kind: .rateLimits
        ) else {
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
            settings.settingsError = nil
            return
        }

        notificationManager.requestAuthorization { [weak self] granted, error in
            guard let self else { return }
            self.settings.notificationsEnabled = granted
            if granted {
                self.settings.settingsError = nil
                self.notificationManager.evaluate(
                    windows: self.windows,
                    threshold: self.settings.notificationThreshold
                )
            } else {
                self.settings.settingsError = error.map {
                    L10n.format("settings.notification_error_format", $0)
                } ?? L10n.string("settings.notification_denied")
            }
        }
    }

    private func installRefreshTimer() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
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
            data.append(0x0A)
            try inputHandle.write(contentsOf: data)
            return true
        } catch {
            markFailure(L10n.format("error.communication_format", error.localizedDescription))
            return false
        }
    }

    private func consumeOutput(_ data: Data) {
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
        if let method = message["method"] as? String,
           method == "account/rateLimits/updated" {
            refresh()
            return
        }

        guard let id = message["id"] as? Int else { return }
        let kind = pendingRequests.removeValue(forKey: id)

        if let error = message["error"] as? [String: Any] {
            let text = error["message"] as? String ?? L10n.string("error.unknown")
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

        guard let result = message["result"] as? [String: Any],
              let kind else {
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

        if let buckets = result["rateLimitsByLimitId"] as? [String: Any],
           !buckets.isEmpty {
            for (bucketID, value) in buckets {
                guard let snapshot = value as? [String: Any] else { continue }
                parsed.append(contentsOf: parseSnapshot(snapshot, fallbackID: bucketID))
            }
        } else if let snapshot = result["rateLimits"] as? [String: Any] {
            parsed = parseSnapshot(snapshot, fallbackID: "codex")
        }

        parsed.sort {
            ($0.windowDurationMins ?? Int.max) < ($1.windowDurationMins ?? Int.max)
        }

        guard !parsed.isEmpty else {
            markFailure(L10n.string("error.no_windows"))
            return
        }

        windows = parsed
        isLoading = false
        isRefreshInFlight = false
        isStale = false
        lastUpdated = Date()
        errorMessage = nil

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
            self.markFailure(L10n.string("error.request_timeout"))
        }
        refreshTimeout = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: workItem)
    }

    private func cancelRefreshTimeout() {
        refreshTimeout?.cancel()
        refreshTimeout = nil
    }

    private func markFailure(_ message: String) {
        isLoading = false
        isRefreshInFlight = false
        isStale = !windows.isEmpty
        errorMessage = message
    }

    private func locateCodexExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
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
        process?.terminationHandler = nil
        process?.terminate()
    }
}
