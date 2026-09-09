import Foundation
import Darwin

enum CodexProcessPipe {
    static func readAvailableData(from handle: FileHandle, maximumBytes: Int) throws -> Data {
        precondition(maximumBytes > 0)
        var data = Data(count: maximumBytes)
        let count = data.withUnsafeMutableBytes { bytes in
            // One POSIX read returns available pipe bytes immediately. Foundation's
            // length-based reads can wait for more bytes and stall a JSON-RPC exchange.
            var result: Int
            repeat {
                result = Darwin.read(handle.fileDescriptor, bytes.baseAddress, maximumBytes)
            } while result < 0 && errno == EINTR
            return result
        }
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        data.count = count
        return data
    }
}

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
    static func rpcErrorLocalizationKey(_ error: [String: Any]) -> String {
        // Upstream messages and error data can contain credentials or account details.
        // Only allow known protocol codes to select locally authored UI text.
        switch error["code"] as? Int {
        case -32601: return "error.app_server_method_unavailable"
        default: return "error.app_server_request_failed"
        }
    }

    static func isNodeRuntimeMissing(in standardError: Data) -> Bool {
        let message = String(decoding: standardError, as: UTF8.self).lowercased()
        return message.contains("env: node: no such file or directory")
            || message.contains("node: command not found")
    }
}

/// Frames newline-delimited JSON without retaining an unbounded partial response.
struct CodexRPCLineBuffer: Sendable {
    enum Failure: Error {
        case messageTooLarge
    }

    let maximumMessageBytes: Int
    private(set) var bufferedData = Data()

    init(maximumMessageBytes: Int = 1_024 * 1_024) {
        precondition(maximumMessageBytes > 0)
        self.maximumMessageBytes = maximumMessageBytes
    }

    mutating func append(_ data: Data) throws -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 0x0A)
            let end = newline ?? data.endIndex
            let fragment = data[start..<end]
            guard fragment.count <= maximumMessageBytes - bufferedData.count else {
                bufferedData = Data()
                throw Failure.messageTooLarge
            }
            bufferedData.append(contentsOf: fragment)
            guard let newline else { break }
            if !bufferedData.isEmpty {
                lines.append(bufferedData)
                bufferedData = Data()
            }
            start = data.index(after: newline)
        }
        return lines
    }
}
