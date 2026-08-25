import Foundation
import SQLite3

enum UsageHistoryStoreError: LocalizedError {
    case openDatabase(String)
    case sqlite(String)
    case invalidText

    var errorDescription: String? {
        switch self {
        case .openDatabase(let message), .sqlite(let message): message
        case .invalidText: "The history database contains invalid text."
        }
    }
}

/// Serializes all SQLite access and keeps history independent from UI lifetime.
actor UsageHistoryStore {
    static let schemaVersion = 4

    private static let developerPreviewWindowID = QuotaHistoryWindowIdentity.make(
        sourceID: "developer-preview-weekly",
        durationMins: 10_080
    )

    let databaseURL: URL
    private var database: OpaquePointer?
    private var isPrepared = false
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL = UsageHistoryStore.defaultDatabaseURL()) throws {
        self.databaseURL = databaseURL

        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &opened,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Unable to open the history database."
            sqlite3_close(opened)
            throw UsageHistoryStoreError.openDatabase(message)
        }

        database = opened
        sqlite3_busy_timeout(opened, 2_000)
    }

    deinit {
        sqlite3_close(database)
    }

    static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("CodexMeter", isDirectory: true)
            .appendingPathComponent("UsageHistory.sqlite")
    }

    /// Completes schema setup after actor initialization so Swift 6 isolation stays valid.
    func prepareDatabase() throws {
        guard !isPrepared else { return }
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try migrateIfNeeded()
        isPrepared = true
    }

    func recordQuotaSnapshots(
        _ windows: [CodexUsageWindow],
        at date: Date,
        isStale: Bool,
        source: QuotaSampleSource,
        accountKey: String = HistoryAccountIdentity.legacyKey
    ) throws {
        try prepareDatabase()
        guard !isStale else { return }
        try transaction {
            for window in windows {
                let previous = try latestQuotaSample(
                    windowID: window.historyID,
                    accountKey: accountKey
                )
                let remainingPercent = min(100, max(0, 100 - window.usedPercent))
                let resetChanged = previous.map {
                    QuotaCycleDetection.resetMeaningfullyChanged(
                        previousRemaining: $0.remainingPercent,
                        previousReset: $0.resetsAt,
                        currentRemaining: remainingPercent,
                        currentReset: window.resetsAt
                    )
                } ?? false
                let startsNewCycle = previous.map {
                    QuotaCycleDetection.startsNewCycle(
                        previousRemaining: $0.remainingPercent,
                        previousReset: $0.resetsAt,
                        currentRemaining: remainingPercent,
                        currentReset: window.resetsAt
                    )
                } ?? false
                let changed = previous.map {
                    $0.remainingPercent != remainingPercent
                        || $0.windowDurationMins != window.windowDurationMins
                        || resetChanged
                        || $0.windowName != window.name
                } ?? true
                let anchorDue = previous.map {
                    date.timeIntervalSince($0.sampledAt) >= 15 * 60
                } ?? true
                let isFirstSample = previous.map { _ in false } ?? true

                guard changed || anchorDue else { continue }
                try insertQuotaSample(
                    window: window,
                    date: date,
                    remainingPercent: remainingPercent,
                    startsSegment: isFirstSample || startsNewCycle,
                    isAnchor: !changed,
                    isStale: false,
                    source: source,
                    accountKey: accountKey
                )
            }
        }
    }

    func recordTokenUsage(
        _ snapshot: TokenUsageSnapshot,
        accountKey: String = HistoryAccountIdentity.legacyKey
    ) throws {
        try prepareDatabase()
        try transaction {
            if let buckets = snapshot.dailyBuckets {
                // Upsert the returned window instead of replacing the table. The
                // endpoint may expose only recent days, while CodexMeter builds a
                // longer local history for 90-day, one-year, and all-time charts.
                for bucket in buckets {
                    let statement = try prepare("""
                        INSERT INTO token_daily (account_key, start_date, tokens, fetched_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(account_key, start_date) DO UPDATE SET
                            tokens = excluded.tokens,
                            fetched_at = excluded.fetched_at;
                        """)
                    defer { sqlite3_finalize(statement) }
                    try bind(accountKey, at: 1, in: statement)
                    try bind(bucket.startDate, at: 2, in: statement)
                    sqlite3_bind_int64(statement, 3, bucket.tokens)
                    sqlite3_bind_double(statement, 4, snapshot.fetchedAt.timeIntervalSince1970)
                    try stepDone(statement)
                }
            }

            let summary = snapshot.summary
            let statement = try prepare("""
                INSERT INTO token_summary (
                    account_key, lifetime_tokens, peak_daily_tokens, current_streak_days,
                    longest_streak_days, longest_running_turn_sec, fetched_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_key) DO UPDATE SET
                    lifetime_tokens = excluded.lifetime_tokens,
                    peak_daily_tokens = excluded.peak_daily_tokens,
                    current_streak_days = excluded.current_streak_days,
                    longest_streak_days = excluded.longest_streak_days,
                    longest_running_turn_sec = excluded.longest_running_turn_sec,
                    fetched_at = excluded.fetched_at;
            """)
            defer { sqlite3_finalize(statement) }
            try bind(accountKey, at: 1, in: statement)
            bind(summary.lifetimeTokens, at: 2, in: statement)
            bind(summary.peakDailyTokens, at: 3, in: statement)
            bind(summary.currentStreakDays, at: 4, in: statement)
            bind(summary.longestStreakDays, at: 5, in: statement)
            bind(summary.longestRunningTurnSeconds, at: 6, in: statement)
            sqlite3_bind_double(statement, 7, snapshot.fetchedAt.timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    func quotaWindows(
        accountKey: String = HistoryAccountIdentity.legacyKey
    ) throws -> [QuotaHistoryWindow] {
        try prepareDatabase()
        let statement = try prepare("""
            SELECT q.window_id, q.window_name, q.window_duration_mins, q.resets_at
            FROM quota_samples q
            INNER JOIN (
                SELECT window_id, MAX(sampled_at) AS latest
                FROM quota_samples WHERE account_key = ? GROUP BY window_id
            ) latest ON latest.window_id = q.window_id AND latest.latest = q.sampled_at
            WHERE q.account_key = ?
            ORDER BY q.window_name COLLATE NOCASE;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(accountKey, at: 1, in: statement)
        try bind(accountKey, at: 2, in: statement)

        var result: [QuotaHistoryWindow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(QuotaHistoryWindow(
                id: try text(statement, column: 0),
                name: try text(statement, column: 1),
                windowDurationMins: optionalInt(statement, column: 2),
                resetsAt: optionalDouble(statement, column: 3).map(Date.init(timeIntervalSince1970:))
            ))
        }
        return result
    }

    func quotaSamples(
        windowID: String,
        since date: Date,
        accountKey: String = HistoryAccountIdentity.legacyKey
    ) throws -> [QuotaHistorySample] {
        try prepareDatabase()
        let statement = try prepare("""
            SELECT id, window_id, window_name, sampled_at, remaining_percent,
                   window_duration_mins, resets_at, starts_segment, is_anchor,
                   is_stale, source
            FROM quota_samples
            WHERE account_key = ? AND window_id = ? AND sampled_at >= ?
            ORDER BY sampled_at ASC;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(accountKey, at: 1, in: statement)
        try bind(windowID, at: 2, in: statement)
        sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)

        var result: [QuotaHistorySample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decodeQuotaSample(statement))
        }
        return result
    }

    func quotaSamples(
        windowID: String,
        from startDate: Date,
        before endDate: Date,
        accountKey: String = HistoryAccountIdentity.legacyKey
    ) throws -> [QuotaHistorySample] {
        try prepareDatabase()
        let statement = try prepare("""
            SELECT id, window_id, window_name, sampled_at, remaining_percent,
                   window_duration_mins, resets_at, starts_segment, is_anchor,
                   is_stale, source
            FROM quota_samples
            WHERE account_key = ? AND window_id = ?
                  AND sampled_at >= ? AND sampled_at < ?
            ORDER BY sampled_at ASC;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(accountKey, at: 1, in: statement)
        try bind(windowID, at: 2, in: statement)
        sqlite3_bind_double(statement, 3, startDate.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, endDate.timeIntervalSince1970)

        var result: [QuotaHistorySample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decodeQuotaSample(statement))
        }
        return result
    }

    func oldestQuotaSampleDate(
        windowID: String,
        accountKey: String = HistoryAccountIdentity.legacyKey
    ) throws -> Date? {
        try prepareDatabase()
        let statement = try prepare("""
            SELECT MIN(sampled_at) FROM quota_samples
            WHERE account_key = ? AND window_id = ?;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(accountKey, at: 1, in: statement)
        try bind(windowID, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else {
            return nil
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    func quotaSamples(
        since date: Date,
        accountKey: String = HistoryAccountIdentity.legacyKey
    ) throws -> [QuotaHistorySample] {
        try prepareDatabase()
        let statement = try prepare("""
            SELECT id, window_id, window_name, sampled_at, remaining_percent,
                   window_duration_mins, resets_at, starts_segment, is_anchor,
                   is_stale, source
            FROM quota_samples
            WHERE account_key = ? AND sampled_at >= ?
            ORDER BY sampled_at ASC;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(accountKey, at: 1, in: statement)
        sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)

        var result: [QuotaHistorySample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decodeQuotaSample(statement))
        }
        return result
    }

    func tokenUsage(
        accountKey: String = HistoryAccountIdentity.legacyKey
    ) throws -> TokenUsageSnapshot? {
        try prepareDatabase()
        let bucketStatement = try prepare("""
            SELECT start_date, tokens FROM token_daily
            WHERE account_key = ? ORDER BY start_date ASC;
            """)
        defer { sqlite3_finalize(bucketStatement) }
        try bind(accountKey, at: 1, in: bucketStatement)
        var buckets: [TokenUsageDailyBucket] = []
        while sqlite3_step(bucketStatement) == SQLITE_ROW {
            buckets.append(TokenUsageDailyBucket(
                startDate: try text(bucketStatement, column: 0),
                tokens: sqlite3_column_int64(bucketStatement, 1)
            ))
        }

        let summaryStatement = try prepare("""
            SELECT lifetime_tokens, peak_daily_tokens, current_streak_days,
                   longest_streak_days, longest_running_turn_sec, fetched_at
            FROM token_summary WHERE account_key = ?;
            """)
        defer { sqlite3_finalize(summaryStatement) }
        try bind(accountKey, at: 1, in: summaryStatement)
        guard sqlite3_step(summaryStatement) == SQLITE_ROW else {
            return buckets.isEmpty ? nil : TokenUsageSnapshot(
                dailyBuckets: buckets,
                summary: TokenUsageSummary(
                    lifetimeTokens: nil,
                    peakDailyTokens: nil,
                    currentStreakDays: nil,
                    longestStreakDays: nil,
                    longestRunningTurnSeconds: nil
                ),
                fetchedAt: .distantPast
            )
        }

        return TokenUsageSnapshot(
            dailyBuckets: buckets,
            summary: TokenUsageSummary(
                lifetimeTokens: optionalInt64(summaryStatement, column: 0),
                peakDailyTokens: optionalInt64(summaryStatement, column: 1),
                currentStreakDays: optionalInt64(summaryStatement, column: 2),
                longestStreakDays: optionalInt64(summaryStatement, column: 3),
                longestRunningTurnSeconds: optionalInt64(summaryStatement, column: 4)
            ),
            fetchedAt: Date(timeIntervalSince1970: sqlite3_column_double(summaryStatement, 5))
        )
    }

    func applyRetention(_ retention: HistoryRetention, now: Date = Date()) throws {
        try prepareDatabase()
        let days: Int?
        switch retention {
        case .sevenDays: days = 7
        case .thirtyDays: days = 30
        case .ninetyDays: days = 90
        case .oneYear: days = 365
        case .forever: days = nil
        }
        guard let days else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let quotaStatement = try prepare("DELETE FROM quota_samples WHERE sampled_at < ?;")
        defer { sqlite3_finalize(quotaStatement) }
        sqlite3_bind_double(quotaStatement, 1, cutoff.timeIntervalSince1970)
        try stepDone(quotaStatement)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let cutoffDate = formatter.string(from: cutoff)
        let tokenStatement = try prepare("DELETE FROM token_daily WHERE start_date < ?;")
        defer { sqlite3_finalize(tokenStatement) }
        try bind(cutoffDate, at: 1, in: tokenStatement)
        try stepDone(tokenStatement)
    }

    func clearAll() throws {
        try prepareDatabase()
        try transaction {
            try execute("DELETE FROM quota_samples;")
            try execute("DELETE FROM token_daily;")
            try execute("DELETE FROM token_summary;")
        }
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    func clearAccount(_ accountKey: String) throws {
        try prepareDatabase()
        try transaction {
            for table in ["quota_samples", "token_daily", "token_summary"] {
                let statement = try prepare("DELETE FROM \(table) WHERE account_key = ?;")
                defer { sqlite3_finalize(statement) }
                try bind(accountKey, at: 1, in: statement)
                try stepDone(statement)
            }
        }
    }

    func claimLegacyHistory(for accountKey: String) throws {
        try prepareDatabase()
        guard accountKey != HistoryAccountIdentity.legacyKey else { return }

        try transaction {
            // A newly upgraded database has only `legacy` rows. Move them to the
            // first identifiable account, but never merge them into an account
            // that already owns history because that could mix two users.
            guard try accountHasHistory(accountKey) == false else { return }

            for table in ["quota_samples", "token_daily", "token_summary"] {
                let statement = try prepare("""
                    UPDATE \(table) SET account_key = ? WHERE account_key = ?;
                    """)
                defer { sqlite3_finalize(statement) }
                try bind(accountKey, at: 1, in: statement)
                try bind(HistoryAccountIdentity.legacyKey, at: 2, in: statement)
                try stepDone(statement)
            }
        }
    }

    func replaceDeveloperPreviewData(
        windowName: String,
        now: Date = Date(),
        accountKey: String = HistoryAccountIdentity.legacyKey
    ) throws {
        try prepareDatabase()
        try transaction {
            let deleteStatement = try prepare("""
                DELETE FROM quota_samples
                WHERE account_key = ? AND window_id = ?;
                """)
            defer { sqlite3_finalize(deleteStatement) }
            try bind(accountKey, at: 1, in: deleteStatement)
            try bind(Self.developerPreviewWindowID, at: 2, in: deleteStatement)
            try stepDone(deleteStatement)
            let cycleDuration = 7 * 24 * 60 * 60
            let sampleInterval = 15 * 60
            let samplesPerCycle = cycleDuration / sampleInterval
            let firstDate = now.addingTimeInterval(-30 * 24 * 60 * 60)
            let sampleCount = 30 * 24 * 4 + 1

            for index in 0..<sampleCount {
                let sampledAt = firstDate.addingTimeInterval(Double(index * sampleInterval))
                let cycleIndex = index / samplesPerCycle
                let indexInCycle = index % samplesPerCycle
                let cycleStart = firstDate.addingTimeInterval(Double(cycleIndex * cycleDuration))
                let reset = cycleStart.addingTimeInterval(Double(cycleDuration))
                let consumed = min(
                    88,
                    Int((Double(indexInCycle) / Double(samplesPerCycle) * 88).rounded())
                )
                let window = CodexUsageWindow(
                    id: "developer-preview-weekly",
                    name: windowName,
                    usedPercent: consumed,
                    windowDurationMins: 10_080,
                    resetsAt: reset
                )
                try insertQuotaSample(
                    window: window,
                    date: sampledAt,
                    remainingPercent: 100 - consumed,
                    startsSegment: indexInCycle == 0,
                    isAnchor: true,
                    isStale: false,
                    source: .refresh,
                    accountKey: accountKey
                )
            }
        }
    }

    func clearDeveloperPreviewData(
        accountKey: String = HistoryAccountIdentity.legacyKey
    ) throws {
        try prepareDatabase()
        let statement = try prepare("""
            DELETE FROM quota_samples
            WHERE account_key = ? AND window_id = ?;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(accountKey, at: 1, in: statement)
        try bind(Self.developerPreviewWindowID, at: 2, in: statement)
        try stepDone(statement)
    }

    func storageSize() -> Int64 {
        let paths = [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
        return paths.reduce(0) { total, path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else {
                return total
            }
            return total + size.int64Value
        }
    }

    func exportCSV(
        accountKey: String = HistoryAccountIdentity.legacyKey
    ) throws -> Data {
        try prepareDatabase()
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestampFormatter.timeZone = .current
        var rows = [
            "record_type,timestamp,recorded_at,window_id,window_name,remaining_percent,window_duration_mins,resets_at,segment_start,anchor,source,start_date,tokens"
        ]
        let quotaStatement = try prepare("""
            SELECT sampled_at, window_id, window_name, remaining_percent,
                   window_duration_mins, resets_at, starts_segment, is_anchor, source
            FROM quota_samples
            WHERE account_key = ? ORDER BY sampled_at ASC;
            """)
        defer { sqlite3_finalize(quotaStatement) }
        try bind(accountKey, at: 1, in: quotaStatement)
        while sqlite3_step(quotaStatement) == SQLITE_ROW {
            let timestamp = sqlite3_column_double(quotaStatement, 0)
            let values = [
                "quota",
                String(timestamp),
                timestampFormatter.string(from: Date(timeIntervalSince1970: timestamp)),
                try text(quotaStatement, column: 1),
                try text(quotaStatement, column: 2),
                String(Int(sqlite3_column_int(quotaStatement, 3))),
                optionalInt(quotaStatement, column: 4).map { String($0) } ?? "",
                optionalDouble(quotaStatement, column: 5).map { String($0) } ?? "",
                String(Int(sqlite3_column_int(quotaStatement, 6))),
                String(Int(sqlite3_column_int(quotaStatement, 7))),
                try text(quotaStatement, column: 8),
                "",
                ""
            ]
            rows.append(values.map(csvEscape).joined(separator: ","))
        }

        let tokenStatement = try prepare("""
            SELECT start_date, tokens, fetched_at FROM token_daily
            WHERE account_key = ? ORDER BY start_date ASC;
            """)
        defer { sqlite3_finalize(tokenStatement) }
        try bind(accountKey, at: 1, in: tokenStatement)
        while sqlite3_step(tokenStatement) == SQLITE_ROW {
            let timestamp = sqlite3_column_double(tokenStatement, 2)
            let values = [
                "token_daily",
                String(timestamp),
                timestampFormatter.string(from: Date(timeIntervalSince1970: timestamp)),
                "", "", "", "", "", "", "", "",
                try text(tokenStatement, column: 0),
                String(sqlite3_column_int64(tokenStatement, 1))
            ]
            rows.append(values.map(csvEscape).joined(separator: ","))
        }

        guard let data = (rows.joined(separator: "\n") + "\n").data(using: .utf8) else {
            throw UsageHistoryStoreError.invalidText
        }
        return data
    }

    private func migrateIfNeeded() throws {
        let version = try userVersion()
        guard version <= Self.schemaVersion else {
            throw UsageHistoryStoreError.sqlite("The history database is newer than this app supports.")
        }

        if version < 1 {
            try transaction {
                try execute("""
                    CREATE TABLE quota_samples (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        account_key TEXT NOT NULL,
                        window_id TEXT NOT NULL,
                        window_name TEXT NOT NULL,
                        sampled_at REAL NOT NULL,
                        remaining_percent INTEGER NOT NULL,
                        window_duration_mins INTEGER,
                        resets_at REAL,
                        is_anchor INTEGER NOT NULL DEFAULT 0,
                        is_stale INTEGER NOT NULL DEFAULT 0,
                        starts_segment INTEGER NOT NULL DEFAULT 0,
                        source TEXT NOT NULL DEFAULT 'refresh'
                    );
                    """)
                try execute("""
                    CREATE TABLE token_daily (
                        account_key TEXT NOT NULL,
                        start_date TEXT NOT NULL,
                        tokens INTEGER NOT NULL,
                        fetched_at REAL NOT NULL,
                        PRIMARY KEY (account_key, start_date)
                    );
                    """)
                try execute("""
                    CREATE TABLE token_summary (
                        account_key TEXT PRIMARY KEY,
                        lifetime_tokens INTEGER,
                        peak_daily_tokens INTEGER,
                        current_streak_days INTEGER,
                        longest_streak_days INTEGER,
                        longest_running_turn_sec INTEGER,
                        fetched_at REAL NOT NULL
                    );
                    """)
                try execute("""
                    CREATE INDEX quota_samples_account_window_time
                    ON quota_samples(account_key, window_id, sampled_at);
                    """)
                try execute("PRAGMA user_version = 4;")
            }
        }

        if try userVersion() < 2 {
            try transaction {
                try execute("ALTER TABLE quota_samples ADD COLUMN starts_segment INTEGER NOT NULL DEFAULT 0;")
                try execute("ALTER TABLE quota_samples ADD COLUMN source TEXT NOT NULL DEFAULT 'refresh';")
                try execute("CREATE INDEX quota_samples_window_time ON quota_samples(window_id, sampled_at);")
                try execute("PRAGMA user_version = 2;")
            }
        }

        if try userVersion() < 3 {
            try transaction {
                try execute("""
                    ALTER TABLE quota_samples
                    ADD COLUMN account_key TEXT NOT NULL DEFAULT 'legacy';
                    """)
                try execute("DROP INDEX IF EXISTS quota_samples_window_time;")
                try execute("""
                    CREATE INDEX quota_samples_account_window_time
                    ON quota_samples(account_key, window_id, sampled_at);
                    """)

                try execute("ALTER TABLE token_daily RENAME TO token_daily_v2;")
                try execute("""
                    CREATE TABLE token_daily (
                        account_key TEXT NOT NULL,
                        start_date TEXT NOT NULL,
                        tokens INTEGER NOT NULL,
                        fetched_at REAL NOT NULL,
                        PRIMARY KEY (account_key, start_date)
                    );
                    """)
                try execute("""
                    INSERT INTO token_daily (account_key, start_date, tokens, fetched_at)
                    SELECT 'legacy', start_date, tokens, fetched_at FROM token_daily_v2;
                    """)
                try execute("DROP TABLE token_daily_v2;")

                try execute("ALTER TABLE token_summary RENAME TO token_summary_v2;")
                try execute("""
                    CREATE TABLE token_summary (
                        account_key TEXT PRIMARY KEY,
                        lifetime_tokens INTEGER,
                        peak_daily_tokens INTEGER,
                        current_streak_days INTEGER,
                        longest_streak_days INTEGER,
                        longest_running_turn_sec INTEGER,
                        fetched_at REAL NOT NULL
                    );
                    """)
                try execute("""
                    INSERT INTO token_summary (
                        account_key, lifetime_tokens, peak_daily_tokens,
                        current_streak_days, longest_streak_days,
                        longest_running_turn_sec, fetched_at
                    )
                    SELECT 'legacy', lifetime_tokens, peak_daily_tokens,
                           current_streak_days, longest_streak_days,
                           longest_running_turn_sec, fetched_at
                    FROM token_summary_v2 WHERE id = 1;
                    """)
                try execute("DROP TABLE token_summary_v2;")
                try execute("PRAGMA user_version = 3;")
            }
        }

        if try userVersion() < 4 {
            try transaction {
                // App Server labels returned windows by primary/secondary position.
                // When a new duration appears those positions can swap, so repair
                // existing rows into a duration-scoped identity before continuing.
                try execute("""
                    UPDATE quota_samples
                    SET window_id =
                        'duration:' || window_duration_mins || ':' ||
                        CASE
                            WHEN window_id LIKE '%-primary'
                                THEN substr(window_id, 1, length(window_id) - length('-primary'))
                            WHEN window_id LIKE '%-secondary'
                                THEN substr(window_id, 1, length(window_id) - length('-secondary'))
                            ELSE window_id
                        END
                    WHERE window_duration_mins IS NOT NULL
                      AND window_duration_mins > 0
                      AND window_id NOT LIKE 'duration:%';
                    """)
                try execute("PRAGMA user_version = 4;")
            }
        }
    }

    private func userVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw currentError()
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func accountHasHistory(_ accountKey: String) throws -> Bool {
        for table in ["quota_samples", "token_daily", "token_summary"] {
            let statement = try prepare("""
                SELECT EXISTS(SELECT 1 FROM \(table) WHERE account_key = ? LIMIT 1);
                """)
            defer { sqlite3_finalize(statement) }
            try bind(accountKey, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw currentError()
            }
            if sqlite3_column_int(statement, 0) == 1 {
                return true
            }
        }
        return false
    }

    private func insertQuotaSample(
        window: CodexUsageWindow,
        date: Date,
        remainingPercent: Int,
        startsSegment: Bool,
        isAnchor: Bool,
        isStale: Bool,
        source: QuotaSampleSource,
        accountKey: String
    ) throws {
        let statement = try prepare("""
            INSERT INTO quota_samples (
                account_key, window_id, window_name, sampled_at, remaining_percent,
                window_duration_mins, resets_at, is_anchor, is_stale,
                starts_segment, source
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }
        try bind(accountKey, at: 1, in: statement)
        try bind(window.historyID, at: 2, in: statement)
        try bind(window.name, at: 3, in: statement)
        sqlite3_bind_double(statement, 4, date.timeIntervalSince1970)
        sqlite3_bind_int(statement, 5, Int32(remainingPercent))
        bind(window.windowDurationMins, at: 6, in: statement)
        bind(window.resetsAt?.timeIntervalSince1970, at: 7, in: statement)
        sqlite3_bind_int(statement, 8, isAnchor ? 1 : 0)
        sqlite3_bind_int(statement, 9, isStale ? 1 : 0)
        sqlite3_bind_int(statement, 10, startsSegment ? 1 : 0)
        try bind(source.rawValue, at: 11, in: statement)
        try stepDone(statement)
    }

    private func latestQuotaSample(
        windowID: String,
        accountKey: String
    ) throws -> QuotaHistorySample? {
        let statement = try prepare("""
            SELECT id, window_id, window_name, sampled_at, remaining_percent,
                   window_duration_mins, resets_at, starts_segment, is_anchor,
                   is_stale, source
            FROM quota_samples
            WHERE account_key = ? AND window_id = ?
            ORDER BY sampled_at DESC LIMIT 1;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(accountKey, at: 1, in: statement)
        try bind(windowID, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeQuotaSample(statement)
    }

    private func decodeQuotaSample(_ statement: OpaquePointer?) throws -> QuotaHistorySample {
        QuotaHistorySample(
            id: sqlite3_column_int64(statement, 0),
            windowID: try text(statement, column: 1),
            windowName: try text(statement, column: 2),
            sampledAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            remainingPercent: Int(sqlite3_column_int(statement, 4)),
            windowDurationMins: optionalInt(statement, column: 5),
            resetsAt: optionalDouble(statement, column: 6).map(Date.init(timeIntervalSince1970:)),
            startsSegment: sqlite3_column_int(statement, 7) != 0,
            isAnchor: sqlite3_column_int(statement, 8) != 0,
            isStale: sqlite3_column_int(statement, 9) != 0,
            source: QuotaSampleSource(rawValue: try text(statement, column: 10)) ?? .refresh
        )
    }

    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try work()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw currentError()
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError()
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) throws {
        guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else {
            throw currentError()
        }
    }

    private func bind(_ value: Int?, at index: Int32, in statement: OpaquePointer?) {
        if let value {
            sqlite3_bind_int64(statement, index, Int64(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ value: Int64?, at index: Int32, in statement: OpaquePointer?) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func text(_ statement: OpaquePointer?, column: Int32) throws -> String {
        guard let bytes = sqlite3_column_text(statement, column) else {
            throw UsageHistoryStoreError.invalidText
        }
        return String(cString: bytes)
    }

    private func optionalInt(_ statement: OpaquePointer?, column: Int32) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, column))
    }

    private func optionalInt64(_ statement: OpaquePointer?, column: Int32) -> Int64? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, column)
    }

    private func optionalDouble(_ statement: OpaquePointer?, column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, column)
    }

    private func currentError() -> UsageHistoryStoreError {
        UsageHistoryStoreError.sqlite(
            database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error."
        )
    }

    private func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

}
