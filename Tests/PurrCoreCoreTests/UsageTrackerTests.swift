import Foundation
import XCTest
@testable import PurrCoreCore

final class UsageTrackerTests: XCTestCase {
    func testOfflineGapAndSleepAreNotCountedAsAwakeTime() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var tracker = UsageTracker(maximumContinuousGap: 5)

        tracker.resume(at: start, battery: nil)
        tracker.observe(at: start.addingTimeInterval(1), battery: nil)
        tracker.observe(at: start.addingTimeInterval(20), battery: nil)
        tracker.suspend(at: start.addingTimeInterval(21), battery: nil)
        tracker.resume(at: start.addingTimeInterval(100), battery: nil)
        tracker.observe(at: start.addingTimeInterval(102), battery: nil)

        let batch = tracker.persistenceBatch()
        let segments = batch.completedUsageSegments + [batch.currentUsageSegment].compactMap { $0 }

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map(\.awakeSeconds).reduce(0, +), 4, accuracy: 0.001)
        XCTAssertEqual(segments.map(\.batteryAwakeSeconds).reduce(0, +), 0, accuracy: 0.001)
    }

    func testBatterySessionCountsOnlyContiguousAwakeBatteryTime() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var tracker = UsageTracker(maximumContinuousGap: 5)

        tracker.resume(at: start, battery: .fixture(percent: 100, pluggedIn: true))
        tracker.observe(at: start.addingTimeInterval(1), battery: .fixture(percent: 100, pluggedIn: true))
        tracker.observe(at: start.addingTimeInterval(2), battery: .fixture(percent: 100, pluggedIn: false))
        tracker.observe(at: start.addingTimeInterval(3), battery: .fixture(percent: 98, pluggedIn: false))
        tracker.suspend(at: start.addingTimeInterval(4), battery: .fixture(percent: 97, pluggedIn: false))

        tracker.resume(at: start.addingTimeInterval(100), battery: .fixture(percent: 90, pluggedIn: false))
        tracker.observe(at: start.addingTimeInterval(101), battery: .fixture(percent: 89, pluggedIn: false))
        tracker.observe(at: start.addingTimeInterval(102), battery: .fixture(percent: 89, pluggedIn: true))

        let batch = tracker.persistenceBatch()
        let session = try XCTUnwrap(batch.completedBatterySessions.last)

        XCTAssertEqual(session.awakeSeconds, 4, accuracy: 0.001)
        XCTAssertEqual(session.consumedPercent, 11, accuracy: 0.001)
        XCTAssertEqual(session.startBoundaryKnown, true)
        XCTAssertEqual(session.endBoundaryKnown, true)
        XCTAssertNil(batch.activeBatterySession)
    }

    func testChargingWhileSuspendedInvalidatesBoundaries() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var tracker = UsageTracker(maximumContinuousGap: 5)

        tracker.resume(at: start, battery: .fixture(percent: 100, pluggedIn: true))
        tracker.observe(at: start.addingTimeInterval(1), battery: .fixture(percent: 100, pluggedIn: false))
        tracker.observe(at: start.addingTimeInterval(2), battery: .fixture(percent: 90, pluggedIn: false))
        tracker.suspend(at: start.addingTimeInterval(3), battery: .fixture(percent: 89, pluggedIn: false))
        tracker.resume(at: start.addingTimeInterval(100), battery: .fixture(percent: 95, pluggedIn: false))

        let batch = tracker.persistenceBatch()
        let completed = try XCTUnwrap(batch.completedBatterySessions.last)
        let active = try XCTUnwrap(batch.activeBatterySession)

        XCTAssertFalse(completed.endBoundaryKnown)
        XCTAssertFalse(active.startBoundaryKnown)
        XCTAssertEqual(active.startPercent, 95, accuracy: 0.001)
    }

    func testRestoredBatterySessionAfterOfflineGapIsExcludedFromEstimate() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let restored = BatterySessionRecord.fixture(
            startedAt: start,
            endedAt: nil,
            startPercent: 100,
            endPercent: 80,
            awakeSeconds: 7_200,
            lastObservedAt: start.addingTimeInterval(7_200)
        )
        var tracker = UsageTracker(activeBatterySession: restored, maximumContinuousGap: 5)

        tracker.resume(
            at: start.addingTimeInterval(7_300),
            battery: .fixture(percent: 79, pluggedIn: false)
        )
        tracker.observe(
            at: start.addingTimeInterval(7_301),
            battery: .fixture(percent: 79, pluggedIn: true)
        )

        let completed = try XCTUnwrap(tracker.persistenceBatch().completedBatterySessions.last)
        XCTAssertFalse(completed.startBoundaryKnown)
        XCTAssertFalse(completed.isEstimateCandidate)
    }

    func testFullChargeEstimateUsesCoverageWeightedRecentSessions() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let sessions = [
            BatterySessionRecord.fixture(
                startedAt: start,
                endedAt: start.addingTimeInterval(5 * 3_600),
                startPercent: 100,
                endPercent: 50,
                awakeSeconds: 5 * 3_600
            ),
            BatterySessionRecord.fixture(
                startedAt: start.addingTimeInterval(86_400),
                endedAt: start.addingTimeInterval(86_400 + 3 * 3_600),
                startPercent: 90,
                endPercent: 65,
                awakeSeconds: 3 * 3_600
            ),
            BatterySessionRecord.fixture(
                startedAt: start.addingTimeInterval(2 * 86_400),
                endedAt: start.addingTimeInterval(2 * 86_400 + 3_600),
                startPercent: 80,
                endPercent: 70,
                awakeSeconds: 3_600,
                startBoundaryKnown: false
            )
        ]

        let estimate = try XCTUnwrap(UsageEstimator.fullChargeEstimate(from: sessions))

        XCTAssertEqual(estimate.sessionCount, 2)
        XCTAssertEqual(estimate.seconds, 38_400, accuracy: 0.001)
    }
}

private extension BatterySnapshot {
    static func fixture(percent: Double, pluggedIn: Bool) -> BatterySnapshot {
        BatterySnapshot(percent: percent, isCharging: pluggedIn, isPluggedIn: pluggedIn, minutesRemaining: nil)
    }
}

private extension BatterySessionRecord {
    static func fixture(
        startedAt: Date,
        endedAt: Date?,
        startPercent: Double,
        endPercent: Double,
        awakeSeconds: TimeInterval,
        lastObservedAt: Date? = nil,
        startBoundaryKnown: Bool = true,
        endBoundaryKnown: Bool = true
    ) -> BatterySessionRecord {
        BatterySessionRecord(
            id: UUID().uuidString,
            startedAt: startedAt,
            endedAt: endedAt,
            lastObservedAt: lastObservedAt ?? endedAt ?? startedAt,
            startPercent: startPercent,
            endPercent: endPercent,
            awakeSeconds: awakeSeconds,
            startBoundaryKnown: startBoundaryKnown,
            endBoundaryKnown: endBoundaryKnown
        )
    }
}
