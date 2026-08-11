import Foundation
import XCTest
@testable import CodexMeterCore

final class UpdateCheckScheduleTests: XCTestCase {
    func testWaitsTwentyFourHoursAfterSuccess() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        XCTAssertEqual(
            UpdateCheckSchedule.nextDelay(
                lastCheckedAt: now,
                now: now,
                lastAttemptFailed: false
            ),
            24 * 60 * 60,
            accuracy: 0.001
        )
        XCTAssertEqual(
            UpdateCheckSchedule.nextDelay(
                lastCheckedAt: now.addingTimeInterval(-6 * 60 * 60),
                now: now,
                lastAttemptFailed: false
            ),
            18 * 60 * 60,
            accuracy: 0.001
        )
    }

    func testRetriesFailuresWithoutBusyLooping() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        XCTAssertEqual(
            UpdateCheckSchedule.nextDelay(
                lastCheckedAt: now.addingTimeInterval(-48 * 60 * 60),
                now: now,
                lastAttemptFailed: true
            ),
            60 * 60,
            accuracy: 0.001
        )
        XCTAssertEqual(
            UpdateCheckSchedule.nextDelay(
                lastCheckedAt: now.addingTimeInterval(-48 * 60 * 60),
                now: now,
                lastAttemptFailed: false
            ),
            60,
            accuracy: 0.001
        )
    }
}
