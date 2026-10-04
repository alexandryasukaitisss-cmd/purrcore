import Foundation
import SQLite3

public enum HistoryStoreError: Error, LocalizedError {
    case openFailed(String)
    case sqlite(message: String)
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message): "Не удалось открыть историю: \(message)"
        case .sqlite(let message): "Ошибка SQLite: \(message)"
        case .unsupportedSchema(let version): "Версия базы PurrCore \(version) новее поддерживаемой"
        }
    }
}

public actor HistoryStore {
    private let database: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let currentSchemaVersion = 1

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "неизвестная ошибка"
            if let handle { sqlite3_close(handle) }
            throw HistoryStoreError.openFailed(message)
        }
        database = handle

        try Self.execute(on: handle, sql: "PRAGMA journal_mode=WAL;")
        try Self.execute(on: handle, sql: "PRAGMA synchronous=NORMAL;")
        try Self.execute(on: handle, sql: "PRAGMA temp_store=MEMORY;")
        try Self.execute(on: handle, sql: "PRAGMA busy_timeout=3000;")
        try Self.migrateSchema(on: handle)
    }

    deinit {
        sqlite3_close(database)
    }

    public func addSystemSample(_ sample: SystemSnapshot) throws {
        let sql = """
        INSERT OR REPLACE INTO system_samples (
            timestamp, cpu_percent, memory_used_bytes,
            network_download_bps, network_upload_bps,
            disk_read_bps, disk_write_bps, thermal_state
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, sample.timestamp.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, sample.cpuPercent)
        sqlite3_bind_int64(statement, 3, Int64(clamping: sample.memory.usedBytes))
        sqlite3_bind_double(statement, 4, sample.network.downloadBytesPerSecond)
        sqlite3_bind_double(statement, 5, sample.network.uploadBytesPerSecond)
        sqlite3_bind_double(statement, 6, sample.disk.downloadBytesPerSecond)
        sqlite3_bind_double(statement, 7, sample.disk.uploadBytesPerSecond)
        bind(sample.thermalState.rawValue, to: 8, in: statement)
        try stepDone(statement)
    }

    public func addProcessSamples(_ samples: [ProcessGroupSample], at timestamp: Date) throws {
        guard !samples.isEmpty else { return }
        try execute("BEGIN IMMEDIATE;")
        do {
            let sql = """
            INSERT OR REPLACE INTO process_samples (
                timestamp, group_key, display_name, explanation, category,
                cpu_percent, resident_bytes, process_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }

            for sample in samples {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_double(statement, 1, timestamp.timeIntervalSince1970)
                bind(sample.groupKey, to: 2, in: statement)
                bind(sample.displayName, to: 3, in: statement)
                bind(sample.explanation, to: 4, in: statement)
                bind(sample.category.rawValue, to: 5, in: statement)
                sqlite3_bind_double(statement, 6, sample.cpuPercent)
                sqlite3_bind_int64(statement, 7, Int64(clamping: sample.residentBytes))
                sqlite3_bind_int(statement, 8, Int32(sample.processCount))
                try stepDone(statement)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func addTaskMarker(_ marker: TaskMarker) throws {
        let sql = """
        INSERT OR REPLACE INTO task_markers (id, source, task_id, label, kind, timestamp)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        bind(marker.id, to: 1, in: statement)
        bind(marker.source, to: 2, in: statement)
        bind(marker.taskID, to: 3, in: statement)
        bind(marker.label, to: 4, in: statement)
        bind(marker.kind.rawValue, to: 5, in: statement)
        sqlite3_bind_double(statement, 6, marker.timestamp.timeIntervalSince1970)
        try stepDone(statement)
    }

    public func saveUsageBatch(_ batch: UsagePersistenceBatch) throws {
        guard !batch.isEmpty else { return }
        try execute("BEGIN IMMEDIATE;")
        do {
            let usageSQL = """
            INSERT INTO usage_sessions (
                id, started_at, ended_at, awake_seconds, battery_awake_seconds
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                ended_at = MAX(usage_sessions.ended_at, excluded.ended_at),
                awake_seconds = MAX(usage_sessions.awake_seconds, excluded.awake_seconds),
                battery_awake_seconds = MAX(usage_sessions.battery_awake_seconds, excluded.battery_awake_seconds);
            """
            let usageStatement = try prepare(usageSQL)
            defer { sqlite3_finalize(usageStatement) }

            let usageRecords = batch.completedUsageSegments + [batch.currentUsageSegment].compactMap { $0 }
            for record in usageRecords {
                sqlite3_reset(usageStatement)
                sqlite3_clear_bindings(usageStatement)
                bind(record.id, to: 1, in: usageStatement)
                sqlite3_bind_double(usageStatement, 2, record.startedAt.timeIntervalSince1970)
                sqlite3_bind_double(usageStatement, 3, record.endedAt.timeIntervalSince1970)
                sqlite3_bind_double(usageStatement, 4, record.awakeSeconds)
                sqlite3_bind_double(usageStatement, 5, record.batteryAwakeSeconds)
                try stepDone(usageStatement)
            }

            let batterySQL = """
            INSERT INTO battery_sessions (
                id, started_at, ended_at, last_observed_at,
                start_percent, end_percent, awake_seconds,
                start_boundary_known, end_boundary_known
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                ended_at = CASE
                    WHEN excluded.last_observed_at >= battery_sessions.last_observed_at THEN excluded.ended_at
                    ELSE battery_sessions.ended_at
                END,
                last_observed_at = MAX(battery_sessions.last_observed_at, excluded.last_observed_at),
                end_percent = CASE
                    WHEN excluded.last_observed_at >= battery_sessions.last_observed_at THEN excluded.end_percent
                    ELSE battery_sessions.end_percent
                END,
                awake_seconds = MAX(battery_sessions.awake_seconds, excluded.awake_seconds),
                start_boundary_known = MIN(
                    battery_sessions.start_boundary_known,
                    excluded.start_boundary_known
                ),
                end_boundary_known = CASE
                    WHEN excluded.last_observed_at >= battery_sessions.last_observed_at THEN excluded.end_boundary_known
                    ELSE battery_sessions.end_boundary_known
                END;
            """
            let batteryStatement = try prepare(batterySQL)
            defer { sqlite3_finalize(batteryStatement) }

            let batteryRecords = batch.completedBatterySessions + [batch.activeBatterySession].compactMap { $0 }
            for record in batteryRecords {
                sqlite3_reset(batteryStatement)
                sqlite3_clear_bindings(batteryStatement)
                bind(record.id, to: 1, in: batteryStatement)
                sqlite3_bind_double(batteryStatement, 2, record.startedAt.timeIntervalSince1970)
                bind(record.endedAt, to: 3, in: batteryStatement)
                sqlite3_bind_double(batteryStatement, 4, record.lastObservedAt.timeIntervalSince1970)
                sqlite3_bind_double(batteryStatement, 5, record.startPercent)
                sqlite3_bind_double(batteryStatement, 6, record.endPercent)
                sqlite3_bind_double(batteryStatement, 7, record.awakeSeconds)
                sqlite3_bind_int(batteryStatement, 8, record.startBoundaryKnown ? 1 : 0)
                sqlite3_bind_int(batteryStatement, 9, record.endBoundaryKnown ? 1 : 0)
                try stepDone(batteryStatement)
            }

            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func loadActiveBatterySession() throws -> BatterySessionRecord? {
        let statement = try prepare("""
        SELECT id, started_at, ended_at, last_observed_at,
               start_percent, end_percent, awake_seconds,
               start_boundary_known, end_boundary_known
        FROM battery_sessions
        WHERE ended_at IS NULL
        ORDER BY last_observed_at DESC
        LIMIT 1;
        """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return batterySession(from: statement)
    }

    public func loadUsageReport(
        since: Date,
        until: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> UsageReport {
        let usageStatement = try prepare("""
        SELECT started_at, awake_seconds, battery_awake_seconds
        FROM usage_sessions
        WHERE ended_at >= ? AND started_at <= ?
        ORDER BY started_at ASC;
        """)
        defer { sqlite3_finalize(usageStatement) }
        sqlite3_bind_double(usageStatement, 1, since.timeIntervalSince1970)
        sqlite3_bind_double(usageStatement, 2, until.timeIntervalSince1970)

        var totals: [Date: (awake: TimeInterval, battery: TimeInterval)] = [:]
        while sqlite3_step(usageStatement) == SQLITE_ROW {
            let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(usageStatement, 0))
            let day = calendar.startOfDay(for: startedAt)
            let current = totals[day] ?? (0, 0)
            totals[day] = (
                current.awake + max(sqlite3_column_double(usageStatement, 1), 0),
                current.battery + max(sqlite3_column_double(usageStatement, 2), 0)
            )
        }
        try checkLastStep(usageStatement)

        let firstDay = calendar.startOfDay(for: since)
        let finalDay = calendar.startOfDay(for: until)
        var daily: [DailyUsagePoint] = []
        var day = firstDay
        while day <= finalDay {
            let values = totals[day] ?? (0, 0)
            daily.append(
                DailyUsagePoint(
                    day: day,
                    awakeSeconds: values.awake,
                    batteryAwakeSeconds: values.battery
                )
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }

        let batteryStatement = try prepare("""
        SELECT id, started_at, ended_at, last_observed_at,
               start_percent, end_percent, awake_seconds,
               start_boundary_known, end_boundary_known
        FROM battery_sessions
        WHERE started_at <= ?
        ORDER BY last_observed_at DESC;
        """)
        defer { sqlite3_finalize(batteryStatement) }
        sqlite3_bind_double(batteryStatement, 1, until.timeIntervalSince1970)

        var batterySessions: [BatterySessionRecord] = []
        while sqlite3_step(batteryStatement) == SQLITE_ROW {
            if let session = batterySession(from: batteryStatement) {
                batterySessions.append(session)
            }
        }
        try checkLastStep(batteryStatement)

        let today = daily.last(where: { calendar.isDate($0.day, inSameDayAs: until) })
        let active = batterySessions.first(where: { $0.endedAt == nil })
        return UsageReport(
            daily: daily,
            todayAwakeSeconds: today?.awakeSeconds ?? 0,
            todayBatteryAwakeSeconds: today?.batteryAwakeSeconds ?? 0,
            currentBatterySession: active,
            latestBatterySession: active ?? batterySessions.first,
            fullChargeEstimate: UsageEstimator.fullChargeEstimate(from: batterySessions)
        )
    }

    public func purge(olderThan cutoff: Date) throws {
        for table in ["system_samples", "process_samples", "task_markers"] {
            let statement = try prepare("DELETE FROM \(table) WHERE timestamp < ?;")
            sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
            try stepDone(statement)
            sqlite3_finalize(statement)
        }
        let usageStatement = try prepare("DELETE FROM usage_sessions WHERE ended_at < ?;")
        sqlite3_bind_double(usageStatement, 1, cutoff.timeIntervalSince1970)
        try stepDone(usageStatement)
        sqlite3_finalize(usageStatement)
        try execute("PRAGMA wal_checkpoint(PASSIVE);")
    }

    /// Only completed sessions expire. The active discharge is always preserved.
    public func purgeBatterySessions(endedBefore cutoff: Date) throws {
        let statement = try prepare("DELETE FROM battery_sessions WHERE ended_at IS NOT NULL AND ended_at < ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        try stepDone(statement)
    }

    public func loadSystemHistory(since: Date, until: Date, maxPoints: Int) throws -> [HistoryPoint] {
        let safeMaxPoints = max(maxPoints, 1)
        let span = max(until.timeIntervalSince(since), 1)
        let bucketWidth = max(span / Double(safeMaxPoints), 1)
        let sql = """
        SELECT
            MIN(CAST((timestamp - ?) / ? AS INTEGER), ? - 1) AS bucket,
            AVG(cpu_percent), AVG(memory_used_bytes),
            AVG(network_download_bps), AVG(network_upload_bps),
            AVG(disk_read_bps), AVG(disk_write_bps)
        FROM system_samples
        WHERE timestamp >= ? AND timestamp <= ?
        GROUP BY bucket
        ORDER BY bucket ASC;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, bucketWidth)
        sqlite3_bind_int64(statement, 3, Int64(safeMaxPoints))
        sqlite3_bind_double(statement, 4, since.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, until.timeIntervalSince1970)

        var points: [HistoryPoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let bucketTimestamp = since.timeIntervalSince1970
                + Double(sqlite3_column_int64(statement, 0)) * bucketWidth
            points.append(
                HistoryPoint(
                    timestamp: Date(timeIntervalSince1970: min(max(bucketTimestamp, since.timeIntervalSince1970), until.timeIntervalSince1970)),
                    cpuPercent: sqlite3_column_double(statement, 1),
                    memoryUsedBytes: UInt64(max(sqlite3_column_int64(statement, 2), 0)),
                    networkDownloadBytesPerSecond: sqlite3_column_double(statement, 3),
                    networkUploadBytesPerSecond: sqlite3_column_double(statement, 4),
                    diskReadBytesPerSecond: sqlite3_column_double(statement, 5),
                    diskWriteBytesPerSecond: sqlite3_column_double(statement, 6)
                )
            )
        }
        try checkLastStep(statement)
        return points
    }

    public func loadTaskMarkers(since: Date, until: Date) throws -> [TaskMarker] {
        let sql = """
        SELECT id, source, task_id, label, kind, timestamp
        FROM task_markers
        WHERE timestamp >= ? AND timestamp <= ?
        ORDER BY timestamp ASC;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, until.timeIntervalSince1970)

        var markers: [TaskMarker] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = text(at: 0, in: statement),
                let source = text(at: 1, in: statement),
                let taskID = text(at: 2, in: statement),
                let label = text(at: 3, in: statement),
                let kindRaw = text(at: 4, in: statement),
                let kind = TaskEventKind(rawValue: kindRaw)
            else { continue }

            markers.append(
                TaskMarker(
                    id: id,
                    source: source,
                    taskID: taskID,
                    label: label,
                    kind: kind,
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                )
            )
        }
        try checkLastStep(statement)
        return markers
    }

    public func loadTopProcessGroups(since: Date, limit: Int = 12) throws -> [ProcessGroupSample] {
        let sql = """
        SELECT group_key, MAX(display_name), MAX(explanation), MAX(category),
               AVG(cpu_percent), MAX(resident_bytes), MAX(process_count)
        FROM process_samples
        WHERE timestamp >= ?
        GROUP BY group_key
        ORDER BY AVG(cpu_percent) DESC
        LIMIT ?;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        sqlite3_bind_int(statement, 2, Int32(max(limit, 1)))

        var samples: [ProcessGroupSample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let key = text(at: 0, in: statement),
                let name = text(at: 1, in: statement),
                let explanation = text(at: 2, in: statement),
                let categoryRaw = text(at: 3, in: statement),
                let category = ProcessCategory(rawValue: categoryRaw)
            else { continue }

            samples.append(
                ProcessGroupSample(
                    groupKey: key,
                    displayName: name,
                    explanation: explanation,
                    category: category,
                    cpuPercent: sqlite3_column_double(statement, 4),
                    residentBytes: UInt64(max(sqlite3_column_int64(statement, 5), 0)),
                    processCount: Int(sqlite3_column_int(statement, 6))
                )
            )
        }
        try checkLastStep(statement)
        return samples
    }

    public func databaseSizeBytes() -> UInt64 {
        let pageCount = scalarInt64("PRAGMA page_count;")
        let pageSize = scalarInt64("PRAGMA page_size;")
        return UInt64(max(pageCount * pageSize, 0))
    }

    public func schemaVersion() -> Int {
        Int(scalarInt64("PRAGMA user_version;"))
    }

    private static func migrateSchema(on database: OpaquePointer) throws {
        let version = Int(scalarInt64(on: database, sql: "PRAGMA user_version;"))
        guard version <= currentSchemaVersion else {
            throw HistoryStoreError.unsupportedSchema(version)
        }

        try execute(on: database, sql: "BEGIN IMMEDIATE;")
        do {
            try execute(on: database, sql: """
        CREATE TABLE IF NOT EXISTS system_samples (
            timestamp REAL PRIMARY KEY,
            cpu_percent REAL NOT NULL,
            memory_used_bytes INTEGER NOT NULL,
            network_download_bps REAL NOT NULL,
            network_upload_bps REAL NOT NULL,
            disk_read_bps REAL NOT NULL,
            disk_write_bps REAL NOT NULL,
            thermal_state TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS process_samples (
            timestamp REAL NOT NULL,
            group_key TEXT NOT NULL,
            display_name TEXT NOT NULL,
            explanation TEXT NOT NULL,
            category TEXT NOT NULL,
            cpu_percent REAL NOT NULL,
            resident_bytes INTEGER NOT NULL,
            process_count INTEGER NOT NULL,
            PRIMARY KEY (timestamp, group_key)
        );
        CREATE INDEX IF NOT EXISTS process_samples_timestamp_idx ON process_samples(timestamp);
        CREATE TABLE IF NOT EXISTS task_markers (
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            task_id TEXT NOT NULL,
            label TEXT NOT NULL,
            kind TEXT NOT NULL,
            timestamp REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS task_markers_timestamp_idx ON task_markers(timestamp);
        CREATE TABLE IF NOT EXISTS usage_sessions (
            id TEXT PRIMARY KEY,
            started_at REAL NOT NULL,
            ended_at REAL NOT NULL,
            awake_seconds REAL NOT NULL,
            battery_awake_seconds REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS usage_sessions_ended_at_idx ON usage_sessions(ended_at);
        CREATE TABLE IF NOT EXISTS battery_sessions (
            id TEXT PRIMARY KEY,
            started_at REAL NOT NULL,
            ended_at REAL,
            last_observed_at REAL NOT NULL,
            start_percent REAL NOT NULL,
            end_percent REAL NOT NULL,
            awake_seconds REAL NOT NULL,
            start_boundary_known INTEGER NOT NULL,
            end_boundary_known INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS battery_sessions_last_observed_idx ON battery_sessions(last_observed_at);
        """)
            if version < currentSchemaVersion {
                try execute(on: database, sql: "PRAGMA user_version = \(currentSchemaVersion);")
            }
            try execute(on: database, sql: "COMMIT;")
        } catch {
            try? execute(on: database, sql: "ROLLBACK;")
            throw error
        }
    }

    private static func execute(on database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw HistoryStoreError.sqlite(message: message)
        }
    }

    private func execute(_ sql: String) throws {
        try Self.execute(on: database, sql: sql)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoryStoreError.sqlite(message: String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ value: Date?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw HistoryStoreError.sqlite(message: String(cString: sqlite3_errmsg(database)))
        }
    }

    private func checkLastStep(_ statement: OpaquePointer) throws {
        let code = sqlite3_errcode(database)
        guard code == SQLITE_OK || code == SQLITE_DONE || code == SQLITE_ROW else {
            throw HistoryStoreError.sqlite(message: String(cString: sqlite3_errmsg(database)))
        }
    }

    private func text(at index: Int32, in statement: OpaquePointer) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    private func scalarInt64(_ sql: String) -> Int64 {
        guard let statement = try? prepare(sql) else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private static func scalarInt64(on database: OpaquePointer, sql: String) -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private func batterySession(from statement: OpaquePointer) -> BatterySessionRecord? {
        guard let id = text(at: 0, in: statement) else { return nil }
        let endedAt = sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        return BatterySessionRecord(
            id: id,
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            endedAt: endedAt,
            lastObservedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            startPercent: sqlite3_column_double(statement, 4),
            endPercent: sqlite3_column_double(statement, 5),
            awakeSeconds: sqlite3_column_double(statement, 6),
            startBoundaryKnown: sqlite3_column_int(statement, 7) != 0,
            endBoundaryKnown: sqlite3_column_int(statement, 8) != 0
        )
    }
}
