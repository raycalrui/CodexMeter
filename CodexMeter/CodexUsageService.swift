import Combine
import Foundation
import SwiftUI

struct CodexUsageWindow: Identifiable, Equatable {
    let id: String
    let name: String
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Date?

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    var tint: Color {
        switch remainingPercent {
        case 0..<20: return .red
        case 20..<40: return .orange
        default: return .accentColor
        }
    }
}

final class CodexUsageService: ObservableObject {
    @Published private(set) var windows: [CodexUsageWindow] = []
    @Published private(set) var planType: String?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputBuffer = Data()
    private var nextRequestID = 3
    private var didInitialize = false

    init() {
        DispatchQueue.main.async { [weak self] in
            self?.start()
        }
    }

    var menuBarTitle: String {
        guard let remaining = windows.map(\.remainingPercent).min() else {
            return isLoading ? "…" : "--"
        }
        return "\(remaining)%"
    }

    var menuBarSymbol: String {
        guard let remaining = windows.map(\.remainingPercent).min() else {
            return errorMessage == nil ? "gauge.with.dots.needle.0percent" : "exclamationmark.triangle"
        }

        switch remaining {
        case 0..<20: return "gauge.with.dots.needle.100percent"
        case 20..<60: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.33percent"
        }
    }

    var accountDescription: String {
        guard let planType else { return "正在确认账户…" }
        return "ChatGPT \(planType.capitalized)"
    }

    func start() {
        guard process == nil else { return }

        setLoading(true)

        guard let codexURL = locateCodexExecutable() else {
            finishWithError("找不到 Codex CLI。请先安装 Codex，并在终端中完成登录。")
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
            // App Server may write harmless diagnostics to stderr. JSON-RPC errors
            // arrive on stdout and are handled separately.
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.process != nil else { return }
                self.process = nil
                self.inputHandle = nil
                self.didInitialize = false
                self.isLoading = false
                if self.windows.isEmpty {
                    self.errorMessage = "Codex App Server 已停止。"
                }
            }
        }

        do {
            try process.run()
            self.process = process
            inputHandle = inputPipe.fileHandleForWriting

            send([
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": [
                        "name": "codex_meter",
                        "title": "Codex Meter",
                        "version": appVersion
                    ]
                ]
            ])
        } catch {
            self.process = nil
            inputHandle = nil
            finishWithError("无法启动 Codex App Server：\(error.localizedDescription)")
        }
    }

    func refresh() {
        if process == nil {
            start()
            return
        }

        guard didInitialize else { return }
        setLoading(true)
        requestAccount()
        requestRateLimits()
    }

    private func requestAccount() {
        send([
            "method": "account/read",
            "id": 2,
            "params": ["refreshToken": false]
        ])
    }

    private func requestRateLimits() {
        let requestID = nextRequestID
        nextRequestID += 1
        send([
            "method": "account/rateLimits/read",
            "id": requestID,
            "params": [:]
        ])
    }

    private func send(_ object: [String: Any]) {
        guard let inputHandle else { return }

        do {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try inputHandle.write(contentsOf: data)
        } catch {
            finishWithError("无法与 Codex 通信：\(error.localizedDescription)")
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

            handleMessage(object)
        }
    }

    private func handleMessage(_ message: [String: Any]) {
        if let error = message["error"] as? [String: Any] {
            let text = error["message"] as? String ?? "Codex 返回了未知错误。"
            finishWithError(text)
            return
        }

        if let method = message["method"] as? String,
           method == "account/rateLimits/updated" {
            requestRateLimits()
            return
        }

        guard let id = message["id"] as? Int,
              let result = message["result"] as? [String: Any] else {
            return
        }

        switch id {
        case 1:
            didInitialize = true
            send(["method": "initialized", "params": [:]])
            requestAccount()
            requestRateLimits()
        case 2:
            parseAccount(result)
        default:
            parseRateLimits(result)
        }
    }

    private func parseAccount(_ result: [String: Any]) {
        let account = result["account"] as? [String: Any]
        let type = account?["type"] as? String
        let plan = account?["planType"] as? String

        DispatchQueue.main.async {
            if type == "chatgpt" {
                self.planType = plan ?? "unknown"
            } else if type == "apiKey" {
                self.planType = "API Key"
            } else if account == nil {
                self.errorMessage = "Codex 尚未登录 ChatGPT 账户。"
            }
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

        DispatchQueue.main.async {
            self.windows = parsed
            self.isLoading = false
            self.lastUpdated = Date()
            self.errorMessage = parsed.isEmpty ? "账户没有返回可显示的额度窗口。" : nil
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
        let resetTimestamp = object["resetsAt"] as? TimeInterval
        let durationName = friendlyDuration(duration)
        let displayName = bucketName == "Codex" ? durationName : "\(bucketName) · \(durationName)"

        return CodexUsageWindow(
            id: id,
            name: displayName,
            usedPercent: usedPercent,
            windowDurationMins: duration,
            resetsAt: resetTimestamp.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func friendlyDuration(_ minutes: Int?) -> String {
        guard let minutes else { return "额度" }
        switch minutes {
        case 300: return "5 小时额度"
        case 10_080: return "每周额度"
        case let value where value.isMultiple(of: 1_440):
            return "\(value / 1_440) 天额度"
        case let value where value.isMultiple(of: 60):
            return "\(value / 60) 小时额度"
        default:
            return "\(minutes) 分钟额度"
        }
    }

    private func friendlyBucketName(_ value: String) -> String {
        switch value.lowercased() {
        case "codex": return "Codex"
        default:
            return value.replacingOccurrences(of: "_", with: " ").capitalized
        }
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

    private func setLoading(_ value: Bool) {
        DispatchQueue.main.async {
            self.isLoading = value
            if value {
                self.errorMessage = nil
            }
        }
    }

    private func finishWithError(_ message: String) {
        DispatchQueue.main.async {
            self.isLoading = false
            self.errorMessage = message
        }
    }

    deinit {
        process?.terminationHandler = nil
        process?.terminate()
    }
}
