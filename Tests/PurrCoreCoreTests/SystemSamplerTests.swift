import XCTest
@testable import PurrCoreCore

final class SystemSamplerTests: XCTestCase {
    func testSamplesLiveMacMetricsAndProcesses() async {
        let sampler = SystemSampler()
        _ = await sampler.sample(includeProcesses: true)
        try? await Task.sleep(nanoseconds: 1_100_000_000)

        let sample = await sampler.sample(includeProcesses: true)

        XCTAssertGreaterThan(sample.memory.totalBytes, 0)
        XCTAssertLessThanOrEqual(sample.memory.usedBytes, sample.memory.totalBytes)
        XCTAssertTrue((0...100).contains(sample.cpuPercent))
        XCTAssertGreaterThanOrEqual(sample.coreCount, 1)
        XCTAssertEqual(sample.perCoreCPU.count, sample.coreCount)
        XCTAssertTrue(sample.perCoreCPU.allSatisfy { (0...100).contains($0) })
        XCTAssertGreaterThan(sample.processes.count, 0)
        XCTAssertGreaterThan(sample.processes.map(\.residentBytes).max() ?? 0, 0)
    }

    func testProcessCPUShareConvertsMachTimebaseAndNormalizesAcrossCores() {
        // Apple Silicon 24 MHz clock: numer = 125, denom = 3 => 24_000_000 ticks = 1.0 CPU second.
        let appleSiliconOneCoreOfTen = SystemSampler.cpuSharePercent(
            deltaMachTicks: 24_000_000,
            elapsedSeconds: 1.0,
            timebaseNumer: 125,
            timebaseDenom: 3,
            coreCount: 10
        )
        XCTAssertEqual(appleSiliconOneCoreOfTen, 10.0, accuracy: 0.001)

        let appleSiliconFiveCoresOfTen = SystemSampler.cpuSharePercent(
            deltaMachTicks: 120_000_000,
            elapsedSeconds: 1.0,
            timebaseNumer: 125,
            timebaseDenom: 3,
            coreCount: 10
        )
        XCTAssertEqual(appleSiliconFiveCoresOfTen, 50.0, accuracy: 0.001)

        // Intel 1 GHz clock: numer = 1, denom = 1 => 1_000_000_000 ticks = 1.0 CPU second.
        let intelOneCoreOfEight = SystemSampler.cpuSharePercent(
            deltaMachTicks: 1_000_000_000,
            elapsedSeconds: 1.0,
            timebaseNumer: 1,
            timebaseDenom: 1,
            coreCount: 8
        )
        XCTAssertEqual(intelOneCoreOfEight, 12.5, accuracy: 0.001)

        let group = ProcessGroupSample(
            groupKey: "app:test",
            displayName: "Test",
            explanation: "основной процесс",
            category: .development,
            cpuPercent: 50.0,
            residentBytes: 1_000,
            processCount: 1
        )
        XCTAssertEqual(group.equivalentCores(totalCores: 10), 5.0, accuracy: 0.001)
    }

    func testActivityMonitorMemoryBreakdownAndKernelPressure() {
        let pageSize: UInt64 = 16_384
        let gb: UInt64 = 1_073_741_824
        let total = 16 * gb
        let internalPages = (8 * gb) / pageSize
        let purgeablePages = (1 * gb) / pageSize
        let externalPages = (3 * gb) / pageSize
        let wiredPages = (2 * gb) / pageSize
        let compressedPages = (3 * gb) / pageSize
        let freePages = (1 * gb) / pageSize
        let inactivePages = (2 * gb) / pageSize

        let warning = SystemSampler.memoryBreakdown(
            totalBytes: total,
            pageSize: pageSize,
            internalPages: internalPages,
            externalPages: externalPages,
            purgeablePages: purgeablePages,
            wiredPages: wiredPages,
            compressedPages: compressedPages,
            freePages: freePages,
            inactivePages: inactivePages,
            kernelPressureLevel: 2,
            swapUsedBytes: 8 * gb
        )
        XCTAssertEqual(warning.appBytes, 7 * gb)
        XCTAssertEqual(warning.wiredBytes, 2 * gb)
        XCTAssertEqual(warning.compressedBytes, 3 * gb)
        XCTAssertEqual(warning.usedBytes, 12 * gb)
        XCTAssertEqual(warning.cachedBytes, 4 * gb)
        XCTAssertEqual(warning.pressure, .warning)

        let critical = SystemSampler.memoryBreakdown(
            totalBytes: total,
            pageSize: pageSize,
            internalPages: internalPages,
            externalPages: externalPages,
            purgeablePages: purgeablePages,
            wiredPages: wiredPages,
            compressedPages: compressedPages,
            freePages: freePages,
            inactivePages: inactivePages,
            kernelPressureLevel: 4,
            swapUsedBytes: 0
        )
        XCTAssertEqual(critical.pressure, .critical)

        let normal = SystemSampler.memoryBreakdown(
            totalBytes: total,
            pageSize: pageSize,
            internalPages: internalPages,
            externalPages: externalPages,
            purgeablePages: purgeablePages,
            wiredPages: wiredPages,
            compressedPages: compressedPages,
            freePages: freePages,
            inactivePages: inactivePages,
            kernelPressureLevel: 1,
            swapUsedBytes: 0
        )
        XCTAssertEqual(normal.pressure, .normal)
    }
}
