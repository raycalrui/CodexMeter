import Foundation
import XCTest
@testable import CodexMeterCore

final class QuotaCalendarPeriodTests: XCTestCase {
    func testQuotaHistoryModesKeepQuickRangesSeparateFromBrowse() {
        XCTAssertEqual(QuotaHistoryMode.currentCycle.historyRange, .currentCycle)
        XCTAssertEqual(QuotaHistoryMode.sevenDays.historyRange, .sevenDays)
        XCTAssertEqual(QuotaHistoryMode.fourteenDays.historyRange, .fourteenDays)
        XCTAssertEqual(QuotaHistoryMode.month.historyRange, .month)
        XCTAssertNil(QuotaHistoryMode.browse.historyRange)
    }

    func testWeekIntervalsFollowTheProvidedCalendar() throws {
        let calendar = testCalendar
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 13,
            hour: 12
        )))
        let current = try XCTUnwrap(QuotaCalendarPeriod.week.interval(
            offset: 0,
            containing: date,
            calendar: calendar
        ))
        let previous = try XCTUnwrap(QuotaCalendarPeriod.week.interval(
            offset: -1,
            containing: date,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.component(.day, from: current.start), 10)
        XCTAssertEqual(calendar.component(.day, from: current.end), 17)
        XCTAssertEqual(previous.end, current.start)
        XCTAssertEqual(previous.duration, 7 * 24 * 60 * 60, accuracy: 1)
    }

    func testMonthIntervalsUseWholeCalendarMonths() throws {
        let calendar = testCalendar
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 13,
            hour: 12
        )))
        let current = try XCTUnwrap(QuotaCalendarPeriod.month.interval(
            offset: 0,
            containing: date,
            calendar: calendar
        ))
        let previous = try XCTUnwrap(QuotaCalendarPeriod.month.interval(
            offset: -1,
            containing: date,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.component(.month, from: current.start), 8)
        XCTAssertEqual(calendar.component(.month, from: current.end), 9)
        XCTAssertEqual(calendar.component(.month, from: previous.start), 7)
        XCTAssertEqual(previous.end, current.start)
    }

    private var testCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
}
