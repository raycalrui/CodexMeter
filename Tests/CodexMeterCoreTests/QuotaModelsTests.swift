import XCTest
@testable import CodexMeterCore

/// Covers boundary behavior that directly drives menu bar colors and pace labels.
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

    func testAttentionLevelWarnsWhenUsageIsAbovePace() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = CodexUsageWindow(
            id: "test",
            name: "Test",
            usedPercent: 60,
            windowDurationMins: 100,
            resetsAt: now.addingTimeInterval(50 * 60)
        )

        XCTAssertEqual(window.attentionLevel(at: now), .warning)
    }

    func testAttentionLevelPrioritizesCriticalQuotaBelowTwentyPercent() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = CodexUsageWindow(
            id: "test",
            name: "Test",
            usedPercent: 81,
            windowDurationMins: 100,
            resetsAt: now.addingTimeInterval(10 * 60)
        )

        XCTAssertEqual(window.attentionLevel(at: now), .critical)
    }

    func testTwentyPercentIsNotYetCritical() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = CodexUsageWindow(
            id: "test",
            name: "Test",
            usedPercent: 80,
            windowDurationMins: 100,
            resetsAt: now.addingTimeInterval(10 * 60)
        )

        XCTAssertNotEqual(window.attentionLevel(at: now), .critical)
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

    func testDeveloperAppearanceClampsUnsafeRenderingValues() {
        var appearance = MenuBarAppearance()
        appearance.percentageFontSize = 100
        appearance.captionFontSize = -10
        appearance.itemHeight = 0
        appearance.ringDiameter = 200
        appearance.outerRingStrokeWidth = 0
        appearance.ringGap = 20
        appearance.trackOpacity = 2
        appearance.horizontalPadding = -5
        appearance.captionText = String(repeating: "x", count: 100)

        let normalized = appearance.normalized()

        XCTAssertEqual(normalized.percentageFontSize, 14)
        XCTAssertEqual(normalized.captionFontSize, 5)
        XCTAssertEqual(normalized.itemHeight, 18)
        XCTAssertEqual(normalized.ringDiameter, 20)
        XCTAssertEqual(normalized.outerRingStrokeWidth, 1)
        XCTAssertEqual(normalized.ringGap, 3)
        XCTAssertEqual(normalized.trackOpacity, 0.5)
        XCTAssertEqual(normalized.horizontalPadding, 0)
        XCTAssertEqual(normalized.captionText.count, 24)
    }

    func testWarningPreviewPresetIsDeterministic() {
        let snapshot = DeveloperPreviewPreset.warning.snapshot

        XCTAssertEqual(snapshot.remainingPercent, 38)
        XCTAssertEqual(snapshot.remainingTimePercent, 62)
        XCTAssertEqual(snapshot.attentionLevel, .warning)
        XCTAssertFalse(snapshot.isStale)
    }

    func testMissingResetPreviewDoesNotInventRemainingTime() {
        let snapshot = DeveloperPreviewPreset.missingReset.snapshot

        XCTAssertEqual(snapshot.remainingPercent, 56)
        XCTAssertNil(snapshot.remainingTimePercent)
    }

    func testCustomPreviewUsesQuotaAndTimeToDeriveAttention() {
        let safe = MenuBarPreviewSnapshot.custom(
            remainingPercent: 70,
            remainingTimePercent: 40
        )
        let warning = MenuBarPreviewSnapshot.custom(
            remainingPercent: 40,
            remainingTimePercent: 70
        )
        let critical = MenuBarPreviewSnapshot.custom(
            remainingPercent: 19,
            remainingTimePercent: 10
        )

        XCTAssertEqual(safe.attentionLevel, .normal)
        XCTAssertEqual(warning.attentionLevel, .warning)
        XCTAssertEqual(critical.attentionLevel, .critical)
    }

    func testCustomPreviewClampsSliderValues() {
        let snapshot = MenuBarPreviewSnapshot.custom(
            remainingPercent: 140,
            remainingTimePercent: -20
        )

        XCTAssertEqual(snapshot.remainingPercent, 100)
        XCTAssertEqual(snapshot.remainingTimePercent, 0)
        XCTAssertEqual(snapshot.title, "100%")
    }

    private func makeWindow(
        used: Int,
        elapsedFraction: Double = 0
    ) -> CodexUsageWindow {
        // Build deterministic windows relative to a fixed clock for stable tests.
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
