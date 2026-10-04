import Foundation
import SQLite3
import XCTest
@testable import PurrCoreCore

final class HistoryStoreTests: XCTestCase {
    func testBatteryExpiryPreservesActiveAndBoundarySessionsAndDefaultResourcePurgeKeepsBatteryHistory() async throws {
        let fixture = try TemporaryHistoryFixture()
        let store = try HistoryStore(url: fixture.databaseURL)
        let cutoff = Date(timeIntervalSince1970: 2_000_000_000)
        func session(_ id: String, end: Date?) -> BatterySessionRecord {
            BatterySessionRecord(id: id, startedAt: cutoff.addingTimeInterval(-1_000_000),
                endedAt: end, lastObservedAt: end ?? cutoff, startPercent: 100, endPercent: 80,
                awakeSeconds: 7_200, startBoundaryKnown: true, endBoundaryKnown: end != nil)
        }
        try await store.saveUsageBatch(UsagePersistenceBatch(completedUsageSegments: [], currentUsageSegment: nil,
            completedBatterySessions: [session("old", end: cutoff.addingTimeInterval(-1)),
                session("boundary", end: cutoff), session("new", end: cutoff.addingTimeInterval(1))],
            activeBatterySession: session("active", end: nil)))
        try await store.purge(olderThan: cutoff)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(fixture.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let db = try XCTUnwrap(database)
        defer { sqlite3_close(db) }
        func ids() throws -> [String] {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT id FROM battery_sessions ORDER BY id;", -1, &statement, nil), SQLITE_OK)
            let query = try XCTUnwrap(statement)
            defer { sqlite3_finalize(query) }
            var values: [String] = []
            while sqlite3_step(query) == SQLITE_ROW { values.append(String(cString: sqlite3_column_text(query, 0))) }
            return values
        }
        XCTAssertEqual(try ids(), ["active", "boundary", "new", "old"])
        try await store.purgeBatterySessions(endedBefore: cutoff)
        XCTAssertEqual(try ids(), ["active", "boundary", "new"])
        let active = try await store.loadActiveBatterySession()
        XCTAssertEqual(active?.id, "active")
    }

    func testPurgesSamplesOlderThanSevenDays() async throws {
        let fixture = try TemporaryHistoryFixture()
        let store = try HistoryStore(url: fixture.databaseURL)
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        try await store.addSystemSample(.fixture(at: now.addingTimeInterval(-8 * 86_400), cpu: 90))
        try await store.addSystemSample(.fixture(at: now.addingTimeInterval(-6 * 86_400), cpu: 30))
        try await store.purge(olderThan: now.addingTimeInterval(-7 * 86_400))

        let points = try await store.loadSystemHistory(
            since: now.addingTimeInterval(-9 * 86_400),
            until: now,
            maxPoints: 100
        )

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.cpuPercent, 30)
    }

    func testDownsamplesLongHistoryToBoundedPointCount() async throws {
        let fixture = try TemporaryHistoryFixture()
        let store = try HistoryStore(url: fixture.databaseURL)
        let start = Date(timeIntervalSince1970: 2_000_000_000)

        for offset in 0..<600 {
            try await store.addSystemSample(.fixture(at: start.addingTimeInterval(Double(offset)), cpu: Double(offset % 100)))
        }

        let points = try await store.loadSystemHistory(
            since: start,
            until: start.addingTimeInterval(600),
            maxPoints: 60
        )

        XCTAssertLessThanOrEqual(points.count, 60)
        XCTAssertGreaterThan(points.count, 50)
    }

    func testHistoryBucketsStayWithinRequestedRangeAndPointLimit() async throws {
        let fixture = try TemporaryHistoryFixture()
        let store = try HistoryStore(url: fixture.databaseURL)
        let since = Date(timeIntervalSince1970: 2_000_000_003)
        let until = since.addingTimeInterval(600)

        for offset in stride(from: 0, through: 600, by: 10) {
            try await store.addSystemSample(.fixture(at: since.addingTimeInterval(Double(offset)), cpu: Double(offset) / 10))
        }

        let points = try await store.loadSystemHistory(since: since, until: until, maxPoints: 60)

        XCTAssertLessThanOrEqual(points.count, 60)
        XCTAssertTrue(points.allSatisfy { $0.timestamp >= since && $0.timestamp <= until })
        XCTAssertEqual(try XCTUnwrap(points.last).cpuPercent, 59.5, accuracy: 0.001)
    }

    func testHistoryBucketsAggregateInclusiveBoundarySamples() async throws {
        let fixture = try TemporaryHistoryFixture()
        let store = try HistoryStore(url: fixture.databaseURL)
        let since = Date(timeIntervalSince1970: 2_000_000_123)
        let samples: [(Int, Double, UInt64, Double, Double, Double, Double)] = [
            (0, 10, 100, 10, 20, 30, 40),
            (5, 30, 300, 30, 40, 50, 60),
            (10, 50, 500, 50, 60, 70, 80)
        ]
        for (offset, cpu, memory, download, upload, diskRead, diskWrite) in samples {
            try await store.addSystemSample(
                .fixture(
                    at: since.addingTimeInterval(Double(offset)),
                    cpu: cpu,
                    memory: memory,
                    download: download,
                    upload: upload,
                    diskRead: diskRead,
                    diskWrite: diskWrite
                )
            )
        }

        let points = try await store.loadSystemHistory(
            since: since,
            until: since.addingTimeInterval(10),
            maxPoints: 2
        )

        XCTAssertEqual(points.count, 2)
        XCTAssertTrue(points.allSatisfy { $0.timestamp >= since && $0.timestamp <= since.addingTimeInterval(10) })
        XCTAssertEqual(points[0].cpuPercent, 10, accuracy: 0.001)
        XCTAssertEqual(points[1].cpuPercent, 40, accuracy: 0.001)
        XCTAssertEqual(points[1].memoryUsedBytes, 400)
        XCTAssertEqual(points[1].networkDownloadBytesPerSecond, 40, accuracy: 0.001)
        XCTAssertEqual(points[1].networkUploadBytesPerSecond, 50, accuracy: 0.001)
        XCTAssertEqual(points[1].diskReadBytesPerSecond, 60, accuracy: 0.001)
        XCTAssertEqual(points[1].diskWriteBytesPerSecond, 70, accuracy: 0.001)

        let singlePoint = try await store.loadSystemHistory(
            since: since,
            until: since.addingTimeInterval(10),
            maxPoints: 0
        )
        XCTAssertEqual(singlePoint.count, 1)
        XCTAssertEqual(singlePoint[0].timestamp, since)
        XCTAssertEqual(singlePoint[0].cpuPercent, 30, accuracy: 0.001)
        XCTAssertEqual(singlePoint[0].memoryUsedBytes, 300)
    }

    func testStoredHistoryStopsBeforeNonalignedLiveSample() async throws {
        let fixture = try TemporaryHistoryFixture()
        let store = try HistoryStore(url: fixture.databaseURL)
        let since = Date(timeIntervalSince1970: 2_000_000_000)
        let firstLive = since.addingTimeInterval(3.5)
        try await store.addSystemSample(.fixture(at: since.addingTimeInterval(1), cpu: 10))
        try await store.addSystemSample(.fixture(at: firstLive, cpu: 90))
        try await store.addSystemSample(.fixture(at: since.addingTimeInterval(5), cpu: 90))

        let stored = try await store.loadSystemHistory(
            since: since,
            until: Date(timeIntervalSince1970: firstLive.timeIntervalSince1970.nextDown),
            maxPoints: 1
        )
        let live = [HistoryPoint(snapshot: .fixture(at: firstLive, cpu: 90))]
        let merged = HistoryPoint.mergedAndDownsampled(
            stored: stored,
            live: live,
            since: since,
            until: since.addingTimeInterval(10),
            maximumCount: 720
        )

        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].cpuPercent, 10)
        XCTAssertEqual(merged.map(\.cpuPercent), [10, 90])
        XCTAssertEqual(merged.last?.timestamp, firstLive)
    }

    func testMergesOverlappingHistoryAndBoundsRepresentativeSeries() throws {
        let since = Date(timeIntervalSince1970: 2_000_000_000)
        let until = since.addingTimeInterval(1_800)
        func point(at offset: Int, cpu: Double) -> HistoryPoint {
            HistoryPoint(
                timestamp: since.addingTimeInterval(Double(offset)),
                cpuPercent: cpu,
                memoryUsedBytes: UInt64(cpu * 100),
                networkDownloadBytesPerSecond: cpu,
                networkUploadBytesPerSecond: cpu + 1,
                diskReadBytesPerSecond: cpu + 2,
                diskWriteBytesPerSecond: cpu + 3
            )
        }
        let stored = (-1...1_000).map { point(at: $0, cpu: 10) }
        let live = (902...1_801).map { point(at: $0, cpu: 20) }

        let merged = HistoryPoint.mergedAndDownsampled(
            stored: stored,
            live: live,
            since: since,
            until: until,
            maximumCount: 2_000
        )

        XCTAssertEqual(merged.count, 1_801)
        XCTAssertEqual(merged[902].timestamp, since.addingTimeInterval(902))
        XCTAssertEqual(merged[902].cpuPercent, 20)

        let bounded = HistoryPoint.mergedAndDownsampled(
            stored: stored,
            live: live,
            since: since,
            until: until,
            maximumCount: 720
        )

        XCTAssertEqual(bounded.count, 720)
        XCTAssertEqual(bounded.first?.timestamp, since)
        XCTAssertEqual(bounded.first?.cpuPercent, 10)
        XCTAssertEqual(bounded.last?.timestamp, until)
        XCTAssertEqual(bounded.last?.cpuPercent, 20)
        XCTAssertTrue(bounded.allSatisfy { $0.timestamp >= since && $0.timestamp <= until })
        XCTAssertTrue(zip(bounded, bounded.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })
        let averagedPoint = try XCTUnwrap(bounded.dropFirst().dropLast().first { $0.cpuPercent > 10 && $0.cpuPercent < 20 })
        XCTAssertEqual(Double(averagedPoint.memoryUsedBytes), averagedPoint.cpuPercent * 100, accuracy: 1)
        XCTAssertEqual(averagedPoint.networkDownloadBytesPerSecond, averagedPoint.cpuPercent, accuracy: 0.001)
        XCTAssertEqual(averagedPoint.networkUploadBytesPerSecond, averagedPoint.cpuPercent + 1, accuracy: 0.001)
        XCTAssertEqual(averagedPoint.diskReadBytesPerSecond, averagedPoint.cpuPercent + 2, accuracy: 0.001)
        XCTAssertEqual(averagedPoint.diskWriteBytesPerSecond, averagedPoint.cpuPercent + 3, accuracy: 0.001)
    }

    func testStoresTaskMarkersForOptionalExternalIntegration() async throws {
        let fixture = try TemporaryHistoryFixture()
        let store = try HistoryStore(url: fixture.databaseURL)
        let timestamp = Date(timeIntervalSince1970: 2_000_000_000)
        let marker = TaskMarker(
            id: "marker-1",
            source: "mempalace",
            taskID: "task-42",
            label: "Индексация памяти",
            kind: .begin,
            timestamp: timestamp
        )

        try await store.addTaskMarker(marker)
        let markers = try await store.loadTaskMarkers(since: timestamp.addingTimeInterval(-1), until: timestamp.addingTimeInterval(1))

        XCTAssertEqual(markers, [marker])
    }

    func testMigratesLegacyDatabaseWithoutLosingSystemHistory() async throws {
        let fixture = try TemporaryHistoryFixture()
        let timestamp = Date(timeIntervalSince1970: 2_000_000_000)
        try createLegacyDatabase(at: fixture.databaseURL, timestamp: timestamp)

        let store = try HistoryStore(url: fixture.databaseURL)
        let points = try await store.loadSystemHistory(
            since: timestamp.addingTimeInterval(-1),
            until: timestamp.addingTimeInterval(1),
            maxPoints: 10
        )

        let schemaVersion = await store.schemaVersion()
        XCTAssertEqual(schemaVersion, 1)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.cpuPercent, 42)
    }

    func testStoresUsageAndBuildsDailyBatteryReport() async throws {
        let fixture = try TemporaryHistoryFixture()
        let store = try HistoryStore(url: fixture.databaseURL)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = Date(timeIntervalSince1970: 2_000_073_600)
        let yesterday = today.addingTimeInterval(-86_400)

        let active = BatterySessionRecord(
            id: "battery-active",
            startedAt: today,
            endedAt: nil,
            lastObservedAt: today.addingTimeInterval(7_200),
            startPercent: 100,
            endPercent: 80,
            awakeSeconds: 7_200,
            startBoundaryKnown: true,
            endBoundaryKnown: false
        )
        let completed = BatterySessionRecord(
            id: "battery-completed",
            startedAt: yesterday,
            endedAt: yesterday.addingTimeInterval(18_000),
            lastObservedAt: yesterday.addingTimeInterval(18_000),
            startPercent: 100,
            endPercent: 50,
            awakeSeconds: 18_000,
            startBoundaryKnown: true,
            endBoundaryKnown: true
        )
        let batch = UsagePersistenceBatch(
            completedUsageSegments: [
                UsageSegmentRecord(
                    id: "usage-yesterday",
                    startedAt: yesterday,
                    endedAt: yesterday.addingTimeInterval(3_600),
                    awakeSeconds: 3_600,
                    batteryAwakeSeconds: 1_800
                )
            ],
            currentUsageSegment: UsageSegmentRecord(
                id: "usage-today",
                startedAt: today,
                endedAt: today.addingTimeInterval(7_200),
                awakeSeconds: 7_200,
                batteryAwakeSeconds: 7_200
            ),
            completedBatterySessions: [completed],
            activeBatterySession: active
        )

        try await store.saveUsageBatch(batch)
        let report = try await store.loadUsageReport(
            since: yesterday,
            until: today.addingTimeInterval(8_000),
            calendar: calendar
        )

        XCTAssertEqual(report.daily.count, 2)
        XCTAssertEqual(report.daily[0].awakeSeconds, 3_600, accuracy: 0.001)
        XCTAssertEqual(report.daily[1].awakeSeconds, 7_200, accuracy: 0.001)
        XCTAssertEqual(report.todayBatteryAwakeSeconds, 7_200, accuracy: 0.001)
        XCTAssertEqual(report.currentBatterySession?.id, "battery-active")
        XCTAssertEqual(report.latestBatterySession?.id, "battery-active")
        XCTAssertEqual(report.fullChargeEstimate?.sessionCount, 2)
        XCTAssertEqual(report.fullChargeEstimate?.seconds ?? 0, 36_000, accuracy: 0.001)
    }

    func testRecentInvalidBatterySessionsDoNotHideOlderEstimateCandidates() async throws {
        let fixture = try TemporaryHistoryFixture()
        let store = try HistoryStore(url: fixture.databaseURL)
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let validSessions = [
            BatterySessionRecord(
                id: "valid-1",
                startedAt: start,
                endedAt: start.addingTimeInterval(18_000),
                lastObservedAt: start.addingTimeInterval(18_000),
                startPercent: 100,
                endPercent: 50,
                awakeSeconds: 18_000,
                startBoundaryKnown: true,
                endBoundaryKnown: true
            ),
            BatterySessionRecord(
                id: "valid-2",
                startedAt: start.addingTimeInterval(86_400),
                endedAt: start.addingTimeInterval(86_400 + 10_800),
                lastObservedAt: start.addingTimeInterval(86_400 + 10_800),
                startPercent: 90,
                endPercent: 60,
                awakeSeconds: 10_800,
                startBoundaryKnown: true,
                endBoundaryKnown: true
            )
        ]
        let invalidSessions = (0..<13).map { index in
            let sessionStart = start.addingTimeInterval(Double(index + 2) * 86_400)
            return BatterySessionRecord(
                id: "invalid-\(index)",
                startedAt: sessionStart,
                endedAt: sessionStart.addingTimeInterval(1_800),
                lastObservedAt: sessionStart.addingTimeInterval(1_800),
                startPercent: 80,
                endPercent: 75,
                awakeSeconds: 1_800,
                startBoundaryKnown: true,
                endBoundaryKnown: true
            )
        }
        let batch = UsagePersistenceBatch(
            completedUsageSegments: [],
            currentUsageSegment: nil,
            completedBatterySessions: validSessions + invalidSessions,
            activeBatterySession: nil
        )

        try await store.saveUsageBatch(batch)
        let report = try await store.loadUsageReport(
            since: start,
            until: start.addingTimeInterval(20 * 86_400)
        )

        XCTAssertEqual(report.fullChargeEstimate?.sessionCount, 2)
        XCTAssertEqual(report.fullChargeEstimate?.seconds ?? 0, 36_000, accuracy: 0.001)
    }

    func testBatteryStartBoundaryInvalidationPersistsAcrossReload() async throws {
        let fixture = try TemporaryHistoryFixture()
        let store = try HistoryStore(url: fixture.databaseURL)
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let known = BatterySessionRecord(
            id: "restored-session",
            startedAt: start,
            endedAt: nil,
            lastObservedAt: start.addingTimeInterval(3_600),
            startPercent: 100,
            endPercent: 90,
            awakeSeconds: 3_600,
            startBoundaryKnown: true,
            endBoundaryKnown: false
        )
        let invalidated = BatterySessionRecord(
            id: known.id,
            startedAt: known.startedAt,
            endedAt: nil,
            lastObservedAt: start.addingTimeInterval(3_700),
            startPercent: known.startPercent,
            endPercent: 89,
            awakeSeconds: 3_601,
            startBoundaryKnown: false,
            endBoundaryKnown: false
        )

        try await store.saveUsageBatch(
            UsagePersistenceBatch(
                completedUsageSegments: [],
                currentUsageSegment: nil,
                completedBatterySessions: [],
                activeBatterySession: known
            )
        )
        try await store.saveUsageBatch(
            UsagePersistenceBatch(
                completedUsageSegments: [],
                currentUsageSegment: nil,
                completedBatterySessions: [],
                activeBatterySession: invalidated
            )
        )

        let restored = try await store.loadActiveBatterySession()
        XCTAssertFalse(try XCTUnwrap(restored).startBoundaryKnown)
    }
}

private struct TemporaryHistoryFixture {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PurrCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        databaseURL = directoryURL.appendingPathComponent("history.sqlite3")
    }
}

private extension SystemSnapshot {
    static func fixture(
        at date: Date,
        cpu: Double,
        memory: UInt64 = 8_000,
        download: Double = 100,
        upload: Double = 50,
        diskRead: Double = 200,
        diskWrite: Double = 75
    ) -> SystemSnapshot {
        SystemSnapshot(
            timestamp: date,
            cpuPercent: cpu,
            memory: MemorySnapshot(totalBytes: 16_000, usedBytes: memory, appBytes: 4_000, wiredBytes: 1_000, compressedBytes: 1_000, cachedBytes: 2_000, swapUsedBytes: 0, pressure: .normal),
            network: ThroughputSnapshot(downloadBytesPerSecond: download, uploadBytesPerSecond: upload),
            disk: ThroughputSnapshot(downloadBytesPerSecond: diskRead, uploadBytesPerSecond: diskWrite),
            thermalState: .nominal,
            processes: []
        )
    }
}

private func createLegacyDatabase(at url: URL, timestamp: Date) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "HistoryStoreTests", code: 1)
    }
    defer { sqlite3_close(database) }

    let sql = """
    CREATE TABLE system_samples (
        timestamp REAL PRIMARY KEY,
        cpu_percent REAL NOT NULL,
        memory_used_bytes INTEGER NOT NULL,
        network_download_bps REAL NOT NULL,
        network_upload_bps REAL NOT NULL,
        disk_read_bps REAL NOT NULL,
        disk_write_bps REAL NOT NULL,
        thermal_state TEXT NOT NULL
    );
    INSERT INTO system_samples VALUES (
        \(timestamp.timeIntervalSince1970), 42, 8000, 100, 50, 200, 75, 'nominal'
    );
    PRAGMA user_version = 0;
    """

    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw NSError(
            domain: "HistoryStoreTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
        )
    }
}
