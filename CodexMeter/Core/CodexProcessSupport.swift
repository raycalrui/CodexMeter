import Foundation

enum CodexProcessEnvironment {
    static func make(
        baseEnvironment: [String: String],
        executableURL: URL,
        homeDirectory: URL
    ) -> [String: String] {
        var environment = baseEnvironment
        let preferredPaths = [
            executableURL.deletingLastPathComponent().standardizedFileURL.path,
            homeDirectory.appendingPathComponent(".local/bin").path,
            homeDirectory.appendingPathComponent(".npm-global/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        let inheritedPaths = baseEnvironment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init) ?? []

        var seen: Set<String> = []
        let paths = (preferredPaths + inheritedPaths).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
        environment["PATH"] = paths.joined(separator: ":")
        return environment
    }
}

enum CodexProcessDiagnostic {
    static func isNodeRuntimeMissing(in standardError: Data) -> Bool {
        let message = String(decoding: standardError, as: UTF8.self).lowercased()
        return message.contains("env: node: no such file or directory")
            || message.contains("node: command not found")
    }
}
