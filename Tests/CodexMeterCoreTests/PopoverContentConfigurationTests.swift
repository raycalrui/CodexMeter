import XCTest
@testable import CodexMeterCore

final class PopoverContentConfigurationTests: XCTestCase {
    func testDefaultsShowEveryPopoverSection() {
        let configuration = PopoverContentConfiguration.defaultValue

        XCTAssertTrue(configuration.isSectionVisible(.quotaWindows))
        XCTAssertTrue(configuration.isSectionVisible(.resetCredits))
        XCTAssertTrue(configuration.isSectionVisible(.quotaHistory))
        XCTAssertTrue(configuration.isSectionVisible(.tokenActivity))
        XCTAssertNil(configuration.menuBarQuotaWindowID)
    }

    func testQuotaWindowsCanBeHiddenIndependentlyByStableIdentity() {
        var configuration = PopoverContentConfiguration.defaultValue
        let fiveHour = makeWindow(id: "codex-primary", name: "5h", duration: 300, used: 20)
        let weekly = makeWindow(id: "codex-secondary", name: "Weekly", duration: 10_080, used: 30)

        configuration.setQuotaWindow(fiveHour, visible: false)

        XCTAssertFalse(configuration.isQuotaWindowVisible(fiveHour))
        XCTAssertTrue(configuration.isQuotaWindowVisible(weekly))
        XCTAssertEqual(configuration.visibleQuotaWindows(from: [fiveHour, weekly]), [weekly])
    }

    func testSelectedMenuBarWindowUsesPersistedStableIdentity() {
        var configuration = PopoverContentConfiguration.defaultValue
        let fiveHour = makeWindow(id: "codex-primary", name: "5h", duration: 300, used: 80)
        let weekly = makeWindow(id: "codex-secondary", name: "Weekly", duration: 10_080, used: 20)

        configuration.menuBarQuotaWindowID = weekly.historyID

        XCTAssertEqual(configuration.selectedMenuBarWindow(from: [fiveHour, weekly]), weekly)
    }

    func testMissingMenuBarSelectionFallsBackToLowestRemainingQuota() {
        var configuration = PopoverContentConfiguration.defaultValue
        configuration.menuBarQuotaWindowID = "duration:999:missing"
        let fiveHour = makeWindow(id: "codex-primary", name: "5h", duration: 300, used: 80)
        let weekly = makeWindow(id: "codex-secondary", name: "Weekly", duration: 10_080, used: 20)

        XCTAssertEqual(configuration.selectedMenuBarWindow(from: [weekly, fiveHour]), fiveHour)
    }

    func testMovingSectionChangesOnlyItsStoredOrder() {
        var configuration = PopoverContentConfiguration.defaultValue

        configuration.moveSection(.tokenActivity, by: -1)

        XCTAssertEqual(
            configuration.sectionOrder,
            [.quotaWindows, .resetCredits, .tokenActivity, .quotaHistory]
        )
        XCTAssertTrue(configuration.isSectionVisible(.resetCredits))
        XCTAssertTrue(configuration.isSectionVisible(.tokenActivity))
    }

    func testDecodingOlderEmptyPreferencesUsesCurrentDefaults() throws {
        let configuration = try JSONDecoder().decode(
            PopoverContentConfiguration.self,
            from: Data("{}".utf8)
        )

        XCTAssertEqual(configuration, .defaultValue)
    }

    private func makeWindow(
        id: String,
        name: String,
        duration: Int,
        used: Int
    ) -> CodexUsageWindow {
        CodexUsageWindow(
            id: id,
            name: name,
            usedPercent: used,
            windowDurationMins: duration,
            resetsAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
    }
}
