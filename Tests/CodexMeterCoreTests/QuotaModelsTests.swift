import XCTest
@testable import CodexMeterCore

final class QuotaModelsTests: XCTestCase {
    private let sevenDays = 7 * 24 * 60
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRemainingQuotaIsClampedToValidPercentage() {
        XCTAssertEqual(makeWindow(used: -10).remainingPercent, 100)
        XCTAssertEqual(makeWindow(used: 40).remainingPercent, 60)
        XCTAssertEqual(makeWindow(used: 140).remainingPercent, 0)
    }

    func testHalfwayThroughWindowUsesFiftyPercentRemainingTime() throws {
        let window = makeWindow(used: 50, elapsedFraction: 0.5)
        let remainingTime = try XCTUnwrap(window.remainingTimePercent(at: now))

        XCTAssertEqual(remainingTime, 50, accuracy: 0.001)
        XCTAssertEqual(window.pace(at: now), .onTrack)
        XCTAssertEqual(try XCTUnwrap(window.paceDelta(at: now)), 0, accuracy: 0.001)
    }

    func testUsageAboveElapsedTimeIsOverPace() {
        let window = makeWindow(used: 60, elapsedFraction: 0.5)

        XCTAssertEqual(window.remainingPercent, 40)
        XCTAssertEqual(window.pace(at: now), .overPace)
    }

    func testUsageBelowElapsedTimeIsOnTrack() {
        let window = makeWindow(used: 40, elapsedFraction: 0.5)

        XCTAssertEqual(window.remainingPercent, 60)
        XCTAssertEqual(window.pace(at: now), .onTrack)
    }

    func testMissingResetDataDoesNotGuessPace() {
        let missingReset = CodexUsageWindow(
            id: "missing-reset",
            name: "Weekly",
            usedPercent: 20,
            windowDurationMins: sevenDays,
            resetsAt: nil
        )
        let missingDuration = CodexUsageWindow(
            id: "missing-duration",
            name: "Weekly",
            usedPercent: 20,
            windowDurationMins: nil,
            resetsAt: now.addingTimeInterval(3_600)
        )

        XCTAssertNil(missingReset.remainingTimePercent(at: now))
        XCTAssertEqual(missingReset.pace(at: now), .unavailable)
        XCTAssertNil(missingDuration.remainingTimePercent(at: now))
        XCTAssertEqual(missingDuration.pace(at: now), .unavailable)
    }

    func testExpiredResetDoesNotGuessPace() {
        let window = CodexUsageWindow(
            id: "expired",
            name: "Weekly",
            usedPercent: 20,
            windowDurationMins: sevenDays,
            resetsAt: now.addingTimeInterval(-1)
        )

        XCTAssertNil(window.remainingTimePercent(at: now))
        XCTAssertEqual(window.pace(at: now), .unavailable)
    }

    func testRemainingTimeIsClampedAtWindowStart() throws {
        let window = CodexUsageWindow(
            id: "future",
            name: "Weekly",
            usedPercent: 0,
            windowDurationMins: sevenDays,
            resetsAt: now.addingTimeInterval(Double(sevenDays * 60) * 1.5)
        )

        XCTAssertEqual(
            try XCTUnwrap(window.remainingTimePercent(at: now)),
            100,
            accuracy: 0.001
        )
    }

    private func makeWindow(
        used: Int,
        elapsedFraction: Double = 0
    ) -> CodexUsageWindow {
        let durationSeconds = Double(sevenDays * 60)
        let remainingSeconds = durationSeconds * (1 - elapsedFraction)
        return CodexUsageWindow(
            id: "weekly",
            name: "Weekly",
            usedPercent: used,
            windowDurationMins: sevenDays,
            resetsAt: now.addingTimeInterval(remainingSeconds)
        )
    }
}
