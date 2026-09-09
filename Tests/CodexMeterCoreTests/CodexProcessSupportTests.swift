import Foundation
import XCTest
@testable import CodexMeterCore

final class CodexProcessSupportTests: XCTestCase {
    func testBoundedPipeReadReturnsShortMessagesWhileWriterRemainsOpen() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("hello".utf8))
        XCTAssertEqual(
            try CodexProcessPipe.readAvailableData(from: pipe.fileHandleForReading, maximumBytes: 2),
            Data("he".utf8)
        )
        XCTAssertEqual(
            try CodexProcessPipe.readAvailableData(from: pipe.fileHandleForReading, maximumBytes: 64 * 1_024),
            Data("llo".utf8)
        )
        try pipe.fileHandleForWriting.close()
        XCTAssertTrue(try CodexProcessPipe.readAvailableData(
            from: pipe.fileHandleForReading, maximumBytes: 64 * 1_024
        ).isEmpty)
    }

    func testRPCFramingPreservesSplitUTF8AndMultipleMessages() throws {
        var buffer = CodexRPCLineBuffer()
        let first = Data("{\"text\":\"中文\"}".utf8)
        let split = first.firstIndex(of: 0xE4)! + 1
        XCTAssertEqual(try buffer.append(first.prefix(split)), [])
        let remainder = first.suffix(from: split) + Data("\n\n{\"id\":2}\npartial".utf8)
        XCTAssertEqual(try buffer.append(remainder), [first, Data("{\"id\":2}".utf8)])
        XCTAssertEqual(buffer.bufferedData, Data("partial".utf8))
    }

    func testRPCFramingAcceptsExactByteLimitBeforeNewline() throws {
        var buffer = CodexRPCLineBuffer(maximumMessageBytes: 8)
        XCTAssertEqual(try buffer.append(Data("12345678".utf8)), [])
        XCTAssertEqual(try buffer.append(Data("\n".utf8)), [Data("12345678".utf8)])
        XCTAssertTrue(buffer.bufferedData.isEmpty)
    }

    func testRPCFramingRejectsOversizedPartialAndReleasesBufferedBytes() throws {
        var buffer = CodexRPCLineBuffer(maximumMessageBytes: 8)
        _ = try buffer.append(Data("12345678".utf8))
        XCTAssertThrowsError(try buffer.append(Data("9".utf8))) { error in
            guard case CodexRPCLineBuffer.Failure.messageTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(buffer.bufferedData.isEmpty)
    }

    func testRPCFramingRejectsOversizedCompleteMessage() {
        var buffer = CodexRPCLineBuffer(maximumMessageBytes: 8)
        XCTAssertThrowsError(try buffer.append(Data("123456789\n".utf8)))
        XCTAssertTrue(buffer.bufferedData.isEmpty)
    }

    func testRPCFramingLimitsEachMessageRatherThanCombinedRead() throws {
        var buffer = CodexRPCLineBuffer(maximumMessageBytes: 4)
        XCTAssertEqual(
            try buffer.append(Data("1234\n5678\n9012\n".utf8)),
            [Data("1234".utf8), Data("5678".utf8), Data("9012".utf8)]
        )
        XCTAssertTrue(buffer.bufferedData.isEmpty)
    }

    func testRPCFramingRejectsSustainedUnterminatedOutputAtProductionLimit() throws {
        var buffer = CodexRPCLineBuffer()
        let chunk = Data(repeating: 0x61, count: 64 * 1_024)
        for _ in 0..<16 {
            XCTAssertEqual(try buffer.append(chunk), [])
        }
        XCTAssertEqual(buffer.bufferedData.count, 1_024 * 1_024)
        XCTAssertThrowsError(try buffer.append(chunk))
        XCTAssertTrue(buffer.bufferedData.isEmpty)
    }

    func testRPCErrorDoesNotExposeMessageOrNestedData() {
        let sensitiveError: [String: Any] = [
            "code": -32000,
            "message": "user@example.com Authorization: Bearer secret-token /Users/example/auth.json",
            "data": ["refresh_token": "another-secret"]
        ]
        XCTAssertEqual(
            CodexProcessDiagnostic.rpcErrorLocalizationKey(sensitiveError),
            "error.app_server_request_failed"
        )
        XCTAssertEqual(
            CodexProcessDiagnostic.rpcErrorLocalizationKey([:]),
            "error.app_server_request_failed"
        )
        XCTAssertEqual(
            CodexProcessDiagnostic.rpcErrorLocalizationKey(["code": "user@example.com"]),
            "error.app_server_request_failed"
        )
    }

    func testRPCMethodUnavailableUsesOnlyKnownNumericCode() {
        XCTAssertEqual(
            CodexProcessDiagnostic.rpcErrorLocalizationKey([
                "code": -32601,
                "message": "secret-token"
            ]),
            "error.app_server_method_unavailable"
        )
    }

    func testEnvironmentLaunchesEnvNodeScriptWithMinimalInheritedPath() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let nodeURL = temporaryDirectory.appendingPathComponent("node")
        let codexURL = temporaryDirectory.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: nodeURL)
        try Data("#!/usr/bin/env node\n".utf8).write(to: codexURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: nodeURL.path
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: codexURL.path
        )

        let process = Process()
        process.executableURL = codexURL
        process.environment = CodexProcessEnvironment.make(
            baseEnvironment: ["PATH": "/usr/bin:/bin"],
            executableURL: codexURL,
            homeDirectory: URL(fileURLWithPath: "/Users/example")
        )

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testEnvironmentPrependsExecutableAndCommonRuntimePaths() {
        let environment = CodexProcessEnvironment.make(
            baseEnvironment: [
                "PATH": "/usr/bin:/bin",
                "LANG": "en_US.UTF-8"
            ],
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            homeDirectory: URL(fileURLWithPath: "/Users/example")
        )

        XCTAssertEqual(
            environment["PATH"],
            [
                "/opt/homebrew/bin",
                "/Users/example/.local/bin",
                "/Users/example/.npm-global/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin"
            ].joined(separator: ":")
        )
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
    }

    func testEnvironmentRemovesDuplicatePathsWithoutDroppingInheritedEntries() {
        let environment = CodexProcessEnvironment.make(
            baseEnvironment: [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/custom/bin"
            ],
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            homeDirectory: URL(fileURLWithPath: "/Users/example")
        )

        XCTAssertEqual(
            environment["PATH"]?.split(separator: ":").map(String.init),
            [
                "/opt/homebrew/bin",
                "/Users/example/.local/bin",
                "/Users/example/.npm-global/bin",
                "/usr/local/bin",
                "/custom/bin"
            ]
        )
    }

    func testNodeRuntimeFailureIsRecognizedWithoutExposingRawError() {
        let standardError = Data("env: node: No such file or directory\n".utf8)

        XCTAssertTrue(CodexProcessDiagnostic.isNodeRuntimeMissing(in: standardError))
    }

    func testUnrelatedStandardErrorIsNotReportedAsMissingNode() {
        let standardError = Data("warning: retrying request\n".utf8)

        XCTAssertFalse(CodexProcessDiagnostic.isNodeRuntimeMissing(in: standardError))
    }
}
