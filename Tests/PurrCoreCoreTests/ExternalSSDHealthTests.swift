import XCTest
@testable import PurrCoreCore

final class ExternalSSDHealthTests: XCTestCase {
    func testEligibilityIncludesUnknownAndFixedButExcludesRotational() {
        XCTAssertTrue(ExternalSSDParsing.eligible(["Internal": false, "Removable": false]))
        XCTAssertTrue(ExternalSSDParsing.eligible(["Internal": false, "SolidState": true]))
        XCTAssertFalse(ExternalSSDParsing.eligible(["Internal": false, "SolidState": false]))
        XCTAssertFalse(ExternalSSDParsing.eligible(["Internal": true, "SolidState": true]))
    }

    func testSharedAPFSPoolIsCountedOnceAndMultiStoreUnknown() {
        let pool: [String: Any] = ["PhysicalStores": [["DeviceIdentifier": "disk6s2"]], "Volumes": [["DeviceIdentifier": "disk7s1"], ["DeviceIdentifier": "disk7s2"]], "CapacityCeiling": 499972575232, "CapacityFree": 337648939008]
        let parsed = ExternalSSDParsing.poolStorage(pool)
        XCTAssertEqual(parsed?.totalBytes, 499972575232)
        XCTAssertEqual(parsed?.freeBytes, 337648939008)
        var multi = pool
        multi["PhysicalStores"] = [["DeviceIdentifier": "disk6s2"], ["DeviceIdentifier": "disk8s2"]]
        XCTAssertNil(ExternalSSDParsing.poolStorage(multi))
    }

    func testNoSMARTCannotBecomeHealthyAndUnknownSpeedIsAbsent() {
        XCTAssertNil(ExternalSSDParsing.smart("Not Supported"))
        XCTAssertEqual(SSDHealthSnapshot(smartStatus: ExternalSSDParsing.smart("Not Supported")).status, .unavailable)
        XCTAssertNil(ExternalSSDParsing.speed(99))
        XCTAssertEqual(ExternalSSDParsing.speed(3), 5000)
    }
    func testMountNormalizationAndCandidateSelection() {
        XCTAssertNil(ExternalSSDParsing.mount(""))
        XCTAssertNil(ExternalSSDParsing.mount("  "))
        XCTAssertEqual(ExternalSSDParsing.mount("/Volumes/Drive"), "/Volumes/Drive")
        let whole: [String: Any] = ["DeviceIdentifier": "disk6", "Content": "Microsoft Basic Data"]
        XCTAssertEqual(ExternalSSDParsing.candidates(["AllDisksAndPartitions": [whole]], disk: "disk6").count, 1)
        let partitioned: [String: Any] = ["DeviceIdentifier": "disk6", "Partitions": [["DeviceIdentifier": "disk6s1", "Content": "EFI"], ["DeviceIdentifier": "disk6s2", "Content": "Microsoft Basic Data"]]]
        XCTAssertEqual(ExternalSSDParsing.candidates(["AllDisksAndPartitions": [partitioned]], disk: "disk6").count, 2)
        XCTAssertTrue(ExternalSSDParsing.isUserFilesystem(["FilesystemType": "exfat", "MountPoint": ""]))
        XCTAssertFalse(ExternalSSDParsing.isUserFilesystem(["FilesystemType": "msdos", "Content": "EFI"]))
    }

    func testAPFSUnavailableDoesNotBecomeRegularFilesystem() {
        let store: [String: Any] = ["DeviceIdentifier": "disk6s2", "Content": "Apple_APFS"]
        XCTAssertTrue(ExternalSSDParsing.isAPFS(store))
        XCTAssertFalse(ExternalSSDParsing.isUserFilesystem(["FilesystemType": "apfs", "MountPoint": "/Volumes/Xcode"]))
    }

    func testDiskutilFailureOverridesCleanNativeMetricsInSharedSnapshotPath() {
        let bytes = [UInt8](repeating: 0, count: 512)
        let metrics = try! XCTUnwrap(SSDHealthNVMeDecoder.decode(data: bytes))
        let info = SSDHealthDiskInfo(model: "Example", smartStatus: false)
        let snapshot = SSDHealthReader().snapshot(diskInfo: info, nativeModel: nil, nativeSmartStatus: true, metrics: metrics)
        XCTAssertEqual(snapshot.smartStatus, false)
        XCTAssertEqual(snapshot.status, .critical)
    }

    func testMixedAPFSAndExFATAreBothRepresentedAndAggregated() {
        let pool: [String: Any] = ["PhysicalStores": [["DeviceIdentifier": "disk6s2"]],
            "Volumes": [["DeviceIdentifier": "disk7s1", "Name": "Xcode"]],
            "CapacityCeiling": 500, "CapacityFree": 200]
        let candidates: [[String: Any]] = [
            ["DeviceIdentifier": "disk6s2", "Content": "Apple_APFS"],
            ["DeviceIdentifier": "disk6s3", "Content": "Microsoft Basic Data"]]
        let details: [String: [String: Any]] = [
            "disk7s1": ["VolumeName": "Xcode", "MountPoint": "/Volumes/Xcode"],
            "disk6s2": ["Content": "Apple_APFS"],
            "disk6s3": ["FilesystemType": "exfat", "VolumeName": "Data", "MountPoint": "/Volumes/Data"]]
        let result = ExternalSSDParsing.summarize(pools: [pool], candidates: candidates, details: details,
            filesystemStorage: ["disk6s3": SSDSnapshot(totalBytes: 100, freeBytes: 50)], apfsAvailable: true)
        XCTAssertEqual(result.volumes.map(\.name), ["Xcode", "Data"])
        XCTAssertEqual(result.storage, SSDSnapshot(totalBytes: 600, freeBytes: 250))
    }

    func testUnmountedUserVolumeMakesStorageUnknownEvenWhenAnotherIsMounted() {
        let candidates: [[String: Any]] = [
            ["DeviceIdentifier": "disk6s1"], ["DeviceIdentifier": "disk6s2"]]
        let details: [String: [String: Any]] = [
            "disk6s1": ["FilesystemType": "exfat", "VolumeName": "Mounted", "MountPoint": "/Volumes/Mounted"],
            "disk6s2": ["FilesystemType": "exfat", "VolumeName": "Offline", "MountPoint": ""]]
        let result = ExternalSSDParsing.summarize(pools: [], candidates: candidates, details: details,
            filesystemStorage: ["disk6s1": SSDSnapshot(totalBytes: 100, freeBytes: 40)], apfsAvailable: true)
        XCTAssertEqual(result.volumes.count, 2)
        XCTAssertNil(result.volumes[1].mountPoint)
        XCTAssertNil(result.storage)
    }

    func testIOCountersPreserveUnknownAndRejectInvalidValues() throws {
        XCTAssertNil(ExternalSSDParsing.ioStatistics(nil))
        XCTAssertNil(ExternalSSDParsing.ioStatistics(["Errors (Read)": -1, "Errors (Write)": true]))
        let partial = try XCTUnwrap(ExternalSSDParsing.ioStatistics(["Bytes (Read)": UInt64.max]))
        XCTAssertEqual(partial.bytesRead, UInt64.max)
        XCTAssertNil(partial.readErrors)
        XCTAssertFalse(partial.hasIssues)
        XCTAssertFalse(partial.hasCompleteErrorCounters)
        let warnings = try XCTUnwrap(ExternalSSDParsing.ioStatistics([
            "Errors (Read)": 0, "Errors (Write)": 1, "Retries (Read)": 2, "Retries (Write)": 0]))
        XCTAssertTrue(warnings.hasIssues)
        XCTAssertTrue(warnings.hasCompleteErrorCounters)
        XCTAssertEqual(warnings.readErrors, 0)
        XCTAssertEqual(warnings.writeErrors, 1)
    }

}
