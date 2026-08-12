import Foundation
import XCTest
@testable import CodexMeterCore

final class ObservedQuotaConsumptionTests: XCTestCase {
    func testCompleteResetCyclesCanExceedOneHundredPercent() throws {
        let day = 24 * 60 * 60.0
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let firstReset = start.addingTimeInterval(7 * day)
        let secondReset = firstReset.addingTimeInterval(7 * day)
        let thirdReset = secondReset.addingTimeInterval(7 * day)
        let samples = [
            sample(id: 1, date: start.addingTimeInterval(60), remaining: 100, reset: firstReset),
            sample(id: 2, date: firstReset.addingTimeInterval(-5 * 60), remaining: 50, reset: firstReset),
            sample(id: 3, date: firstReset.addingTimeInterval(60), remaining: 100, reset: secondReset),
            sample(id: 4, date: secondReset.addingTimeInterval(-5 * 60), remaining: 20, reset: secondReset),
            sample(id: 5, date: secondReset.addingTimeInterval(60), remaining: 100, reset: thirdReset),
            sample(id: 6, date: thirdReset.addingTimeInterval(-5 * 60), remaining: 10, reset: thirdReset)
        ]

        let summary = try XCTUnwrap(ObservedQuotaConsumption.calculate(
            samples: samples,
            window: weeklyWindow(resetsAt: thirdReset),
            interval: DateInterval(start: start, end: thirdReset),
            usesLiveWindowReset: false
        ))

        XCTAssertEqual(summary.percent, 220)
        XCTAssertEqual(summary.cycleCount, 3)
        XCTAssertFalse(summary.isLowerBound)
    }

    func testPartialLeadingCycleReportsOnlyObservedDecreaseAsLowerBound() throws {
        let day = 24 * 60 * 60.0
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let reset = start.addingTimeInterval(7 * day)
        let intervalStart = start.addingTimeInterval(2 * day)
        let intervalEnd = start.addingTimeInterval(4 * day)
        let samples = [
            sample(id: 1, date: start.addingTimeInterval(day), remaining: 80, reset: reset),
            sample(id: 2, date: intervalStart.addingTimeInterval(60 * 60), remaining: 60, reset: reset),
            sample(id: 3, date: intervalEnd.addingTimeInterval(-5 * 60), remaining: 40, reset: reset)
        ]

        let summary = try XCTUnwrap(ObservedQuotaConsumption.calculate(
            samples: samples,
            window: weeklyWindow(resetsAt: reset),
            interval: DateInterval(start: intervalStart, end: intervalEnd),
            usesLiveWindowReset: false
        ))

        XCTAssertEqual(summary.percent, 20)
        XCTAssertTrue(summary.isLowerBound)
    }

    func testExactBoundarySampleKeepsPartialCycleResultExact() throws {
        let day = 24 * 60 * 60.0
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let reset = start.addingTimeInterval(7 * day)
        let intervalStart = start.addingTimeInterval(2 * day)
        let intervalEnd = start.addingTimeInterval(4 * day)
        let samples = [
            sample(id: 1, date: intervalStart, remaining: 60, reset: reset),
            sample(id: 2, date: intervalEnd.addingTimeInterval(-5 * 60), remaining: 40, reset: reset)
        ]

        let summary = try XCTUnwrap(ObservedQuotaConsumption.calculate(
            samples: samples,
            window: weeklyWindow(resetsAt: reset),
            interval: DateInterval(start: intervalStart, end: intervalEnd),
            usesLiveWindowReset: false
        ))

        XCTAssertEqual(summary.percent, 20)
        XCTAssertFalse(summary.isLowerBound)
    }

    func testUnobservedEndingReportsLowerBound() throws {
        let day = 24 * 60 * 60.0
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let reset = start.addingTimeInterval(7 * day)
        let samples = [
            sample(id: 1, date: start.addingTimeInterval(60), remaining: 100, reset: reset),
            sample(id: 2, date: reset.addingTimeInterval(-2 * 60 * 60), remaining: 50, reset: reset)
        ]

        let summary = try XCTUnwrap(ObservedQuotaConsumption.calculate(
            samples: samples,
            window: weeklyWindow(resetsAt: reset),
            interval: DateInterval(start: start, end: reset),
            usesLiveWindowReset: false
        ))

        XCTAssertEqual(summary.percent, 50)
        XCTAssertTrue(summary.isLowerBound)
    }

    func testCurrentUnfinishedCycleUsesKnownResetBaseline() throws {
        let day = 24 * 60 * 60.0
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let reset = start.addingTimeInterval(7 * day)
        let now = start.addingTimeInterval(3 * day)
        let samples = [
            sample(id: 1, date: now, remaining: 40, reset: reset)
        ]

        let summary = try XCTUnwrap(ObservedQuotaConsumption.calculate(
            samples: samples,
            window: weeklyWindow(resetsAt: reset),
            interval: DateInterval(start: start, end: now),
            usesLiveWindowReset: true
        ))

        XCTAssertEqual(summary.percent, 60)
        XCTAssertFalse(summary.isLowerBound)
    }

    func testCalculationNeverCombinesDifferentQuotaWindows() throws {
        let day = 24 * 60 * 60.0
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let reset = start.addingTimeInterval(7 * day)
        let samples = [
            sample(id: 1, date: start, remaining: 100, reset: reset),
            sample(id: 2, date: reset.addingTimeInterval(-60), remaining: 70, reset: reset),
            sample(
                id: 3,
                windowID: "five-hour",
                date: reset.addingTimeInterval(-60),
                remaining: 0,
                reset: reset
            )
        ]

        let summary = try XCTUnwrap(ObservedQuotaConsumption.calculate(
            samples: samples,
            window: weeklyWindow(resetsAt: reset),
            interval: DateInterval(start: start, end: reset),
            usesLiveWindowReset: false
        ))

        XCTAssertEqual(summary.percent, 30)
    }

    func testCurrentCycleUsesReturnedWindowDuration() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let reset = start.addingTimeInterval(5 * 60 * 60)
        let window = QuotaHistoryWindow(
            id: "five-hour",
            name: "5 hours",
            windowDurationMins: 300,
            resetsAt: reset
        )
        let series = try XCTUnwrap(QuotaHistorySeries.makeCurrentCycle(
            samples: [sample(
                id: 1,
                windowID: "five-hour",
                date: start.addingTimeInterval(60),
                remaining: 90,
                reset: reset
            )],
            window: window,
            now: start.addingTimeInterval(60)
        ))

        XCTAssertEqual(series.start, start)
        XCTAssertEqual(series.end, reset)
    }

    private func weeklyWindow(resetsAt: Date) -> QuotaHistoryWindow {
        QuotaHistoryWindow(
            id: "weekly",
            name: "Weekly",
            windowDurationMins: 10_080,
            resetsAt: resetsAt
        )
    }

    private func sample(
        id: Int64,
        windowID: String = "weekly",
        date: Date,
        remaining: Int,
        reset: Date
    ) -> QuotaHistorySample {
        QuotaHistorySample(
            id: id,
            windowID: windowID,
            windowName: windowID == "weekly" ? "Weekly" : "5 hours",
            sampledAt: date,
            remainingPercent: remaining,
            windowDurationMins: windowID == "weekly" ? 10_080 : 300,
            resetsAt: reset,
            startsSegment: id == 1,
            isAnchor: false,
            isStale: false,
            source: .refresh
        )
    }
}
