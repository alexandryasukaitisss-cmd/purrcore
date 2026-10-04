import XCTest
@testable import PurrCoreCore

final class StorageSnapshotTests: XCTestCase {
    func testCalculatesUsedStorage() {
        let snapshot = SSDSnapshot(totalBytes: 1_000, freeBytes: 250)

        XCTAssertEqual(snapshot.usedBytes, 750)
        XCTAssertEqual(snapshot.usedFraction, 0.75, accuracy: 0.0001)
    }

    func testZeroCapacityHasZeroUsedFraction() {
        let snapshot = SSDSnapshot(totalBytes: 0, freeBytes: 0)

        XCTAssertEqual(snapshot.usedBytes, 0)
        XCTAssertEqual(snapshot.usedFraction, 0)
    }
}
