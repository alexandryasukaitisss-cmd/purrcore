import XCTest
@testable import PurrCoreCore

final class SSDHealthTests: XCTestCase {
    func testHealthScoringPrioritizesCriticalSignals() {
        XCTAssertEqual(
            SSDHealthScoring.status(
                smartStatus: true,
                criticalWarning: 0,
                temperatureC: 40,
                availableSparePercent: 100,
                spareThresholdPercent: 10,
                percentageUsed: 10,
                dataUnitsReadTB: nil,
                dataUnitsWrittenTB: nil,
                powerCycles: nil,
                powerOnHours: nil,
                unsafeShutdowns: nil,
                mediaErrors: 0,
                errorLogEntries: nil
            ),
            .healthy
        )
        XCTAssertEqual(
            SSDHealthScoring.status(
                smartStatus: true,
                criticalWarning: 0,
                temperatureC: 70,
                availableSparePercent: 100,
                spareThresholdPercent: 10,
                percentageUsed: 10,
                dataUnitsReadTB: nil,
                dataUnitsWrittenTB: nil,
                powerCycles: nil,
                powerOnHours: nil,
                unsafeShutdowns: nil,
                mediaErrors: 0,
                errorLogEntries: nil
            ),
            .warning
        )
        XCTAssertEqual(
            SSDHealthScoring.status(
                smartStatus: true,
                criticalWarning: 1,
                temperatureC: 40,
                availableSparePercent: 100,
                spareThresholdPercent: 10,
                percentageUsed: 10,
                dataUnitsReadTB: nil,
                dataUnitsWrittenTB: nil,
                powerCycles: nil,
                powerOnHours: nil,
                unsafeShutdowns: nil,
                mediaErrors: 0,
                errorLogEntries: nil
            ),
            .critical
        )
    }

    func testNoStatusAndNoMetricsIsUnavailable() {
        let snapshot = SSDHealthSnapshot()

        XCTAssertEqual(snapshot.status, .unavailable)
    }

    func testDecodesNVMeLittleEndianMetricsAndDecimalTB() {
        var data = [UInt8](repeating: 0, count: 512)
        writeUInt16(323, to: &data, offset: 1)
        data[3] = 95
        data[4] = 10
        data[5] = 12
        writeUInt64(1_953_125, to: &data, offset: 32)
        writeUInt64(3_906_250, to: &data, offset: 48)
        writeUInt64(42, to: &data, offset: 112)

        let metrics = SSDHealthNVMeDecoder.decode(data: data)

        XCTAssertEqual(metrics?.temperatureC ?? 0, 49.85, accuracy: 0.01)
        XCTAssertEqual(metrics?.dataUnitsReadTB ?? 0, 1, accuracy: 0.000001)
        XCTAssertEqual(metrics?.dataUnitsWrittenTB ?? 0, 2, accuracy: 0.000001)
        XCTAssertEqual(metrics?.powerCycles, 42)
        XCTAssertEqual(SSDHealthNVMeDecoder.decodeDataUnitsTB(low: 1, high: 1), 9_444_732_965_739.29, accuracy: 0.01)
    }

    func testParsesDiskutilFallbackAndPhysicalStore() {
        let output = """
        Device Identifier:        disk7s1
        Device / Media Name:      APPLE SSD AP0512N
        Protocol:                 NVMe
        Media Type:               Solid State
        Disk Size:                500.1 GB (500,107,862,016 Bytes)
        SMART Status:             Verified
        APFS Physical Store:      disk9s2
        """

        let info = SSDHealthFallbackParser.parse(output)

        XCTAssertEqual(info.model, "APPLE SSD AP0512N")
        XCTAssertEqual(info.protocolName, "NVMe")
        XCTAssertEqual(info.capacityBytes, 500_107_862_016)
        XCTAssertEqual(info.smartStatus, true)
        XCTAssertEqual(SSDHealthFallbackParser.physicalDiskIdentifier(from: output), "disk9")
    }

    private func writeUInt16(_ value: UInt16, to data: inout [UInt8], offset: Int) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8(value >> 8)
    }

    private func writeUInt64(_ value: UInt64, to data: inout [UInt8], offset: Int) {
        for index in 0..<8 {
            data[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xff)
        }
    }
}
