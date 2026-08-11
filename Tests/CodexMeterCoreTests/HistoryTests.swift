import SQLite3
import XCTest
@testable import CodexMeterCore

final class HistoryTests: XCTestCase {
    func testUnchangedQuotaUsesFifteenMinuteAnchors() async throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.store.prepareDatabase()

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let window = usageWindow(usedPercent: 25, resetsAt: start.addingTimeInterval(3_600))
        try await fixture.store.recordQuotaSnapshots(
            [window], at: start, isStale: false, source: .refresh
        )
        try await fixture.store.recordQuotaSnapshots(
            [window], at: start.addingTimeInterval(60), isStale: false, source: .refresh
        )
        try await fixture.store.recordQuotaSnapshots(
            [window], at: start.addingTimeInterval(15 * 60), isStale: false, source: .refresh
        )

        let samples = try await fixture.store.quotaSamples(windowID: window.id, since: .distantPast)
        XCTAssertEqual(samples.count, 2)
        XCTAssertFalse(samples[0].isAnchor)
        XCTAssertTrue(samples[1].isAnchor)
    }

    func testChangedQuotaRecordsImmediatelyAndStartsNewSegmentAfterReset() async throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.store.prepareDatabase()

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = start.addingTimeInterval(3_600)
        let initial = usageWindow(usedPercent: 25, resetsAt: reset)
        let changed = usageWindow(usedPercent: 27, resetsAt: reset)
        let resetWindow = usageWindow(
            usedPercent: 1,
            resetsAt: reset.addingTimeInterval(3_600)
        )

        try await fixture.store.recordQuotaSnapshots(
            [initial], at: start, isStale: false, source: .refresh
        )
        try await fixture.store.recordQuotaSnapshots(
            [changed], at: start.addingTimeInterval(60), isStale: false, source: .notification
        )
        try await fixture.store.recordQuotaSnapshots(
            [resetWindow], at: start.addingTimeInterval(120), isStale: false, source: .refresh
        )

        let samples = try await fixture.store.quotaSamples(windowID: initial.id, since: .distantPast)
        XCTAssertEqual(samples.map(\.remainingPercent), [75, 73, 99])
        XCTAssertEqual(samples.map(\.startsSegment), [true, false, true])
        XCTAssertEqual(samples[1].source, .notification)
    }

    func testRetentionPrunesOldQuotaAndTokenRows() async throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.store.prepareDatabase()

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-10 * 24 * 60 * 60)
        try await fixture.store.recordQuotaSnapshots(
            [usageWindow(usedPercent: 10, resetsAt: old.addingTimeInterval(3_600))],
            at: old,
            isStale: false,
            source: .refresh
        )
        try await fixture.store.recordQuotaSnapshots(
            [usageWindow(usedPercent: 20, resetsAt: now.addingTimeInterval(3_600))],
            at: now,
            isStale: false,
            source: .refresh
        )
        try await fixture.store.recordTokenUsage(TokenUsageSnapshot(
            dailyBuckets: [
                TokenUsageDailyBucket(startDate: "2027-01-01", tokens: 100),
                TokenUsageDailyBucket(startDate: "2027-01-11", tokens: 200)
            ],
            summary: emptySummary,
            fetchedAt: now
        ))

        try await fixture.store.applyRetention(.sevenDays, now: now)
        let samples = try await fixture.store.quotaSamples(windowID: "codex-primary", since: .distantPast)
        let tokenUsage = try await fixture.store.tokenUsage()
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(tokenUsage?.dailyBuckets?.map(\.startDate), ["2027-01-11"])
    }

    func testVersionOneDatabaseMigratesForward() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMeterMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        try createVersionOneDatabase(at: url)

        let store = try UsageHistoryStore(databaseURL: url)
        try await store.prepareDatabase()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.recordQuotaSnapshots(
            [usageWindow(usedPercent: 30, resetsAt: now.addingTimeInterval(3_600))],
            at: now,
            isStale: false,
            source: .notification
        )

        let samples = try await store.quotaSamples(windowID: "codex-primary", since: .distantPast)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.source, .notification)
        XCTAssertTrue(samples.first?.startsSegment == true)
    }

    func testCSVExportExcludesAuthenticationAndRawResponses() async throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.store.prepareDatabase()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await fixture.store.recordQuotaSnapshots(
            [usageWindow(usedPercent: 30, resetsAt: now.addingTimeInterval(3_600))],
            at: now,
            isStale: false,
            source: .refresh
        )
        try await fixture.store.recordTokenUsage(TokenUsageSnapshot(
            dailyBuckets: [TokenUsageDailyBucket(startDate: "2027-01-15", tokens: 1_000)],
            summary: emptySummary,
            fetchedAt: now
        ))

        let csv = try await fixture.store.exportCSV()
        let text = try XCTUnwrap(String(data: csv, encoding: .utf8))
        let lines = text.split(separator: "\n").map(String.init)
        let quotaColumns = try XCTUnwrap(lines.first(where: { $0.hasPrefix("quota,") }))
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        let tokenColumns = try XCTUnwrap(lines.first(where: { $0.hasPrefix("token_daily,") }))
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        XCTAssertTrue(lines[0].hasPrefix("record_type,timestamp,recorded_at,"))
        XCTAssertEqual(quotaColumns.count, 13)
        XCTAssertEqual(tokenColumns.count, 13)
        XCTAssertEqual(try XCTUnwrap(formatter.date(from: quotaColumns[2])), now)
        XCTAssertEqual(try XCTUnwrap(formatter.date(from: tokenColumns[2])), now)
        XCTAssertTrue(text.contains("quota"))
        XCTAssertTrue(text.contains("codex-primary"))
        XCTAssertFalse(text.lowercased().contains("email"))
        XCTAssertFalse(text.lowercased().contains("access_token"))
        XCTAssertFalse(text.lowercased().contains("raw_response"))
    }

    func testDeveloperPreviewProvidesContinuousThirtyDayHistory() async throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.store.prepareDatabase()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try await fixture.store.replaceDeveloperPreviewData(
            windowName: "Preview weekly quota",
            now: now
        )
        let samples = try await fixture.store.quotaSamples(
            windowID: "developer-preview-weekly",
            since: now.addingTimeInterval(-31 * 24 * 60 * 60)
        )

        XCTAssertEqual(samples.count, 2_881)
        XCTAssertTrue(samples.gaps().isEmpty)
        XCTAssertEqual(samples.filter(\.startsSegment).count, 5)
    }

    func testExhaustionEstimateRequiresContinuousMonotonicSamples() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(6 * 60 * 60)
        let samples = [
            historySample(id: 1, date: now.addingTimeInterval(-30 * 60), remaining: 60, reset: reset),
            historySample(id: 2, date: now.addingTimeInterval(-15 * 60), remaining: 55, reset: reset),
            historySample(id: 3, date: now, remaining: 50, reset: reset)
        ]

        let estimate = QuotaExhaustionEstimate.calculate(samples: samples, now: now)
        XCTAssertNotNil(estimate)
        XCTAssertEqual(
            estimate?.exhaustedAt.timeIntervalSince(now) ?? 0,
            150 * 60,
            accuracy: 1
        )

        let nonMonotonic = [samples[0], historySample(
            id: 2,
            date: now.addingTimeInterval(-15 * 60),
            remaining: 65,
            reset: reset
        ), samples[2]]
        XCTAssertNil(QuotaExhaustionEstimate.calculate(samples: nonMonotonic, now: now))
    }

    func testSemanticVersionComparisonHandlesPrereleases() throws {
        let v119 = try XCTUnwrap(SemanticVersion("1.1.9"))
        let v120Beta = try XCTUnwrap(SemanticVersion("v1.2.0-beta.2"))
        let v120 = try XCTUnwrap(SemanticVersion("1.2.0"))
        XCTAssertLessThan(v119, v120Beta)
        XCTAssertLessThan(v120Beta, v120)
        XCTAssertEqual(SemanticVersion("1.2"), v120)
    }

    func testWeeklyCycleAlwaysStartsAtOneHundredAndKeepsGapsConnected() throws {
        let cycleEnd = Date(timeIntervalSince1970: 1_900_000_000)
        let cycleStart = cycleEnd.addingTimeInterval(-WeeklyQuotaCycle.duration)
        let window = QuotaHistoryWindow(
            id: "weekly",
            name: "Weekly",
            windowDurationMins: 10_080,
            resetsAt: cycleEnd
        )
        let samples = [
            weeklyHistorySample(
                id: 1,
                date: cycleStart.addingTimeInterval(24 * 60 * 60),
                remaining: 86,
                reset: cycleEnd
            ),
            weeklyHistorySample(
                id: 2,
                date: cycleStart.addingTimeInterval(4 * 24 * 60 * 60),
                remaining: 58,
                reset: cycleEnd
            ),
            weeklyHistorySample(
                id: 3,
                date: cycleStart.addingTimeInterval(-60),
                remaining: 4,
                reset: cycleStart
            )
        ]

        let cycle = try XCTUnwrap(WeeklyQuotaCycle.make(
            samples: samples,
            window: window,
            now: cycleStart.addingTimeInterval(4 * 24 * 60 * 60),
            gapThreshold: 60 * 60
        ))

        XCTAssertEqual(cycle.start, cycleStart)
        XCTAssertEqual(cycle.end, cycleEnd)
        XCTAssertEqual(cycle.points.first?.remainingPercent, 100)
        XCTAssertTrue(cycle.points.first?.isSyntheticStart == true)
        XCTAssertEqual(cycle.samples.map(\.id), [1, 2])
        XCTAssertEqual(cycle.gaps.count, 2)
        XCTAssertEqual(cycle.points.count, 3, "Missing periods shade the background without breaking the curve")
    }

    func testCompactTokenFormatterUsesKMBWithoutScientificNotation() {
        let locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(CompactTokenFormatter.string(999, locale: locale), "999")
        XCTAssertEqual(CompactTokenFormatter.string(1_000, locale: locale), "1k")
        XCTAssertEqual(CompactTokenFormatter.string(1_250, locale: locale), "1.3k")
        XCTAssertEqual(CompactTokenFormatter.string(2_000_000, locale: locale), "2M")
        XCTAssertEqual(CompactTokenFormatter.string(5_900_000_000, locale: locale), "5.9B")
        XCTAssertFalse(CompactTokenFormatter.string(Int64.max, locale: locale).contains("e"))
    }

    func testTokenActivityRangesIncludeExpectedDates() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        XCTAssertTrue(TokenActivityRange.week.includes(
            now.addingTimeInterval(-6 * 24 * 60 * 60),
            now: now
        ))
        XCTAssertFalse(TokenActivityRange.week.includes(
            now.addingTimeInterval(-8 * 24 * 60 * 60),
            now: now
        ))
        XCTAssertTrue(TokenActivityRange.all.includes(.distantPast, now: now))
    }

    func testTokenChartGranularityMatchesEveryRange() {
        XCTAssertEqual(TokenActivityRange.week.chartGranularity, .day)
        XCTAssertEqual(TokenActivityRange.month.chartGranularity, .day)
        XCTAssertEqual(TokenActivityRange.threeMonths.chartGranularity, .day)
        XCTAssertEqual(TokenActivityRange.year.chartGranularity, .week)
        XCTAssertEqual(TokenActivityRange.all.chartGranularity, .month)
    }

    func testTokenChartCentersRulesWithinDayWeekAndMonthBars() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_893_499_200) // 2030-01-01 00:00 UTC

        let dayStart = TokenChartGranularity.day.bucketStart(for: date)
        XCTAssertEqual(
            TokenChartGranularity.day.centerDate(for: date).timeIntervalSince(dayStart),
            12 * 60 * 60,
            accuracy: 1
        )

        let weekStart = TokenChartGranularity.week.bucketStart(for: date)
        XCTAssertEqual(
            TokenChartGranularity.week.centerDate(for: date).timeIntervalSince(weekStart),
            3.5 * 24 * 60 * 60,
            accuracy: 1
        )

        let monthStart = TokenChartGranularity.month.bucketStart(for: date)
        let monthInterval = try? XCTUnwrap(calendar.dateInterval(of: .month, for: date))
        XCTAssertEqual(
            TokenChartGranularity.month.centerDate(for: date).timeIntervalSince(monthStart),
            (monthInterval?.duration ?? 0) / 2,
            accuracy: 1
        )
    }

    func testTokenTooltipStopsAtBothChartEdgesWithoutChangingPlotWidth() {
        XCTAssertEqual(TokenTooltipLayout.clampedCenter(
            desiredX: 2,
            lowerBound: 0,
            upperBound: 600,
            width: 176
        ), 88)
        XCTAssertEqual(TokenTooltipLayout.clampedCenter(
            desiredX: 598,
            lowerBound: 0,
            upperBound: 600,
            width: 176
        ), 512)
        XCTAssertEqual(TokenTooltipLayout.clampedCenter(
            desiredX: 300,
            lowerBound: 0,
            upperBound: 600,
            width: 176
        ), 300)
    }

    func testTokenSnapshotsAccumulateOlderDailyBuckets() async throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.store.prepareDatabase()
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        try await fixture.store.recordTokenUsage(TokenUsageSnapshot(
            dailyBuckets: [TokenUsageDailyBucket(startDate: "2030-01-01", tokens: 1_000)],
            summary: emptySummary,
            fetchedAt: now
        ))
        try await fixture.store.recordTokenUsage(TokenUsageSnapshot(
            dailyBuckets: [TokenUsageDailyBucket(startDate: "2030-02-01", tokens: 2_000)],
            summary: emptySummary,
            fetchedAt: now.addingTimeInterval(60)
        ))

        let snapshot = try await fixture.store.tokenUsage()
        XCTAssertEqual(snapshot?.dailyBuckets?.map(\.startDate), ["2030-01-01", "2030-02-01"])
    }

    func testAccountChangeClearsOnlyTokenHistory() async throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.store.prepareDatabase()
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        try await fixture.store.recordQuotaSnapshots(
            [usageWindow(usedPercent: 20, resetsAt: now.addingTimeInterval(3_600))],
            at: now,
            isStale: false,
            source: .refresh
        )
        try await fixture.store.recordTokenUsage(TokenUsageSnapshot(
            dailyBuckets: [TokenUsageDailyBucket(startDate: "2030-01-01", tokens: 1_000)],
            summary: emptySummary,
            fetchedAt: now
        ))

        try await fixture.store.clearTokenUsage()

        let tokenUsage = try await fixture.store.tokenUsage()
        XCTAssertNil(tokenUsage)
        let quota = try await fixture.store.quotaSamples(
            windowID: "codex-primary",
            since: .distantPast
        )
        XCTAssertEqual(quota.count, 1)
    }

    private var emptySummary: TokenUsageSummary {
        TokenUsageSummary(
            lifetimeTokens: nil,
            peakDailyTokens: nil,
            currentStreakDays: nil,
            longestStreakDays: nil,
            longestRunningTurnSeconds: nil
        )
    }

    private func makeStoreFixture() throws -> (directory: URL, store: UsageHistoryStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMeterHistory-\(UUID().uuidString)")
        let store = try UsageHistoryStore(
            databaseURL: directory.appendingPathComponent("History.sqlite")
        )
        return (directory, store)
    }

    private func usageWindow(usedPercent: Int, resetsAt: Date) -> CodexUsageWindow {
        CodexUsageWindow(
            id: "codex-primary",
            name: "5 hours",
            usedPercent: usedPercent,
            windowDurationMins: 300,
            resetsAt: resetsAt
        )
    }

    private func historySample(
        id: Int64,
        date: Date,
        remaining: Int,
        reset: Date
    ) -> QuotaHistorySample {
        QuotaHistorySample(
            id: id,
            windowID: "codex-primary",
            windowName: "5 hours",
            sampledAt: date,
            remainingPercent: remaining,
            windowDurationMins: 300,
            resetsAt: reset,
            startsSegment: id == 1,
            isAnchor: false,
            isStale: false,
            source: .refresh
        )
    }

    private func weeklyHistorySample(
        id: Int64,
        date: Date,
        remaining: Int,
        reset: Date
    ) -> QuotaHistorySample {
        QuotaHistorySample(
            id: id,
            windowID: "weekly",
            windowName: "Weekly",
            sampledAt: date,
            remainingPercent: remaining,
            windowDurationMins: 10_080,
            resetsAt: reset,
            startsSegment: id == 1,
            isAnchor: false,
            isStale: false,
            source: .refresh
        )
    }

    private func createVersionOneDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            XCTFail("Unable to create legacy database")
            return
        }
        defer { sqlite3_close(database) }
        let sql = """
            CREATE TABLE quota_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                window_id TEXT NOT NULL,
                window_name TEXT NOT NULL,
                sampled_at REAL NOT NULL,
                remaining_percent INTEGER NOT NULL,
                window_duration_mins INTEGER,
                resets_at REAL,
                is_anchor INTEGER NOT NULL DEFAULT 0,
                is_stale INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE token_daily (
                start_date TEXT PRIMARY KEY,
                tokens INTEGER NOT NULL,
                fetched_at REAL NOT NULL
            );
            CREATE TABLE token_summary (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                lifetime_tokens INTEGER,
                peak_daily_tokens INTEGER,
                current_streak_days INTEGER,
                longest_streak_days INTEGER,
                longest_running_turn_sec INTEGER,
                fetched_at REAL NOT NULL
            );
            PRAGMA user_version = 1;
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "HistoryTests", code: 1)
        }
    }
}
