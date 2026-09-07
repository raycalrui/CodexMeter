import Foundation
import XCTest
@testable import CodexMeterCore

final class CodexProcessSupportTests: XCTestCase {
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
