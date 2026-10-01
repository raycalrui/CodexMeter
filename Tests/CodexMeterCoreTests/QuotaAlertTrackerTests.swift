import XCTest
@testable import CodexMeterCore

/// Covers alert transitions that decide whether a system notification is sent.
final class QuotaAlertTrackerTests: XCTestCase {
    private let fiveHours = 5 * 60
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testOverPaceAlertsOnceWhileHoveringAroundIdealPace() {
        var tracker = QuotaAlertTracker()
        let resetsAt = start.addingTimeInterval(Double(fiveHours) * 60)

        // Usage tracks elapsed time exactly, but whole-percent quota rounding
        // crosses the continuous time line roughly every three minutes.
        var alerts: [QuotaAlert] = []
        for minute in 30...120 {
            let date = start.addingTimeInterval(Double(minute) * 60)
            let used = Int((Double(minute) / 3).rounded())
            alerts += tracker.evaluate(
                windows: [makeWindow(id: "codex-primary", used: used, resetsAt: resetsAt)],
                threshold: 10,
                at: date
            ).map(\.alert)
        }

        XCTAssertEqual(alerts, [.overPace])
    }

    func testOverPaceAlertsAgainAfterRecoveringBeyondMargin() {
        var tracker = QuotaAlertTracker()
        let resetsAt = start.addingTimeInterval(Double(fiveHours) * 60)
        let halfway = start.addingTimeInterval(Double(fiveHours) * 30)

        XCTAssertEqual(evaluate(&tracker, used: 51, resetsAt: resetsAt, at: halfway), [.overPace])
        // Remaining time falls to 40% while quota stays at 49%: recovered by 9.
        let later = start.addingTimeInterval(Double(fiveHours) * 36)
        XCTAssertEqual(evaluate(&tracker, used: 51, resetsAt: resetsAt, at: later), [])
        // Heavy use pushes it back over pace.
        XCTAssertEqual(evaluate(&tracker, used: 70, resetsAt: resetsAt, at: later), [.overPace])
    }

    func testLowQuotaAlertsOncePerCycleAndRearmsAfterReset() {
        var tracker = QuotaAlertTracker()
        let firstReset = start.addingTimeInterval(Double(fiveHours) * 60)
        let early = start.addingTimeInterval(60)

        XCTAssertEqual(evaluate(&tracker, used: 80, resetsAt: firstReset, at: early), [.overPace, .lowQuota])
        XCTAssertEqual(evaluate(&tracker, used: 81, resetsAt: firstReset, at: early), [])
        XCTAssertEqual(evaluate(&tracker, used: 79, resetsAt: firstReset, at: early), [])

        let secondReset = firstReset.addingTimeInterval(Double(fiveHours) * 60)
        let afterReset = firstReset.addingTimeInterval(60)
        XCTAssertEqual(evaluate(&tracker, used: 0, resetsAt: secondReset, at: afterReset), [])
        XCTAssertEqual(
            evaluate(&tracker, used: 85, resetsAt: secondReset, at: afterReset.addingTimeInterval(60)),
            [.overPace, .lowQuota]
        )
    }

    func testSlotSwapKeepsEachWindowsState() {
        var tracker = QuotaAlertTracker()
        let fiveHourReset = start.addingTimeInterval(Double(fiveHours) * 60)
        let weeklyReset = start.addingTimeInterval(6 * 24 * 60 * 60)
        let fiveHour = { (slot: String) in
            CodexUsageWindow(id: slot, name: "5h", usedPercent: 90, windowDurationMins: self.fiveHours, resetsAt: fiveHourReset)
        }
        let weekly = { (slot: String) in
            CodexUsageWindow(id: slot, name: "Weekly", usedPercent: 5, windowDurationMins: 7 * 24 * 60, resetsAt: weeklyReset)
        }

        XCTAssertEqual(
            tracker.evaluate(windows: [fiveHour("codex-primary"), weekly("codex-secondary")], threshold: 20, at: start).count,
            2
        )
        XCTAssertEqual(
            tracker.evaluate(windows: [weekly("codex-primary"), fiveHour("codex-secondary")], threshold: 20, at: start),
            []
        )
    }

    func testStateSurvivesEncodingSoRelaunchDoesNotRepeatAlerts() throws {
        var tracker = QuotaAlertTracker()
        let resetsAt = start.addingTimeInterval(Double(fiveHours) * 60)
        XCTAssertEqual(evaluate(&tracker, used: 95, resetsAt: resetsAt, at: start), [.overPace, .lowQuota])

        let data = try JSONEncoder().encode(tracker)
        var relaunched = try JSONDecoder().decode(QuotaAlertTracker.self, from: data)
        XCTAssertEqual(evaluate(&relaunched, used: 95, resetsAt: resetsAt, at: start.addingTimeInterval(600)), [])
    }

    func testMissingResetTimingNeverAlertsPace() {
        var tracker = QuotaAlertTracker()
        XCTAssertEqual(evaluate(&tracker, used: 50, resetsAt: nil, at: start), [])
    }

    private func evaluate(
        _ tracker: inout QuotaAlertTracker,
        used: Int,
        resetsAt: Date?,
        at date: Date,
        threshold: Int = 20
    ) -> [QuotaAlert] {
        tracker.evaluate(
            windows: [makeWindow(id: "codex-primary", used: used, resetsAt: resetsAt)],
            threshold: threshold,
            at: date
        ).map(\.alert)
    }

    private func makeWindow(id: String, used: Int, resetsAt: Date?) -> CodexUsageWindow {
        CodexUsageWindow(
            id: id,
            name: "Codex",
            usedPercent: used,
            windowDurationMins: fiveHours,
            resetsAt: resetsAt
        )
    }
}
